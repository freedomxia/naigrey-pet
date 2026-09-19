// Codenotch v1.14.0, MIT, Copyright (c) 2026 Vinz. See THIRD_PARTY_NOTICES.md.
import Foundation
struct UsageResponse: Decodable {
    struct Limit: Decodable {
        let kind: String
        let percent: Double
        let resetsAt: Date?
        /// What the window is scoped to, where it is scoped to anything.
        ///
        /// The model-specific weekly window comes back as `weekly_scoped` for
        /// *every* model, so the kind alone can only ever say "Scoped". The
        /// model it actually meters is named here and nowhere else — which is
        /// also why this is read rather than the model being hardcoded: the
        /// window follows whichever model the plan scopes, and has already been
        /// Opus once.
        let scope: Scope?

        /// The window's own name: the model where the response names one, the
        /// kind's own wording otherwise.
        var windowLabel: String {
            let named = scope?.model?.displayName?.trimmingCharacters(in: .whitespaces)
            if let named, !named.isEmpty { return named }
            return UsageResponse.label(forKind: kind)
        }

        private enum CodingKeys: String, CodingKey {
            case kind, percent, resetsAt, scope
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            percent = try container.decode(Double.self, forKey: .percent)
            resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
            // Tolerated rather than required. Everything above is the reading
            // itself and must decode; the scope is only a nicer name for it, so
            // a shape change here falls back to the kind's wording instead of
            // costing the whole response.
            scope = try? container.decodeIfPresent(Scope.self, forKey: .scope)
        }
    }

    struct Scope: Decodable {
        struct Model: Decodable { let displayName: String? }
        let model: Model?
    }
    struct Window: Decodable {
        let utilization: Double
        let resetsAt: Date?
    }

    let limits: [Limit]?
    let fiveHour: Window?
    let sevenDay: Window?

    /// How this response is read, wherever it is read from.
    ///
    /// Shared rather than one per source: the endpoint and Claude Desktop's cache
    /// carry the *same* response, so two decoders would be two chances for one of
    /// them to drift and silently start dropping windows.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Timestamps come back with fractional seconds and an offset, which
        // `.iso8601` alone will not parse.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: text) ?? plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unparseable date \(text)")
            )
        }
        return decoder
    }()

    /// `limits` is the forward-compatible shape — it grows new kinds as
    /// Anthropic adds them — so it is preferred, with the two named windows as
    /// a fallback for older responses.
    func limitWindows() -> [LimitWindow] {
        var windows = (limits ?? []).compactMap { limit -> LimitWindow? in
            guard let resetsAt = limit.resetsAt else { return nil }
            return LimitWindow(
                id: limit.kind,
                label: limit.windowLabel,
                usedFraction: limit.percent / 100,
                resetsAt: resetsAt,
                duration: Self.duration(forKind: limit.kind)
            )
        }

        // The named windows are merged in rather than used only as a fallback.
        // Claude Code's own schema says an entry is "present only while the API
        // reports it and its resets_at has not passed", so a window that has
        // just rolled over disappears from `limits` while `five_hour` still
        // carries it. Relying on the array alone loses the session exactly when
        // it resets, which is when someone is most likely to be looking.
        func merge(_ window: UsageResponse.Window?, id: String, label: String) {
            guard let window, let resetsAt = window.resetsAt,
                  !windows.contains(where: { $0.id == id })
            else { return }
            windows.append(LimitWindow(id: id, label: label,
                                       usedFraction: window.utilization / 100,
                                       resetsAt: resetsAt, duration: Self.duration(forKind: id)))
        }
        merge(fiveHour, id: "session", label: L10n.t("Current session"))
        merge(sevenDay, id: "weekly_all", label: L10n.t("All models"))

        return windows.sorted(by: UsageResponse.displayOrder)
    }

    static func duration(forKind kind: String) -> TimeInterval? {
        if kind == "session" { return 5 * 3600 }
        if kind.hasPrefix("weekly_") { return 7 * 86400 }
        return nil
    }

    /// The frame's wording, for the kinds it drew.
    static func label(forKind kind: String) -> String {
        switch kind {
        case "session":       return L10n.t("Current session")
        case "weekly_all":    return L10n.t("All models")
        case "weekly_opus":   return L10n.t("Opus")
        case "weekly_sonnet": return L10n.t("Sonnet")
        // Only reached when the response names no model for the window, which
        // is the one case where there is nothing better to call it.
        case "weekly_scoped", "scoped": return L10n.t("Scoped")
        default:
            return kind
                .replacingOccurrences(of: "weekly_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    /// Session first, then the weekly windows — the order the frame shows.
    /// Shared with `ClaudeUsageCLI`, which reads the same windows off the CLI
    /// and must hand them over in the same order.
    static func displayOrder(_ a: LimitWindow, _ b: LimitWindow) -> Bool {
        func rank(_ id: String) -> Int {
            if id == "session" { return 0 }
            if id == "weekly_all" { return 1 }
            return 2
        }
        let (ra, rb) = (rank(a.id), rank(b.id))
        return ra == rb ? a.id < b.id : ra < rb
    }
}
