import Foundation
import Darwin
struct AISession: Codable, Equatable {
    var id: String
    var provider: AIProvider
    var name: String
    var state: String
    var evidence: String
    var updatedAt: Date
}
struct AISessionRules: Codable {
    private var previous: [String: AISession] = [:]
    mutating func observe(_ sessions: [AISession], now: Date) -> [AIAlert] {
        var alerts: [AIAlert] = []
        for session in sessions {
            let key = session.provider.rawValue + ":" + session.id
            guard let old = previous[key], old.state != session.state,
                  old.evidence == "explicit", session.evidence == "explicit",
                  session.updatedAt > old.updatedAt,
                  now.timeIntervalSince(session.updatedAt) >= -60,
                  now.timeIntervalSince(session.updatedAt) <= 60 else { continue }
            let waiting = session.state == "waiting" && old.state == "busy"
            let ended = ["ended", "success", "failure"].contains(session.state)
                || (old.state == "busy" && session.state == "idle")
            guard waiting || ended else { continue }
            let active = sessions.filter { $0.provider == session.provider && $0.id != session.id && $0.state == "busy" }.count
            let text = waiting ? "有 1 个任务等待你的操作。" : (session.state == "failure" ? "有 1 个任务报告失败。" : "有 1 个任务本轮已结束。")
            alerts.append(AIAlert(id: "session:\(key):\(session.updatedAt.timeIntervalSince1970):\(session.state)",
                                  provider: session.provider, title: "\(session.provider.title) · \(session.name)",
                                  body: text + (active > 0 ? "另有 \(active) 个进行中。" : ""),
                                  priority: waiting ? 0 : (session.state == "failure" ? 1 : 2),
                                  createdAt: now, expiresAt: now.addingTimeInterval(waiting ? 300 : 60),
                                  sessionID: session.id, kind: waiting ? "waiting" : "ended"))
        }
        previous = Dictionary(sessions.map { ($0.provider.rawValue + ":" + $0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        return alerts
    }
}

/// Bounded, read-only observations. No transcript text is retained or returned.
enum AISessionReader {
    private struct Cached {
        var modifiedAt: Date
        var size: Int
        var session: AISession?
        var pid: Int32? = nil
        var processStartedAt: Date? = nil
    }
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: Cached] = [:]
        private var generation: UInt64 = 0
        func lookup(_ path: String, modifiedAt: Date, size: Int) -> (Cached?, UInt64) {
            lock.lock(); defer { lock.unlock() }
            let entry = entries[path]
            return (entry?.modifiedAt == modifiedAt && entry?.size == size ? entry : nil, generation)
        }
        func store(_ value: Cached, path: String, generation expected: UInt64) {
            lock.lock(); defer { lock.unlock() }
            guard expected == generation else { return }
            entries[path] = value
            while entries.count > 128, let key = entries.keys.first { entries.removeValue(forKey: key) }
        }
        func version() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            return generation
        }
        func prune(keeping paths: Set<String>, generation expected: UInt64) {
            lock.lock(); defer { lock.unlock() }
            guard expected == generation else { return }
            entries = entries.filter { paths.contains($0.key) }
        }
        func clear() {
            lock.lock(); defer { lock.unlock() }
            generation &+= 1; entries.removeAll()
        }
    }
    private static let cache = Cache()
    static func clearCache() { cache.clear() }

    static func read(enabled: Set<AIProvider>) -> [AISession] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let now = Date()
        var sessions: [AISession] = []
        var inspected = Set<String>()
        let readGeneration = cache.version()
        defer { cache.prune(keeping: inspected, generation: readGeneration) }
        if enabled.contains(.claude) {
            let dir = home.appendingPathComponent(".claude/sessions")
            for file in files(dir, suffix: "json").prefix(64) {
                inspected.insert(file.path)
                guard let signature = signature(file), signature.size <= 64 * 1024 else { continue }
                let (existing, _) = cache.lookup(file.path, modifiedAt: signature.modifiedAt, size: signature.size)
                if let existing {
                    // Never cache liveness: a PID can exit or be recycled while the file stays unchanged.
                    if let pid = existing.pid, let expected = existing.processStartedAt,
                       let actual = processStart(pid), abs(actual.timeIntervalSince(expected)) <= 1,
                       let session = existing.session { sessions.append(session) }
                    continue
                }
                var entry = Cached(modifiedAt: signature.modifiedAt, size: signature.size, session: nil)
                if let data = smallFile(file, maxBytes: 64 * 1024),
                   let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let pid = (json["pid"] as? NSNumber)?.int32Value, pid > 0, let start = processStart(pid),
                   let session = parseClaude(json, processStartedAt: start) {
                    entry.session = session; entry.pid = pid; entry.processStartedAt = start
                    sessions.append(session)
                }
                cache.store(entry, path: file.path, generation: readGeneration)
            }
        }
        if enabled.contains(.codex) {
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".codex")
            // Scan only today and yesterday, never recurse through session history.
            let date = DateFormatter(); date.dateFormat = "yyyy/MM/dd"; date.locale = Locale(identifier: "en_US_POSIX")
            date.timeZone = TimeZone(secondsFromGMT: 0)
            var recent: [URL] = []
            for offset in [0.0, -86400.0] {
                let directory = codexHome.appendingPathComponent("sessions/" + date.string(from: now.addingTimeInterval(offset)))
                recent += files(directory, suffix: "jsonl")
            }
            let candidates = recent.compactMap { file -> (URL, Date, Int)? in
                guard let value = signature(file) else { return nil }
                return (file, value.modifiedAt, value.size)
            }.sorted { $0.1 > $1.1 }.prefix(12)
            for (file, mtime, size) in candidates where now.timeIntervalSince(mtime) < 900 {
                inspected.insert(file.path)
                let session = readCodexFile(file, modifiedAt: mtime, size: size, now: now, generation: readGeneration) {
                    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
                    defer { try? handle.close() }
                    let offset = size > 262144 ? UInt64(size - 262144) : 0
                    guard (try? handle.seek(toOffset: offset)) != nil,
                          var data = try? handle.read(upToCount: 262144) else { return nil }
                    // Drop an incomplete leading record when reading a tail.
                    if offset > 0, let newline = data.firstIndex(of: 10) { data.removeSubrange(...newline) }
                    return data
                }
                if let session { sessions.append(session) }
            }
        }
        return sessions
    }
    static func readCodexFile(_ file: URL, modifiedAt: Date, size: Int, now: Date, generation expectedGeneration: UInt64? = nil, load: () -> Data?) -> AISession? {
        let (existing, generation) = cache.lookup(file.path, modifiedAt: modifiedAt, size: size)
        let stored: AISession?
        if let existing { stored = existing.session }
        else {
            // Cache only normalized state, never raw records or transcript text.
            stored = load().flatMap { parseCodexTail($0, id: file.deletingPathExtension().lastPathComponent,
                                                    modifiedAt: modifiedAt, now: modifiedAt) }
            cache.store(Cached(modifiedAt: modifiedAt, size: size, session: stored), path: file.path, generation: expectedGeneration ?? generation)
        }
        guard var session = stored else { return nil }
        let age = now.timeIntervalSince(modifiedAt)
        if session.state == "busy", age > (session.evidence == "derived" ? 8 : 120) {
            session.state = "unknown"; session.evidence = "unknown"
        }
        return session
    }
    private static func signature(_ file: URL) -> (modifiedAt: Date, size: Int)? {
        guard let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modifiedAt = attrs.contentModificationDate, let size = attrs.fileSize else { return nil }
        return (modifiedAt, size)
    }
    static func parseClaude(_ json: [String: Any], processStartedAt: Date) -> AISession? {
        guard let pid = (json["pid"] as? NSNumber)?.int32Value, let cwd = json["cwd"] as? String else { return nil }
        var reportedStart = (json["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        if reportedStart == nil, let text = json["procStart"] as? String {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            reportedStart = formatter.date(from: text.split(separator: " ").joined(separator: " "))
        }
        // Without a process identity, even a live reused PID cannot justify explicit state.
        guard let started = reportedStart, abs(started.timeIntervalSince(processStartedAt)) <= 5 else { return nil }
        let raw = json["status"] as? String
        let tempo = json["tempo"] as? String
        let state: String
        switch (tempo, raw) {
        case ("blocked", _), (_, "waiting"): state = "waiting"
        case ("active", _), (_, "busy"): state = "busy"
        case ("idle", _), (_, "idle"): state = "idle"
        default: state = "unknown"
        }
        let millis = (json["statusUpdatedAt"] as? NSNumber)?.doubleValue ?? (json["updatedAt"] as? NSNumber)?.doubleValue
        let updatedAt = millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? started
        return AISession(id: "claude-\(pid)-\(Int(started.timeIntervalSince1970))", provider: .claude,
                         name: (cwd as NSString).lastPathComponent, state: state,
                         evidence: state == "unknown" ? "unknown" : "explicit", updatedAt: updatedAt)
    }
    static func parseCodexTail(_ data: Data, id: String, modifiedAt: Date, now: Date) -> AISession? {
        let formatter = ISO8601DateFormatter()
        var currentTurn: String?
        var latestState: String?
        var latestTime: Date?
        // Match completions to the most recently observed start. An older turn's
        // delayed completion must not end a newer turn in the same rollout.
        for line in data.split(separator: 10) {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  json["type"] as? String == "event_msg", let payload = json["payload"] as? [String: Any],
                  let event = payload["type"] as? String, ["task_started", "task_complete", "turn_aborted"].contains(event),
                  let stamp = json["timestamp"] as? String else { continue }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var timestamp = formatter.date(from: stamp)
            if timestamp == nil { formatter.formatOptions = [.withInternetDateTime]; timestamp = formatter.date(from: stamp) }
            guard let time = timestamp else { continue }
            let turn = payload["turn_id"] as? String ?? payload["task_id"] as? String
            if event == "task_started" {
                currentTurn = turn; latestState = "busy"; latestTime = time
            } else {
                if let currentTurn, turn != currentTurn, !(event == "turn_aborted" && turn == nil) { continue }
                latestState = event == "turn_aborted" ? "unknown" : "ended"; latestTime = time
            }
        }
        if let state = latestState, let time = latestTime {
            // A crashed process may leave task_started behind indefinitely.
            let uncertain = state == "busy" && now.timeIntervalSince(modifiedAt) > 120
            return AISession(id: id, provider: .codex, name: "本地任务", state: uncertain ? "unknown" : state,
                             evidence: uncertain || state == "unknown" ? "unknown" : "explicit", updatedAt: time)
        }
        let active = now.timeIntervalSince(modifiedAt) <= 8
        return AISession(id: id, provider: .codex, name: "本地任务", state: active ? "busy" : "unknown", evidence: active ? "derived" : "unknown", updatedAt: modifiedAt)
    }
    private static func files(_ directory: URL, suffix: String) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]))?.filter { $0.pathExtension == suffix } ?? []
    }
    private static func smallFile(_ url: URL, maxBytes: Int) -> Data? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBytes else { return nil }
        return try? Data(contentsOf: url)
    }
    private static func processStart(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard count == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }
}
