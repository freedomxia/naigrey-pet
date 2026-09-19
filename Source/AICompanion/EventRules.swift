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
// Rules are the upstream in-memory watchers: restarting establishes a new observation.
@MainActor final class AIEventRules {
    private var pending:[AIAlert] = []
    private var current:AIUsage?
    private var now = Date()
    private var muted = false
    private lazy var thresholds = ThresholdNotifier(isMuted:{ [weak self] _ in self?.muted ?? true }, deliver:{ [weak self] event in
        self?.emit(window:event.windowLabel,kind:"threshold-\(100-event.threshold)",body:event.threshold == 100 ? "额度已用完。" : "已用 \(event.usedPercent)% 额度。",reset:event.resetsAt,priority:event.threshold == 100 ? 0 : 1)
    })
    private lazy var resets = UsageResetWatcher(isMuted:{ [weak self] _ in self?.muted ?? true },deliver:{ [weak self] event in
        self?.emit(window:event.windowLabel,kind:"reset",body:"额度已重置。",reset:event.resetsAt,priority:2)
    })
    private lazy var limits = UsageLimitWatcher(isMuted:{ [weak self] _ in self?.muted ?? true },deliver:{ [weak self] event in
        self?.emit(window:event.windowLabel,kind:event.kind == .weeklyLimitReached ? "weekly-limit" : "session-limit",body:"额度已用完。",reset:event.resetsAt,priority:0)
    })
    func forget(_ provider:AIProvider) {
        // Recreate per-provider observers without disturbing the other provider.
        children[provider] = nil
    }
    private var children:[AIProvider:AIEventRules] = [:]
    func observe(_ usage:AIUsage,now:Date,muted:Bool = false)->[AIAlert] {
        guard usage.status == .ok, !usage.accountID.isEmpty else { return [] }
        let child:AIEventRules
        if let existing = children[usage.provider], existing.current?.accountID == usage.accountID { child = existing }
        else { child = AIEventRules(); children[usage.provider] = child }
        child.current = usage; child.now = now; child.muted = muted; child.pending = []
        let snapshot = ProviderSnapshot(usage)
        child.thresholds.observe([snapshot]); child.resets.observe([snapshot]); child.limits.observe([snapshot])
        return child.pending
    }
    private func emit(window:String,kind:String,body:String,reset:Date?,priority:Int) {
        guard let usage = current else { return }
        let id = kind == "weekly-limit" ? (usage.provider == .codex ? "secondary" : "weekly_all") : (usage.provider == .codex ? "primary" : "session")
        pending.append(AIAlert(id:UUID().uuidString,provider:usage.provider,title:"\(usage.provider.title) · \(window)",body:body + (reset.map { ResetCopy.text(for:$0,now:now) } ?? ""),priority:priority,createdAt:now,expiresAt:now.addingTimeInterval(300),windowID:id,kind:kind,accountID:usage.accountID))
    }
}
