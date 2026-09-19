import Foundation

enum AIReminderPolicy {
    static func relevant(_ event:AIAlert, readings:[AIProvider:AIUsage], sessions:[AISession], now:Date)->Bool {
        guard event.expiresAt > now else { return false }
        if let id = event.sessionID {
            guard let session = sessions.first(where:{$0.provider == event.provider && $0.id == id}), session.evidence == "explicit" else { return false }
            return event.kind == "waiting" ? session.state == "waiting" : ["ended","idle","success"].contains(session.state)
        }
        guard let usage = readings[event.provider], usage.status == .ok, now.timeIntervalSince(usage.sourceAt) <= 900,
              event.accountID == usage.accountID, let windowID = event.windowID,
              let window = usage.windows.first(where:{$0.id == windowID}), !window.unlimited,
              let used = window.usedFraction, used.isFinite else { return false }
        if event.kind == "reset" { return true }
        if ["weekly-limit","session-limit"].contains(event.kind ?? "") { return used >= 1 }
        if let kind = event.kind, kind.hasPrefix("threshold-"), let threshold = Double(kind.dropFirst(10)) {
            return used >= 1-threshold/100
        }
        return false
    }
}
