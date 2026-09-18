import Foundation
struct AIAlert: Codable, Equatable {
    var id: String
    var provider: AIProvider
    var title: String
    var body: String
    var priority: Int
    var createdAt: Date
    var expiresAt: Date
    var windowID: String? = nil
    var sessionID: String? = nil
    var kind: String? = nil
    var accountID: String? = nil
}
struct AIEventRules: Codable {
    var thresholds: [Int] = [20, 10, 0]
    private struct Window: Codable {
        var used: Double
        var sourceAt: Date
        var resetAt: Date?
        var period: Double?
        var epoch: Int = 0
        var fired: Set<Int> = []
        var hasAlerted: Bool? = false
        var candidateReset: Date?
        var candidateAt: Date?
        var candidateUsed: Double?
    }
    private var accounts: [String: String] = [:]
    private var windows: [String: Window] = [:]
    mutating func forget(_ provider: AIProvider) {
        accounts.removeValue(forKey: provider.rawValue)
        windows = windows.filter { !$0.key.hasPrefix(provider.rawValue + ":") }
    }
    mutating func observe(_ usage: AIUsage, now: Date) -> [AIAlert] {
        guard usage.status == .ok, !usage.accountID.isEmpty,
              now.timeIntervalSince(usage.sourceAt) >= -60,
              now.timeIntervalSince(usage.sourceAt) <= 900 else { return [] }
        if accounts[usage.provider.rawValue] != usage.accountID {
            forget(usage.provider)
            accounts[usage.provider.rawValue] = usage.accountID
        }
        var result: [AIAlert] = []
        for limit in usage.windows {
            guard !limit.unlimited, let used = limit.usedFraction, used.isFinite, (0...1).contains(used) else { continue }
            let key = usage.provider.rawValue + ":" + limit.id
            guard var old = windows[key] else {
                var baseline = Window(used: used, sourceAt: usage.sourceAt, resetAt: limit.resetAt, period: limit.periodSeconds)
                baseline.fired = Set(thresholds.filter { (0...100).contains($0) && used >= 1 - Double($0) / 100 })
                windows[key] = baseline
                continue
            }
            guard usage.sourceAt > old.sourceAt else { continue }
            var confirmed = false
            // A positive period is supplied only for a known fixed-cycle window.
            if let period = old.period, period > 0, limit.periodSeconds == period,
               let previousReset = old.resetAt, let reset = limit.resetAt,
               usage.sourceAt >= previousReset, reset > previousReset, reset > usage.sourceAt {
                if old.used - used >= 0.05 { confirmed = true }
                else if old.candidateReset == reset, let candidateAt = old.candidateAt,
                        usage.sourceAt.timeIntervalSince(candidateAt) >= 15 { confirmed = true }
                else if old.candidateReset != reset {
                    old.candidateReset = reset; old.candidateAt = usage.sourceAt; old.candidateUsed = old.used
                }
            } else {
                old.candidateReset = nil; old.candidateAt = nil; old.candidateUsed = nil
            }
            let remaining = 100 * (1 - used)
            if confirmed {
                if old.hasAlerted == true, used < (old.candidateUsed ?? old.used), remaining > 0 {
                    result.append(alert(usage, limit, kind: "reset", epoch: old.epoch + 1,
                                        body: "额度已重置，当前剩余 \(display(remaining))%。", priority: 2, now: now, ttl: 60))
                }
                old.epoch += 1; old.fired = []; old.hasAlerted = false; old.resetAt = limit.resetAt
                old.candidateReset = nil; old.candidateAt = nil; old.candidateUsed = nil
            } else {
                // Compare in used space to avoid 0.8 becoming 19.999999999% remaining.
                let crossed = Set(thresholds.filter { (0...100).contains($0) && old.used < 1 - Double($0) / 100 && used >= 1 - Double($0) / 100 && !old.fired.contains($0) })
                if let strongest = crossed.min() {
                    old.fired.formUnion(crossed); old.hasAlerted = true
                    let body = strongest == 0 ? "额度已用完。" : "剩余 \(display(remaining))% 额度。"
                    result.append(alert(usage, limit, kind: "threshold-\(strongest)", epoch: old.epoch,
                                        body: body, priority: strongest == 0 ? 0 : 1, now: now, ttl: 300))
                }
                // Keep the old boundary until confirmation; otherwise a delayed new reset
                // would erase the evidence needed for the second independent reading.
                if old.resetAt == nil { old.resetAt = limit.resetAt }
            }
            old.used = used; old.sourceAt = usage.sourceAt; old.period = limit.periodSeconds
            windows[key] = old
        }
        return result
    }
    private func display(_ remaining: Double) -> String {
        remaining > 0 && remaining < 1 ? "<1" : String(Int(remaining.rounded()))
    }
    private func alert(_ usage: AIUsage, _ limit: AILimit, kind: String, epoch: Int,
                       body: String, priority: Int, now: Date, ttl: Double) -> AIAlert {
        var resetText = ""
        if let reset = limit.resetAt {
            let seconds = reset.timeIntervalSince(now)
            if seconds > 0 {
                let minutes = Int(ceil(seconds / 60))
                resetText = minutes >= 60 ? "约 \(minutes / 60) 小时 \(minutes % 60) 分钟后重置。" : "约 \(minutes) 分钟后重置。"
            } else { resetText = "已到预计重置时间，正在确认。" }
        }
        return AIAlert(id: "\(usage.provider.rawValue):\(usage.accountID):\(limit.id):\(epoch):\(kind)",
                provider: usage.provider, title: "\(usage.provider.title) · \(limit.label)", body: body + resetText,
                priority: priority, createdAt: now, expiresAt: min(now, usage.sourceAt).addingTimeInterval(ttl),
                windowID: limit.id, kind: kind, accountID: usage.accountID)
    }
}
