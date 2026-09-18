import Foundation

enum AIProvider: String, CaseIterable, Codable {
    case codex, claude
    var title: String { self == .codex ? "Codex" : "Claude" }
}

enum AIStatus: String, Codable {
    case ok, stale, needsAuth, accessDenied, unsupported, error, disconnected
}

struct AILimit: Codable, Equatable {
    var id: String
    var label: String
    var usedFraction: Double?
    var resetAt: Date?
    var periodSeconds: Double?
    var isExtra: Bool = false
    var unlimited: Bool = false
    init(id: String, label: String, usedFraction: Double? = nil, resetAt: Date? = nil, periodSeconds: Double? = nil,
         isExtra: Bool = false, unlimited: Bool = false) {
        self.id = id; self.label = label; self.usedFraction = usedFraction
        self.resetAt = resetAt; self.periodSeconds = periodSeconds
        self.isExtra = isExtra; self.unlimited = unlimited
    }
    private enum CodingKeys: String, CodingKey {
        case id, label, usedFraction, resetAt, periodSeconds, isExtra, unlimited
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)
        usedFraction = try values.decodeIfPresent(Double.self, forKey: .usedFraction)
        resetAt = try values.decodeIfPresent(Date.self, forKey: .resetAt)
        periodSeconds = try values.decodeIfPresent(Double.self, forKey: .periodSeconds)
        isExtra = try values.decodeIfPresent(Bool.self, forKey: .isExtra) ?? false
        unlimited = try values.decodeIfPresent(Bool.self, forKey: .unlimited) ?? false
    }
}

struct AIUsage: Codable, Equatable {
    var provider: AIProvider
    var accountID: String
    var status: AIStatus
    var source: String
    var sourceAt: Date
    var observedAt: Date
    var windows: [AILimit]
    var message: String?
}

struct AIProviderError: Error {
    var status: AIStatus
    var message: String
    var retryAfter: TimeInterval? = nil
}
