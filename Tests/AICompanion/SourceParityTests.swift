import Foundation
@MainActor func runSourceParityTests() async throws {
    let suite = "naigrey.sources.\(UUID().uuidString)", now = Date()
    let defaults = UserDefaults(suiteName:suite)!
    defer { defaults.removePersistentDomain(forName:suite) }
    let windows = [LimitWindow(id:"session",label:"Session",usedFraction:0.42,resetsAt:now.addingTimeInterval(600))]
    var desktopReads = 0, cliReads = 0, oauthReads = 0
    var desktopValue:ClaudeDesktopUsageCache.Reading? = .init(windows:windows,capturedAt:now,entry:URL(fileURLWithPath:"/fixture/cache"))
    var org = "org-a", current = now
    let sources = ClaudeQuotaSources(defaults:defaults,organization:{org},clock:{current},desktop:{ requested in
        precondition(requested == org); desktopReads += 1; return desktopValue
    },cli:{ cliReads += 1; return windows },oauth:{
        oauthReads += 1
        throw AIProviderError(status:.error,message:"rate limit fixture",retryAfter:60)
    })
    let first = try await sources.fetch()
    precondition(first.source.contains("Desktop") && cliReads == 0 && oauthReads == 0, "Desktop must win without reading any credential")
    desktopValue = .init(windows:windows,capturedAt:now.addingTimeInterval(-1801),entry:URL(fileURLWithPath:"/fixture/cache"))
    let second = try await sources.fetch()
    precondition(second.source.contains("CLI") && cliReads == 1 && oauthReads == 0, "Stale Desktop falls through to CLI")
    _ = try await sources.fetch()
    precondition(cliReads == 1 && desktopReads == 2, "CLI cache and Desktop miss throttled for five minutes")
    org = "org-b"
    let switched = try await sources.fetch()
    precondition(switched.accountID != first.accountID && cliReads == 2, "Organization change cannot reuse the other account's CLI cache")
    // Separate provider: failed CLI is retried after 5 minutes, while OAuth backs off.
    var fallbackCLI = 0, fallbackOAuth = 0
    let fallback = ClaudeQuotaSources(defaults:defaults,organization:{nil},clock:{current},desktop:{_ in nil},cli:{
        fallbackCLI += 1; throw AIProviderError(status:.unsupported,message:"fixture")
    },oauth:{
        fallbackOAuth += 1; throw AIProviderError(status:.error,message:"429",retryAfter:60)
    })
    do { _ = try await fallback.fetch(); preconditionFailure("429 must fail") } catch {}
    do { _ = try await fallback.fetch(); preconditionFailure("backoff must hold") } catch {}
    precondition(fallbackCLI == 1 && fallbackOAuth == 1, "Miss and rate-limit backoffs are independent")
    current = now.addingTimeInterval(60)
    do { _ = try await fallback.fetch(); preconditionFailure("429 must fail") } catch {}
    precondition(fallbackOAuth == 2, "OAuth retry deadline expires")
    current = now.addingTimeInterval(120)
    do { _ = try await fallback.fetch(); preconditionFailure("second backoff must hold") } catch {}
    precondition(fallbackOAuth == 2, "Repeated 429 doubles penalty")
    let liveDesktop = ClaudeQuotaSources(defaults:defaults,organization:{"org-a"},clock:{current},desktop:{_ in .init(windows:windows,capturedAt:current,entry:URL(fileURLWithPath:"/fixture"))},cli:{ preconditionFailure("desktop wins") },oauth:{ preconditionFailure("backoff must not block desktop") })
    let duringBackoff = try await liveDesktop.fetch()
    precondition(duringBackoff.source.contains("Desktop"), "Endpoint backoff must not block other sources")
    // CLI's year/zone parsing and ResetCopy's rounding are upstream, exercised here.
    let cliWindows = try ClaudeUsageCLI.parse("Current session: 38% used · resets Jan 2 at 3pm (Asia/Taipei)",now:ISO8601DateFormatter().date(from:"2026-12-31T00:00:00Z")!)
    precondition(cliWindows[0].resetsAt == ISO8601DateFormatter().date(from:"2027-01-02T07:00:00Z"))
    precondition(ResetCopy.text(for:now.addingTimeInterval(61),now:now,format:.remaining).contains("1 分钟"), "Round minutes instead of ceiling")
}
