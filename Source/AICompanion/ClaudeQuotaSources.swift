import Foundation

/// Default profile's three sources in Codenotch order. No work starts at init.
actor ClaudeQuotaSources {
    typealias Desktop = (String) async -> ClaudeDesktopUsageCache.Reading?
    typealias CLI = () async throws -> [LimitWindow]
    private let desktop:Desktop
    private let cli:CLI
    private let oauth:() async throws -> AIUsage
    private let organization:()->String?
    private let clock:()->Date
    private let defaults:UserDefaults
    init(defaults:UserDefaults = .standard, organization:@escaping ()->String? = { ClaudeProfile.default().organizationID() }, clock:@escaping ()->Date = Date.init, desktop:@escaping Desktop, cli:@escaping CLI, oauth:@escaping () async throws -> AIUsage) {
        self.defaults = defaults; self.organization = organization; self.clock = clock
        self.desktop = desktop; self.cli = cli; self.oauth = oauth
    }
    static let shared = ClaudeQuotaSources(desktop:{ org in
        await Task.detached(priority:.utility) { ClaudeDesktopUsageCache().read(organization:org) }.value
    },cli:{
        guard let cli = ClaudeUsageCLI.locate() else { throw UsageProviderError.needsAuth }
        return try await cli.read(profile:.default())
    },oauth:{ try await AIQuotaReader.fetchOAuth(.claude) })
    private var lastOrganization:String?
    private var lastDesktopMiss:Date?
    private var lastCLIAttempt:Date?
    private var lastCLIWindows:(windows:[LimitWindow],at:Date)?
    private var consecutiveRateLimits = 0
    private var generation = 0
    func forget() {
        generation += 1; lastOrganization = nil; lastDesktopMiss = nil
        lastCLIAttempt = nil; lastCLIWindows = nil
    }
    private func validate(_ captured:Int) throws {
        try Task.checkCancellation()
        guard captured == generation else { throw CancellationError() }
    }
    private func snapshot(_ windows:[LimitWindow],source:String,now:Date,organization:String?)->AIUsage {
        AIUsage(provider:.claude,accountID:QuotaParser.fingerprint("claude:" + (organization ?? ClaudeProfile.default().configDirectory.path)),status:.ok,source:source,sourceAt:now,observedAt:now,windows:windows.map { $0.local(provider:.claude) })
    }
    private func expired(_ windows:[LimitWindow],at now:Date)->Bool {
        windows.contains { $0.resetsAt.map { $0 <= now } ?? false }
    }
    func fetch() async throws -> AIUsage {
        let captured = generation
        try validate(captured)
        let now = clock(), org = organization()
        if lastOrganization != org {
            lastDesktopMiss = nil; lastCLIAttempt = nil; lastCLIWindows = nil; lastOrganization = org
        }
        // Codenotch: a missed Desktop scan waits 5 min; successful scans always
        // look for the newest matching organization entry, up to 30 min old.
        if lastDesktopMiss.map({ now.timeIntervalSince($0) >= 300 }) ?? true {
            if let org, let reading = await desktop(org) {
                try validate(captured)
                if reading.isFresh(at:now,within:1800), !expired(reading.windows,at:now) {
                    lastDesktopMiss = nil
                    return snapshot(reading.windows,source:"Claude Desktop 缓存",now:now,organization:org)
                }
            }
            try validate(captured); lastDesktopMiss = now
        }
        // CLI and Desktop remain available even while the OAuth endpoint backs off.
        if let last = lastCLIWindows, now.timeIntervalSince(last.at) < 300, !expired(last.windows,at:now) {
            return snapshot(last.windows,source:"Claude CLI /usage",now:now,organization:org)
        }
        if lastCLIAttempt.map({ now.timeIntervalSince($0) >= 300 }) ?? true {
            lastCLIAttempt = now
            do {
                let windows = try await cli(); try validate(captured)
                lastCLIWindows = (windows,now)
                return snapshot(windows,source:"Claude CLI /usage",now:now,organization:org)
            } catch is CancellationError { throw CancellationError() }
            catch { try validate(captured) }
        }
        let backoffKey = "ai.claude.oauth.backoff"
        if let until = defaults.object(forKey:backoffKey) as? Date, until.timeIntervalSince(now) > 1 {
            throw AIProviderError(status:.error,message:"Claude 额度接口限流，稍后重试。",retryAfter:until.timeIntervalSince(now))
        }
        do {
            var result = try await oauth(); try validate(captured)
            defaults.removeObject(forKey:backoffKey); consecutiveRateLimits = 0
            result.accountID = QuotaParser.fingerprint("claude:" + (org ?? ClaudeProfile.default().configDirectory.path))
            result.message = nil
            return result
        } catch let failure as AIProviderError {
            try validate(captured)
            if let hint = failure.retryAfter {
                let delay = min(900,max(60 * pow(2,Double(min(consecutiveRateLimits,4))),hint))
                consecutiveRateLimits += 1
                defaults.set(now.addingTimeInterval(delay),forKey:backoffKey)
                throw AIProviderError(status:failure.status,message:failure.message,retryAfter:delay)
            }
            throw failure
        }
    }
}
