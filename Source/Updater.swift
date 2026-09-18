import AppKit
import CryptoKit

/// Keeps the pet current from GitHub. A small JSON feed says what the newest build is; the download is
/// checked against the project's signing key before anything is replaced, so only builds signed on the
/// release machine can ever be installed. This app is ad-hoc signed and not notarised, which means
/// Gatekeeper will not vet the download for us - the signature check here is what stands in for it.
final class Updater {

    /// One platform's newest build, as published in `updates/latest.json`.
    struct Release: Decodable {
        let version: String
        let build: Int
        let url: URL
        /// Lower-case hex digest of the download, for spotting a truncated or corrupted file.
        let sha256: String
        /// Base64 Ed25519 signature over the download's bytes.
        let signature: String
        let minimumSystem: String?
        let notes: String?
        let date: String?
    }

    /// The feed carries one entry per platform so a Windows build can join later without changing the app.
    struct Feed: Decodable {
        let mac: Release?
        let windows: Release?
    }

    enum Failure: LocalizedError {
        case network(String)
        case feed
        case corrupted
        case unsigned
        case notAnApp
        case wrongApp(String)
        case readOnly(String)
        case tool(String, Int32, String)

        var errorDescription: String? {
            switch self {
            case .network(let why): return "连不上更新服务器：\(why)"
            case .feed: return "更新信息读不懂，可能正在发布中"
            case .corrupted: return "下载的文件不完整"
            case .unsigned: return "下载的文件没有正确签名，已经丢掉"
            case .notAnApp: return "下载的包里没有找到 App"
            case .wrongApp(let what): return "下载的包对不上：\(what)"
            case .readOnly(let path): return "没有权限写入 \(path)"
            case .tool(let name, let code, let output): return "\(name) 失败（\(code)）：\(output)"
            }
        }
    }

    static let owner = "freedomxia"
    static let repo = "naigrey-pet"
    static var feedURL: URL { URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/main/updates/latest.json")! }
    static var releasesPage: URL { URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")! }
    /// The public half of the release key. The private half never leaves the machine that publishes builds.
    static let publicKey = "t/eNK8kwD/OsyhR6GEJpZygZi/bKqpVR6KMHT4QGPDY="

    static var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: Checking

    /// Reads the feed and reports the newer build, or nil when this copy is already the newest one.
    /// Always calls back on the main queue.
    func check(_ completion: @escaping (Result<Release?, Error>) -> Void) {
        let request = URLRequest(url: Updater.feedURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        session.dataTask(with: request) { data, response, error in
            let done = { (result: Result<Release?, Error>) in DispatchQueue.main.async { completion(result) } }
            if let error { return done(.failure(Failure.network(error.localizedDescription))) }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return done(.failure(Failure.network("HTTP \(http.statusCode)")))
            }
            guard let data else { return done(.failure(Failure.feed)) }
            do { done(.success(try Updater.pick(data, currentBuild: Updater.currentBuild))) }
            catch { done(.failure(error)) }
        }.resume()
    }

    /// Decides whether a feed offers this Mac something newer. Kept separate from the network so it can be tested.
    static func pick(_ data: Data, currentBuild: Int, system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws -> Release? {
        guard let feed = try? JSONDecoder().decode(Feed.self, from: data) else { throw Failure.feed }
        guard let mac = feed.mac, mac.build > currentBuild else { return nil }
        guard runs(on: system, atLeast: mac.minimumSystem) else { return nil }
        return mac
    }

    static func runs(on system: OperatingSystemVersion, atLeast minimum: String?) -> Bool {
        guard let minimum else { return true }
        let parts = minimum.split(separator: ".").map { Int($0) ?? 0 }
        let major = parts.first ?? 0, minor = parts.count > 1 ? parts[1] : 0
        if system.majorVersion != major { return system.majorVersion > major }
        return system.minorVersion >= minor
    }

    // MARK: Installing

    /// Downloads, checks and swaps in a release, then hands back the installed bundle. Calls back on the main queue.
    func install(_ release: Release, completion: @escaping (Result<URL, Error>) -> Void) {
        session.downloadTask(with: release.url) { temporary, response, error in
            let done = { (result: Result<URL, Error>) in DispatchQueue.main.async { completion(result) } }
            if let error { return done(.failure(Failure.network(error.localizedDescription))) }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return done(.failure(Failure.network("HTTP \(http.statusCode)")))
            }
            guard let temporary, let data = try? Data(contentsOf: temporary) else { return done(.failure(Failure.network("下载没有完成"))) }
            do {
                try Updater.verify(data, sha256: release.sha256, signature: release.signature)
                NSLog("奶灰: 更新包校验通过 %@ (%d bytes)", release.version, data.count)
                let unpacked = try Updater.unpack(data, expecting: release)
                let installed = try Updater.swapIn(unpacked)
                NSLog("奶灰: 已装好 %@", installed.path)
                done(.success(installed))
            } catch {
                done(.failure(error))
            }
        }.resume()
    }

    /// The download must match the published digest *and* carry a signature from the release key.
    /// The digest alone would prove nothing: whoever could change the file could change the digest beside it.
    static func verify(_ data: Data, sha256: String, signature: String, publicKey: String = Updater.publicKey) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(sha256) == .orderedSame else { throw Failure.corrupted }
        guard let signatureBytes = Data(base64Encoded: signature),
              let keyBytes = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              key.isValidSignature(signatureBytes, for: data) else { throw Failure.unsigned }
    }

    /// Unzips into a scratch folder and makes sure what came out really is a newer copy of this app.
    static func unpack(_ data: Data, expecting release: Release) throws -> URL {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("naigrey-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let archive = scratch.appendingPathComponent("download.zip")
        try data.write(to: archive)
        let unpacked = scratch.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])

        let contents = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else { throw Failure.notAnApp }
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { throw Failure.notAnApp }
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        guard identifier == (Bundle.main.bundleIdentifier ?? identifier) else { throw Failure.wrongApp("识别码是 \(identifier)") }
        let build = Int(info["CFBundleVersion"] as? String ?? "") ?? 0
        guard build == release.build else { throw Failure.wrongApp("构建号是 \(build)，说好的是 \(release.build)") }
        // A file we downloaded ourselves is not quarantined, but strip the flag anyway so an update can
        // never turn into a "已损坏" dialog.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        try run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        return app
    }

    /// Puts the new bundle where the running one lives, keeping the old one around in case it is needed.
    static func swapIn(_ newApp: URL, destination: URL = Bundle.main.bundleURL, backups: URL? = backupDirectory()) throws -> URL {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        guard manager.isWritableFile(atPath: parent.path) else { throw Failure.readOnly(parent.path) }
        if let backups {
            let backup = backups.appendingPathComponent("\(destination.deletingPathExtension().lastPathComponent)-\(currentVersion).app")
            try? manager.removeItem(at: backup)
            try? manager.copyItem(at: destination, to: backup)   // on APFS this is an instant clone
        }
        // Stage beside the destination first: replaceItemAt swaps atomically, but only within one volume.
        let staged = parent.appendingPathComponent(".\(destination.lastPathComponent).new")
        try? manager.removeItem(at: staged)
        try manager.moveItem(at: newApp, to: staged)
        do {
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } catch {
            try? manager.removeItem(at: staged)
            throw Failure.tool("替换", 1, error.localizedDescription)
        }
        return destination
    }

    static func backupDirectory() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = support.appendingPathComponent("奶灰/backup")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Starts the new copy once this process is gone. The caller quits straight after.
    static func relaunch(_ app: URL) {
        let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; sleep 0.4; /usr/bin/open \(quote(app.path))"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
    }

    /// Wraps a path for /bin/sh; paths here contain spaces and Chinese, and may contain a quote.
    static func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(data: output, encoding: .utf8) ?? ""
        guard task.terminationStatus == 0 else {
            throw Failure.tool((tool as NSString).lastPathComponent, task.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }
}
