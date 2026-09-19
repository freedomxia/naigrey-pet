import Foundation
import Security
import CryptoKit
import LocalAuthentication

// Protocol shapes and service names adapted from Codenotch v1.14.0:
// CodexCredentials.swift, CodexLocalProvider.swift, CodexUsage.swift,
// ClaudeCredentials.swift, ClaudeOAuthProvider.swift, ClaudeProfile.swift.
// Copyright (c) 2026 Vinz — MIT; see THIRD_PARTY_NOTICES.md.
// Source selection and parsers are shared with the vendored Codenotch core.

/// Call only after the user connects a provider. This type never starts timers.
enum AIQuotaReader {
    static func fetch(_ provider: AIProvider) async throws -> AIUsage {
        if provider == .claude { return try await ClaudeQuotaSources.shared.fetch() }
        return try await fetchOAuth(provider)
    }
    static func fetchOAuth(_ provider: AIProvider, retryUnauthorized:Bool = true) async throws -> AIUsage {
        try Task.checkCancellation()
        let credential: QuotaCredential
        switch provider {
        case .codex:
            let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            let path = home.appendingPathComponent("auth.json")
            let data = try readCredentialFile(path)
            credential = try QuotaParser.codexCredential(data)
        case .claude:
            credential = try await readClaude(interactive: false)
        }
        if provider == .claude, let expiry = credential.expiresAt, expiry <= Date() {
            throw AIProviderError(status:.stale,message:"Claude 登录待续期；正在等待 Claude Code 更新。")
        }
        try Task.checkCancellation()
        let endpoint = provider == .codex
            ? "https://chatgpt.com/backend-api/wham/usage" : "https://api.anthropic.com/api/oauth/usage"
        var request = URLRequest(url: URL(string: endpoint)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        if provider == .codex { request.setValue(credential.rawAccountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        else { request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: RejectQuotaRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw QuotaParser.invalid() }
            if provider == .claude, [401,403].contains(http.statusCode), retryUnauthorized {
                ClaudeQuotaKeychain.forget()
                return try await fetchOAuth(provider,retryUnauthorized:false)
            }
            try QuotaParser.checkHTTP(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            guard data.count <= 2_000_000 else { throw QuotaParser.invalid() }
            let now = Date()
            let windows = try provider == .codex ? QuotaParser.codex(data, now: now) : QuotaParser.claude(data)
            return AIUsage(provider: provider, accountID: credential.fingerprint, status: .ok,
                           source: provider == .codex ? "Codex 本机登录 · 在线额度" : "Claude Code OAuth · 在线额度",
                           sourceAt: now, observedAt: now, windows: windows,
                           message: provider == .claude ? "OAuth 只读模式；凭证轮换后重新建立提醒基线。" : nil)
        } catch let error as AIProviderError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw AIProviderError(status: .error, message: "额度请求未完成，请检查网络后重试。") }
    }

    /// Only invoke from an explicit Claude Connect / Allow Access button.
    /// Background fetches cannot display authorization prompts.
    static func authorizeClaudeKeychain() async throws {
        _ = try await readClaude(interactive: true)
    }

    /// Drop the in-memory secret on disconnect or application shutdown.
    static func forgetClaudeAuthorization() { ClaudeQuotaKeychain.forget(); Task { await ClaudeQuotaSources.shared.forget() } }

    @MainActor static func makeClaudeRefresher()->ClaudeTokenRefresher {
        ClaudeTokenRefresher(expiry:{ ClaudeQuotaKeychain.expiry() },reload:{
            ClaudeQuotaKeychain.forget()
            return try? await readClaude(interactive:false).expiresAt
        })
    }
    private static func readClaude(interactive: Bool) async throws -> QuotaCredential {
        // Security.framework may block waiting for its own authorization dialog.
        // Keep this entirely away from AppKit's main thread.
        let generation = ClaudeQuotaKeychain.currentGeneration()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try ClaudeQuotaKeychain.read(interactive: interactive, generation: generation) })
            }
        }
    }

    private static func readCredentialFile(_ url: URL) throws -> Data {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size <= 1_000_000 else { throw QuotaParser.invalid() }
            return try Data(contentsOf: url)
        } catch let error as AIProviderError { throw error }
        catch let error as NSError {
            if error.code == NSFileReadNoPermissionError {
                throw AIProviderError(status: .accessDenied, message: "无法读取本机 Codex 登录文件。")
            }
            throw AIProviderError(status: .needsAuth, message: "未找到可用的 Codex 文件登录；请在 Codex 登录。仅钥匙串登录暂不支持。")
        }
    }
}

private final class RejectQuotaRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Reject even same-host redirects; credentials never leave the fixed endpoint.
        completionHandler(nil)
    }
}

struct QuotaCredential {
    let token: String
    let rawAccountID: String?
    let fingerprint: String
    var expiresAt: Date? = nil
}

enum QuotaParser {
    static func invalid() -> AIProviderError {
        AIProviderError(status: .unsupported, message: "额度来源格式暂不支持；保留上次记录。")
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid() }
        return root
    }
    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    static func claudeKeychainServices(defaultDirectory: String) -> [String] {
        ["Claude Code-credentials-" + String(fingerprint(defaultDirectory).prefix(8)), "Claude Code-credentials"]
    }
    static func explicitlyTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
    static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains("\r"), !value.contains("\n") else { return nil }
        return value
    }
    static func fraction(_ value: Any?) -> Double? {
        guard let value = number(value), value >= 0, value <= 100 else { return nil }
        return value / 100
    }
    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? object(data)
    }
    static func codexCredential(_ data: Data, now: Date = Date()) throws -> QuotaCredential {
        let root = try object(data)
        guard let tokens = root["tokens"] as? [String: Any],
              let token = nonempty(tokens["access_token"]), let account = nonempty(tokens["account_id"]) else {
            if nonempty(root["OPENAI_API_KEY"]) != nil {
                throw AIProviderError(status: .unsupported, message: "API Key 计费不提供 ChatGPT 订阅额度。")
            }
            throw AIProviderError(status: .needsAuth, message: "请在 Codex 完成账号登录。")
        }
        if let expiry = number(jwtClaims(token)?["exp"]), expiry <= now.timeIntervalSince1970 {
            throw AIProviderError(status: .needsAuth, message: "Codex 登录已过期，请打开 Codex 更新登录。")
        }
        return QuotaCredential(token: token, rawAccountID: account, fingerprint: fingerprint("codex:" + account))
    }
    static func claudeCredential(_ data: Data, now: Date = Date(), allowExpired:Bool = false) throws -> QuotaCredential {
        let root = try object(data)
        guard let oauth = root["claudeAiOauth"] as? [String: Any], let token = nonempty(oauth["accessToken"]),
              let expiry = number(oauth["expiresAt"]), (allowExpired || expiry / 1000 > now.timeIntervalSince1970) else {
            throw AIProviderError(status: .needsAuth, message: "Claude Code 登录已过期或不可用，请在原应用更新登录。")
        }
        // Claude's opaque token has no independently verifiable account ID.
        // A credential epoch is conservative: rotations rebaseline; accounts never mix.
        return QuotaCredential(token: token, rawAccountID: nil, fingerprint: fingerprint("claude:" + token), expiresAt: Date(timeIntervalSince1970: expiry / 1000))
    }
    static func checkHTTP(status: Int, retryAfter: String? = nil, now: Date = Date()) throws {
        if status == 401 || status == 403 { throw AIProviderError(status: .needsAuth, message: "登录失效或额度访问未授权，请在原应用重新登录。") }
        if status == 429 {
            var seconds = retryAfter.flatMap(Double.init)
            if seconds == nil, let value = retryAfter {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                seconds = formatter.date(from: value)?.timeIntervalSince(now)
            }
            let delay = seconds.flatMap { $0.isFinite ? max(60, $0) : nil } ?? 60
            throw AIProviderError(status: .error, message: "额度接口限流，稍后重试。", retryAfter: delay)
        }
        guard (200..<300).contains(status) else {
            throw AIProviderError(status: .error, message: "额度接口暂不可用（HTTP \(status)）。")
        }
    }
    static func codex(_ data: Data, now: Date = Date()) throws -> [AILimit] {
        do { return try CodexUsage.windows(from:data,now:now).map { $0.local(provider:.codex) } }
        catch { throw invalid() }
    }
    static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = parser.date(from: text) { return result }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: text)
    }
    static func claude(_ data: Data) throws -> [AILimit] {
        do {
            let windows = try UsageResponse.decoder.decode(UsageResponse.self,from:data).limitWindows()
            guard !windows.isEmpty else { throw invalid() }
            return windows.map { $0.local(provider:.claude) }
        } catch { throw invalid() }
    }
    private static func unique(_ windows: [AILimit]) -> [AILimit] {
        var seen = Set<String>()
        return windows.filter { seen.insert($0.id).inserted }
    }
}

/// Pure invalidation rule, also exercised without accessing Keychain in tests.
struct QuotaReadGeneration {
    private(set) var value: UInt64 = 0
    mutating func invalidate() { value &+= 1 }
    func accepts(_ captured: UInt64) -> Bool { value == captured }
}

private enum ClaudeQuotaKeychain {
    // An explicit "Allow once" must serve the following fetch too. The secret
    // stays only in process memory until expiration; each read rechecks item
    // identity and modification time so account switches cannot reuse it.
    private static let cacheLock = NSLock()
    private static var generation = QuotaReadGeneration()
    private static var tokenExpiry:Date?
    static func expiry()->Date? { cacheLock.lock(); defer { cacheLock.unlock() }; return tokenExpiry }
    private static var cached: (reference: Data, modified: Date, credential: QuotaCredential)?
    static func forget() {
        cacheLock.lock(); generation.invalidate(); cached = nil; tokenExpiry = nil; cacheLock.unlock()
    }
    static func currentGeneration() -> UInt64 {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return generation.value
    }
    private static func newestItem() throws -> (Date, Data) {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        // Never enumerate all Claude services or consult CLAUDE_CONFIG_DIR:
        // this adapter supports only the default account explicitly connected.
        let services = QuotaParser.claudeKeychainServices(defaultDirectory: path)
        let quietContext = LAContext()
        quietContext.interactionNotAllowed = true
        var candidates: [(Date, Data)] = []
        for service in services {
            var item: CFTypeRef?
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                        kSecReturnAttributes: true, kSecReturnPersistentRef: true, kSecMatchLimit: kSecMatchLimitAll,
                                        kSecUseAuthenticationContext: quietContext]
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else { throw authError(status) }
            for value in item as? [[String: Any]] ?? [] {
                if let reference = value[kSecValuePersistentRef as String] as? Data {
                    candidates.append((value[kSecAttrModificationDate as String] as? Date ?? .distantPast, reference))
                }
            }
        }
        guard let winner = candidates.max(by: { $0.0 < $1.0 }) else { throw authError(errSecItemNotFound) }
        return winner
    }
    static func read(interactive: Bool, generation captured: UInt64) throws -> QuotaCredential {
        guard currentGeneration() == captured else { throw CancellationError() }
        let winner = try newestItem()
        cacheLock.lock()
        guard generation.accepts(captured) else { cacheLock.unlock(); throw CancellationError() }
        let previous = cached
        if !interactive, let previous, previous.reference == winner.1,
           previous.modified == winner.0, let expiry = previous.credential.expiresAt, expiry > Date() {
            cacheLock.unlock()
            return previous.credential
        }
        cached = nil
        cacheLock.unlock()
        var item: CFTypeRef?
        let secretContext = LAContext()
        secretContext.interactionNotAllowed = !interactive
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecValuePersistentRef: winner.1,
                                    kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
                                    kSecUseAuthenticationContext: secretContext]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { throw authError(status) }
        let credential = try QuotaParser.claudeCredential(data,allowExpired:true)
        // The authorization dialog may have stayed open across disconnect or
        // an account rotation. Never resurrect its secret or return that read.
        guard currentGeneration() == captured else { throw CancellationError() }
        let current = try newestItem()
        guard current.0 == winner.0 && current.1 == winner.1 else { throw CancellationError() }
        cacheLock.lock()
        guard generation.accepts(captured) else { cacheLock.unlock(); throw CancellationError() }
        tokenExpiry = credential.expiresAt
        cached = (winner.1, winner.0, credential)
        cacheLock.unlock()
        return credential
    }
    static func authError(_ status: OSStatus) -> AIProviderError {
        let missing = status == errSecItemNotFound
        return AIProviderError(status: .needsAuth, message: missing ? "未找到 Claude Code 登录，请先在 Claude Code 登录。" : "Claude 钥匙串访问未获授权；自动刷新不会再次弹窗，请主动重新连接。")
    }
}
