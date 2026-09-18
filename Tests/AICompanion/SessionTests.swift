import Foundation
import Darwin
private enum SessionFailure: Error { case failed(String) }
func runSessionTests() throws {
    func check(_ value: Bool, _ name: String) throws { if !value { throw SessionFailure.failed(name) } }
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    var rules = AISessionRules()
    func s(_ state: String, _ n: Double, evidence: String = "explicit") -> AISession {
        AISession(id: "fixture", provider: .claude, name: "fixture", state: state, evidence: evidence, updatedAt: t.addingTimeInterval(n))
    }
    try check(rules.observe([s("busy", 0)], now: t).isEmpty, "first busy silent")
    try check(rules.observe([s("waiting", 1)], now: t.addingTimeInterval(1)).count == 1, "waiting transition")
    try check(rules.observe([s("waiting", 1)], now: t.addingTimeInterval(2)).isEmpty, "waiting dedup")
    try check(rules.observe([s("idle", 3)], now: t.addingTimeInterval(3)).isEmpty, "waiting idle not completion")
    _ = rules.observe([s("busy", 4)], now: t.addingTimeInterval(4))
    try check(rules.observe([s("idle", 5)], now: t.addingTimeInterval(5)).count == 1, "busy idle means ended")
    _ = rules.observe([s("busy", 6)], now: t.addingTimeInterval(6))
    try check(rules.observe([], now: t.addingTimeInterval(7)).isEmpty, "disappearance silent")
    try check(rules.observe([s("ended", 8)], now: t.addingTimeInterval(8)).isEmpty, "reappearance silent")
    _ = rules.observe([s("busy", 9, evidence: "derived")], now: t.addingTimeInterval(9))
    try check(rules.observe([s("ended", 10)], now: t.addingTimeInterval(10)).isEmpty, "derived no completion")
    let record: [String: Any] = ["pid": 123, "cwd": "/synthetic/project", "status": "waiting", "startedAt": t.timeIntervalSince1970 * 1000, "updatedAt": t.timeIntervalSince1970 * 1000]
    try check(AISessionReader.parseClaude(record, processStartedAt: t)?.state == "waiting", "Claude explicit field")
    try check(AISessionReader.parseClaude(record, processStartedAt: t.addingTimeInterval(100)) == nil, "PID reuse rejected")
    let line = "{\"timestamp\":\"2027-01-15T08:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}"
    try check(AISessionReader.parseCodexTail(Data(line.utf8), id: "fixture", modifiedAt: t, now: t)?.state == "ended", "Codex lifecycle")
    try check(AISessionReader.parseCodexTail(Data("{\"type\":\"message\"}".utf8), id: "fixture", modifiedAt: t.addingTimeInterval(-9), now: t)?.state == "unknown", "silence unknown")
    let overlapping = """
    {"timestamp":"2027-01-15T08:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"current"}}
    {"timestamp":"2027-01-15T08:00:01Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"previous"}}
    """
    try check(AISessionReader.parseCodexTail(Data(overlapping.utf8), id: "fixture", modifiedAt: t, now: t)?.state == "busy", "unrelated turn completion cannot end current turn")

    let aborted = overlapping + "\n" + #"{"timestamp":"2027-01-15T08:00:02Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"current"}}"#
    try check(AISessionReader.parseCodexTail(Data(aborted.utf8), id: "fixture", modifiedAt: t, now: t)?.state == "unknown", "aborted turn is not busy or success")

    AISessionReader.clearCache()
    let path = URL(fileURLWithPath: "/synthetic/cache-fixture.jsonl")
    var loads = 0
    func load() -> Data? { loads += 1; return Data(overlapping.utf8) }
    _ = AISessionReader.readCodexFile(path, modifiedAt: t, size: 123, now: t, load: load)
    let aged = AISessionReader.readCodexFile(path, modifiedAt: t, size: 123, now: t.addingTimeInterval(121), load: load)
    try check(loads == 1, "unchanged file is read and parsed once")
    try check(aged?.state == "unknown", "cached explicit busy ages to unknown")
    _ = AISessionReader.readCodexFile(path, modifiedAt: t, size: 124, now: t, load: load)
    try check(loads == 2, "size changes invalidate cache")
    _ = AISessionReader.readCodexFile(path, modifiedAt: t.addingTimeInterval(1), size: 124, now: t, load: load)
    try check(loads == 3, "mtime changes invalidate cache")
    AISessionReader.clearCache()
    _ = AISessionReader.readCodexFile(path, modifiedAt: t.addingTimeInterval(1), size: 124, now: t, load: load)
    try check(loads == 4, "disconnect clears cached sessions")
    AISessionReader.clearCache()
    let derivedData = Data("{}".utf8)
    _ = AISessionReader.readCodexFile(path, modifiedAt: t, size: 2, now: t, load: { derivedData })
    let derivedAged = AISessionReader.readCodexFile(path, modifiedAt: t, size: 2, now: t.addingTimeInterval(9), load: { derivedData })
    try check(derivedAged?.state == "unknown", "cached derived activity ages after eight seconds")
    AISessionReader.clearCache()

    let anonymousAbort = overlapping + "\n" + #"{"timestamp":"2027-01-15T08:00:02Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#
    try check(AISessionReader.parseCodexTail(Data(anonymousAbort.utf8), id: "fixture", modifiedAt: t, now: t)?.state == "unknown", "aborted without turn id clears busy conservatively")

    let temporaryHome = FileManager.default.temporaryDirectory.appendingPathComponent("naihui-session-fixture-" + UUID().uuidString)
    let oldHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
    defer {
        if let oldHome { setenv("CODEX_HOME", oldHome, 1) } else { unsetenv("CODEX_HOME") }
        AISessionReader.clearCache()
        try? FileManager.default.removeItem(at: temporaryHome)
    }
    let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX")
    date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "yyyy/MM/dd"
    let fixtureDirectory = temporaryHome.appendingPathComponent("sessions/" + date.string(from: Date()))
    try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    try Data(overlapping.utf8).write(to: fixtureDirectory.appendingPathComponent("synthetic.jsonl"))
    setenv("CODEX_HOME", temporaryHome.path, 1)
    let customHomeSessions = AISessionReader.read(enabled: [.codex])
    try check(customHomeSessions.count == 1 && customHomeSessions.first?.id == "synthetic", "activity follows CODEX_HOME")

}
