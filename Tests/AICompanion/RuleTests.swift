import Foundation
private enum RuleFailure: Error { case failed(String) }
func runRuleTests() throws {
    func check(_ value: Bool, _ name: String) throws { if !value { throw RuleFailure.failed(name) } }
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    func sample(_ used: Double, _ offset: Double, account: String = "a", reset: Double = 100, status: AIStatus = .ok, period: Double? = 100) -> AIUsage {
        AIUsage(provider: .codex, accountID: account, status: status, source: "fixture", sourceAt: t.addingTimeInterval(offset), observedAt: t.addingTimeInterval(offset), windows: [AILimit(id: "primary", label: "5 小时", usedFraction: used, resetAt: t.addingTimeInterval(reset), periodSeconds: period)], message: nil)
    }
    var rules = AIEventRules()
    func observe(_ used: Double, _ offset: Double) -> [AIAlert] { rules.observe(sample(used, offset), now: t.addingTimeInterval(offset)) }
    try check(observe(0.79, 0).isEmpty, "baseline silent")
    let firstAlert = observe(0.80, 1)
    try check(firstAlert.count == 1, "20 crossing")
    try check(firstAlert.first?.body.contains("重置") == true, "known reset in reminder")
    try check(observe(0.79, 2).isEmpty && observe(0.81, 3).isEmpty, "jitter dedup")
    rules = try JSONDecoder().decode(AIEventRules.self, from: JSONEncoder().encode(rules))
    try check(observe(0.82, 4).isEmpty, "restart dedup")
    try check(observe(0.90, 5).count == 1, "10 crossing")
    try check(observe(1, 6).count == 1, "exhausted crossing")
    try check(rules.observe(sample(0.01, 7, account: "b"), now: t.addingTimeInterval(7)).isEmpty, "account change silent")
    rules = AIEventRules()
    _ = observe(0.65, 0)
    try check(observe(1, 1).count == 1, "jump only one event")
    try check(rules.observe(sample(0.01, 101, reset: 200), now: t.addingTimeInterval(101)).count == 1, "confirmed reset recovery")
    try check(observe(Double.nan, 102).isEmpty, "invalid no events")
    try check(rules.observe(sample(1, 103, status: .stale), now: t.addingTimeInterval(103)).isEmpty, "stale no events")
    var unknown = AIEventRules()
    _ = unknown.observe(sample(0.7, 0, period: nil), now: t)
    _ = unknown.observe(sample(1, 1, period: nil), now: t.addingTimeInterval(1))
    try check(unknown.observe(sample(0.01, 101, reset: 200, period: nil), now: t.addingTimeInterval(101)).isEmpty, "unknown period no reset")
    var delayed = AIEventRules()
    _ = delayed.observe(sample(0.7, 0), now: t)
    try check(delayed.observe(sample(1, 1), now: t.addingTimeInterval(1000)).isEmpty, "old read silent")
    var firstLow = AIEventRules()
    try check(firstLow.observe(sample(0.97, 0), now: t).isEmpty, "first low silent")
    _ = firstLow.observe(sample(0.7, 1), now: t.addingTimeInterval(1))
    try check(firstLow.observe(sample(0.95, 2), now: t.addingTimeInterval(2)).isEmpty, "baseline low bounce does not rearm")
    try check(firstLow.observe(sample(0.1, 101, reset: 200), now: t.addingTimeInterval(101)).isEmpty, "silent baseline never celebrates recovery")
    var confirmTwice = AIEventRules()
    _ = confirmTwice.observe(sample(0.7, 0), now: t)
    _ = confirmTwice.observe(sample(0.9, 1), now: t.addingTimeInterval(1))
    try check(confirmTwice.observe(sample(0.89, 101, reset: 200), now: t.addingTimeInterval(101)).isEmpty, "small drop needs confirmation")
    try check(confirmTwice.observe(sample(0.89, 101, reset: 200), now: t.addingTimeInterval(120)).isEmpty, "same cache not independent")
    try check(confirmTwice.observe(sample(0.89, 116, reset: 200), now: t.addingTimeInterval(116)).count == 1, "second confirmation recovers relative to previous cycle")
    try check(confirmTwice.observe(sample(0.91, 117, reset: 200), now: t.addingTimeInterval(117)).count == 1, "confirmed new cycle rearms thresholds")
    var noTime = AIEventRules()
    var missing = sample(0.7, 0); missing.windows[0].resetAt = nil
    _ = noTime.observe(missing, now: t)
    missing = sample(1, 1); missing.windows[0].resetAt = nil
    _ = noTime.observe(missing, now: t.addingTimeInterval(1))
    missing = sample(0.01, 102); missing.windows[0].resetAt = nil
    try check(noTime.observe(missing, now: t.addingTimeInterval(102)).isEmpty, "missing reset no recovery")

    var cached = AIEventRules()
    _ = cached.observe(sample(0.7, 0), now: t)
    let cachedAlerts = cached.observe(sample(0.9, 1), now: t.addingTimeInterval(400))
    try check(cachedAlerts.allSatisfy { $0.expiresAt <= t.addingTimeInterval(400) }, "old cache crossing cannot replay fresh bubble")

}
