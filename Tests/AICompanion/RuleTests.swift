import Foundation
private enum RuleFailure: Error { case failed(String) }
@MainActor func runRuleTests() throws {
    func check(_ value: Bool, _ name: String) throws { if !value { throw RuleFailure.failed(name) } }
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    func sample(_ used: Double, _ offset: Double, reset: Double? = 100, weekly: Double = 0.2) -> AIUsage {
        AIUsage(provider:.codex, accountID:"fixture", status:.ok, source:"fixture", sourceAt:t.addingTimeInterval(offset), observedAt:t.addingTimeInterval(offset), windows:[AILimit(id:"primary",label:"Session",usedFraction:used,resetAt:reset.map { t.addingTimeInterval($0) }), AILimit(id:"secondary",label:"Weekly",usedFraction:weekly)])
    }
    var rules = AIEventRules()
    func observe(_ used:Double,_ offset:Double)->[AIAlert] { rules.observe(sample(used,offset),now:t.addingTimeInterval(offset)) }
    try check(observe(0.85,0).contains { $0.kind == "threshold-20" }, "Codenotch alerts on first reading already above 80%")
    try check(observe(0.9,1).isEmpty, "No separate 90% alert")
    try check(observe(0.79,2).isEmpty, "Small fall only rearms")
    try check(observe(0.8,3).contains { $0.kind == "threshold-20" }, "Falling below 80% rearms crossing")
    try check(observe(1,4).contains { $0.kind == "threshold-0" }, "100% crossing")
    try check(observe(1,5).isEmpty, "Repeated exhaustion silent")
    rules = AIEventRules()
    _ = observe(0.7,0)
    let jump = observe(1,1)
    try check(jump.contains { $0.kind == "threshold-20" } && jump.contains { $0.kind == "threshold-0" }, "Jump emits both 80 and 100 crossings")
    try check(observe(0.6,2).contains { $0.kind == "reset" }, "20 point decrease detects reset even without date rollover")
    rules = AIEventRules()
    _ = observe(0.3,0)
    try check(rules.observe(sample(0.29,1,reset:200),now:t.addingTimeInterval(1)).contains { $0.kind == "reset" }, "Advancing reset date with peak >=15% fires immediately")
    rules = AIEventRules()
    _ = observe(0.1,0)
    try check(rules.observe(sample(0,1,reset:200),now:t.addingTimeInterval(1)).isEmpty, "Tiny usage reset is silent")
    rules = AIEventRules()
    _ = rules.observe(sample(0.2,0,weekly:0.79),now:t)
    try check(rules.observe(sample(0.2,1,weekly:0.8),now:t.addingTimeInterval(1)).isEmpty, "Weekly does not use headline 80% notifier")
    try check(rules.observe(sample(0.2,2,weekly:1),now:t.addingTimeInterval(2)).contains { $0.windowID == "secondary" }, "Weekly exhaustion alert")
}
