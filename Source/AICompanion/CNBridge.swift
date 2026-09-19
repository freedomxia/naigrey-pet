import Foundation
import os

// Narrow host types for the vendored quota algorithms; no Codenotch UI dependency.
struct LimitWindow: Equatable, Sendable {
    var id: String
    var group: String? = nil
    var label: String
    var usedFraction: Double? = nil
    var resetsAt: Date? = nil
    var duration: TimeInterval? = nil
    func local(provider: AIProvider) -> AILimit {
        AILimit(id:id, label:group.map { $0 + " · " + label } ?? label,
                usedFraction:usedFraction, resetAt:resetsAt, periodSeconds:duration,
                isExtra:provider == .codex ? !["primary","secondary"].contains(id) : !["session","weekly_all"].contains(id))
    }
}
enum ProviderGlyph { case openai, claude }
struct ProviderSnapshot {
    var id: String
    var displayName: String
    var glyph: ProviderGlyph
    var windows: [LimitWindow]
    var headlineID: String?
    var weeklyID: String?
    var block: String? = nil
    var headline: LimitWindow? { guard let headlineID else { return windows.first }; return windows.first { $0.id == headlineID } }
    var usedFraction: Double? { headline?.usedFraction }
    var weeklyWindow: LimitWindow? { guard let weeklyID, weeklyID != headlineID else { return nil }; return windows.first { $0.id == weeklyID } }
    var weeklyFraction: Double? { weeklyWindow?.usedFraction }
    init(_ usage:AIUsage) {
        id = usage.provider.rawValue; displayName = usage.provider.title
        glyph = usage.provider == .codex ? .openai : .claude
        windows = usage.windows.filter { !$0.unlimited }.map { LimitWindow(id:$0.id,label:$0.label,usedFraction:$0.usedFraction,resetsAt:$0.resetAt,duration:$0.periodSeconds) }
        headlineID = usage.provider == .codex ? "primary" : "session"
        weeklyID = usage.provider == .codex ? "secondary" : "weekly_all"
    }
}
enum UsageProviderError: Error {
    case needsAuth
    case badResponse(status:Int)
    case nothingMetered(String)
}
enum Log { static let usage = Logger(subsystem:"local.naigrey.desktop-pet",category:"quota") }
extension String {
    var nonEmptyPlan: String? { let value = trimmingCharacters(in:.whitespacesAndNewlines); return value.isEmpty ? nil : value }
}
// Only wording is localized by the host; arithmetic and calendar rules stay upstream.
enum L10n {
    static var locale:Locale { Locale(identifier:"zh_CN") }
    static func t(_ text:String, locale:Locale = locale)->String {
        let fixed = ["Current session":"当前会话", "All models":"每周额度", "Weekly limit":"每周额度", "Monthly limit":"每月额度", "Longer window":"较长周期", "Code review":"代码审查", "Scoped":"指定模型", "Resetting…":"正在重置…", "Reset date":"重置日期", "Time remaining":"剩余时间"]
        if let value = fixed[text] { return value }
        if text.hasPrefix("Resets in ") {
            return text.dropFirst(10).replacingOccurrences(of:" Days ",with:" 天 ").replacingOccurrences(of:" Day ",with:" 天 ").replacingOccurrences(of:"h",with:"小时").replacingOccurrences(of:" min",with:" 分钟").replacingOccurrences(of:"m",with:"分") + "后重置"
        }
        if text.hasPrefix("Resets ") { return String(text.dropFirst(7)) + "重置" }
        if text.hasSuffix("h limit") { return text.replacingOccurrences(of:"h limit",with:" 小时额度") }
        if text.hasSuffix("m limit") { return text.replacingOccurrences(of:"m limit",with:" 分钟额度") }
        if text.hasSuffix("d limit") { return text.replacingOccurrences(of:"d limit",with:" 天额度") }
        return text
    }
}
struct ClaudeProfile: Sendable {
    var slug: String? = nil
    var configDirectory: URL
    static var homeDirectory:URL { FileManager.default.homeDirectoryForCurrentUser }
    static func `default`(home:URL = homeDirectory)->ClaudeProfile { .init(configDirectory:home.appendingPathComponent(".claude")) }
    var accountFileURL:URL { slug == nil ? configDirectory.deletingLastPathComponent().appendingPathComponent(".claude.json") : configDirectory.appendingPathComponent(".claude.json") }
    func organizationID()->String? {
        guard let data = try? Data(contentsOf:accountFileURL), let object = try? QuotaParser.object(data), let account = object["oauthAccount"] as? [String:Any] else { return nil }
        return QuotaParser.nonempty(account["organizationUuid"])
    }
}

extension ResetTimeFormat: Codable {}
