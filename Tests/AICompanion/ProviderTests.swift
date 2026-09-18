import Foundation

private struct ProviderTestFailure: Error { let message: String }
func runProviderTests() throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ProviderTestFailure(message: message) }
    }
    func fixture(_ text: String) -> Data { Data(text.utf8) }
    func failure(_ expected: AIStatus, _ operation: () throws -> Void) throws {
        do { try operation(); throw ProviderTestFailure(message: "Expected \(expected)") }
        catch let error as AIProviderError { try check(error.status == expected, "Wrong status") }
    }
    var generation = QuotaReadGeneration()
    let blockedRead = generation.value
    try check(generation.accepts(blockedRead), "Current authorization read accepted")
    generation.invalidate()
    try check(!generation.accepts(blockedRead), "Disconnect invalidates blocked authorization read")
    let reconnectedRead = generation.value
    try check(generation.accepts(reconnectedRead) && !generation.accepts(blockedRead), "Reconnect cannot revive old read")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let codex = try QuotaParser.codex(fixture(#"{"rate_limit":{"primary_window":{"used_percent":80,"limit_window_seconds":18000,"reset_at":1800018000},"secondary_window":{"used_percent":null,"limit_window_seconds":604800}},"additional_rate_limits":[{"metered_feature":"spark","limit_name":"Spark","rate_limit":{"primary_window":{"used_percent":25}}}]}"#), now: now)
    try check(codex.count == 3, "Codex extra missing")
    try check(codex[0].usedFraction == 0.8 && codex[0].resetAt == now.addingTimeInterval(18000), "Codex values")
    try check(codex[1].usedFraction == nil && codex[1].resetAt == nil, "Unknown must remain unknown")
    let malformed = try QuotaParser.codex(fixture(#"{"rate_limit":{"primary_window":{"used_percent":true},"secondary_window":{"used_percent":101}}}"#))
    try check(malformed.allSatisfy { $0.usedFraction == nil }, "Invalid percentages must not become usage")
    try failure(.unsupported) { _ = try QuotaParser.codex(fixture(#"{"new_shape":{}}"#)) }
    let relative = try QuotaParser.codex(fixture(#"{"rate_limit":{"primary_window":{"used_percent":0,"reset_after_seconds":30}}}"#), now: now)
    try check(relative[0].resetAt == now.addingTimeInterval(30), "Relative reset")
    let claude = try QuotaParser.claude(fixture(#"{"limits":[{"kind":"session","percent":62,"resets_at":"2027-01-15T09:00:00.123Z"},{"kind":"weekly_scoped","percent":20,"scope":{"model":{"display_name":"A model"}}},{"kind":"mystery","percent":null}],"seven_day":{"utilization":12,"resets_at":null}}"#))
    try check(claude.count == 4 && claude[0].id == "session" && claude[1].id == "weekly", "Claude normalized windows")
    try check(claude[0].resetAt != nil && claude[1].resetAt == nil, "Fractional ISO date and unknown reset")
    try check(claude.first { $0.id == "weekly_scoped" }?.label == "A model", "Scoped display name")
    try failure(.unsupported) { _ = try QuotaParser.claude(fixture("[]")) }
    try failure(.needsAuth) { try QuotaParser.checkHTTP(status: 401) }
    try failure(.needsAuth) { try QuotaParser.checkHTTP(status: 403) }
    try failure(.error) { try QuotaParser.checkHTTP(status: 302) }
    do { try QuotaParser.checkHTTP(status: 429, retryAfter: "120"); throw ProviderTestFailure(message: "429 accepted") }
    catch let error as AIProviderError { try check(error.retryAfter == 120, "Retry-After seconds") }
    do { try QuotaParser.checkHTTP(status: 429, retryAfter: "Fri, 15 Jan 2027 08:05:00 GMT", now: now); throw ProviderTestFailure(message: "429 accepted") }
    catch let error as AIProviderError { try check(error.retryAfter == 300, "Retry-After date") }
    try failure(.unsupported) { _ = try QuotaParser.codexCredential(fixture(#"{"OPENAI_API_KEY":"fake"}"#)) }
    let credential = try QuotaParser.codexCredential(fixture(#"{"tokens":{"access_token":"fixture-only","account_id":"account-fixture"}}"#))
    try check(credential.fingerprint.count == 64 && !credential.fingerprint.contains("account-fixture"), "Anonymized account")
    try failure(.needsAuth) { _ = try QuotaParser.claudeCredential(fixture(#"{"claudeAiOauth":{"accessToken":"fake","expiresAt":0}}"#), now: now) }
    let first = try QuotaParser.claudeCredential(fixture(#"{"claudeAiOauth":{"accessToken":"fake-a","expiresAt":1900000000000}}"#), now: now)
    let second = try QuotaParser.claudeCredential(fixture(#"{"claudeAiOauth":{"accessToken":"fake-b","expiresAt":1900000000000}}"#), now: now)
    try check(first.fingerprint != second.fingerprint, "Claude credential epochs must not mix")
    try check(!codex[0].isExtra && codex[2].isExtra, "Codex extras classified")
    try check(claude.filter { $0.id != "session" && $0.id != "weekly" }.allSatisfy(\.isExtra), "Claude extras classified")
    let unlimited = try QuotaParser.codex(fixture(#"{"rate_limit":{"unlimited":true}}"#))
    try check(unlimited.count == 1 && unlimited[0].unlimited && unlimited[0].usedFraction == nil, "Explicit unlimited group")
    let windowUnlimited = try QuotaParser.codex(fixture(#"{"rate_limit":{"primary_window":{"unlimited":true,"used_percent":10},"secondary_window":{"unlimited":1}}}"#))
    try check(windowUnlimited[0].unlimited && windowUnlimited[0].usedFraction == nil && !windowUnlimited[1].unlimited, "Only boolean unlimited")
    let credits = try QuotaParser.codex(fixture(#"{"credits":{"unlimited":true},"rate_limit":{"primary_window":{}}}"#))
    try check(!credits[0].unlimited && credits[0].usedFraction == nil, "Credit unlimited must not imply unlimited subscription")
    let unknown = try QuotaParser.claude(fixture(#"{"limits":[{"kind":"weekly_future","percent":12,"resets_at":"2027-01-15T09:00:00Z"}]}"#))
    try check(unknown[0].isExtra && unknown[0].periodSeconds == nil, "Unknown kind has no invented duration")
    let legacy = try JSONDecoder().decode(AILimit.self, from: fixture(#"{"id":"primary","label":"Quota"}"#))
    try check(!legacy.isExtra && !legacy.unlimited, "Legacy cache defaults")
    let services = QuotaParser.claudeKeychainServices(defaultDirectory: "/fixture/.claude")
    let customService = "Claude Code-credentials-" + String(QuotaParser.fingerprint("/fixture/.claude-work").prefix(8))
    try check(services.count == 2 && !services.contains(customService) && services.contains("Claude Code-credentials"), "Default Claude services exclude work profile")
    let usage = AIUsage(provider: .codex, accountID: credential.fingerprint, status: .ok, source: "fixture", sourceAt: now, observedAt: now, windows: codex)
    let roundtrip = try JSONDecoder().decode(AIUsage.self, from: JSONEncoder().encode(usage))
    try check(roundtrip == usage, "Codable date roundtrip")
}
