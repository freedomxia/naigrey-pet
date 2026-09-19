import Foundation
import AppKit
@MainActor func runServiceTests() async throws {
    let suite = "naigrey.tests.ai.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName:suite)!
    defer { defaults.removePersistentDomain(forName:suite) }
    var requests = 0, authorizations = 0
    let reader:(AIProvider) async throws -> AIUsage = { p in
        requests += 1
        try await Task.sleep(nanoseconds:50_000_000)
        return AIUsage(provider:p,accountID:"fixture",status:.ok,source:"fixture",sourceAt:Date(),observedAt:Date(),windows:[AILimit(id:"primary",label:"Session",usedFraction:0.5)])
    }
    let service = AICompanionService(defaults:defaults,reader:reader,authorizer:{ authorizations += 1 })
    precondition(service.settings.enabled.isEmpty && requests == 0)
    service.refreshAll(); precondition(requests == 0)
    service.connect(.codex); service.refreshAll(); service.connect(.codex)
    try await Task.sleep(nanoseconds:100_000_000)
    precondition(requests == 1 && service.readings[.codex]?.windows.first?.usedFraction == 0.5)
    service.disconnect(.codex); precondition(service.readings[.codex] == nil)
    service.connect(.codex); service.disconnect(.codex)
    try await Task.sleep(nanoseconds:100_000_000)
    precondition(service.readings[.codex] == nil && !service.settings.enabled.contains(.codex))
    service.connect(.claude)
    try await Task.sleep(nanoseconds:100_000_000)
    precondition(authorizations == 0 && service.readings[.claude] != nil)
    service.updateSettings { $0.sound = true; $0.mutedUntil = Date().addingTimeInterval(3600) }
    let restored = AICompanionService(defaults:defaults,reader:reader,authorizer:{})
    precondition(restored.settings.sound && restored.isMuted && restored.readings[.claude]?.status == .stale)
    service.disconnect(.claude); service.stop(); restored.stop()
    // Exercise the native action directly: a previous version read settings
    // inside its inout mutation and trapped only when the user clicked Pause.
    _ = NSApplication.shared
    let uiService = AICompanionService(defaults:defaults,demo:true,reader:reader,authorizer:{})
    uiService.updateSettings { $0.mutedUntil = nil; $0.quietStart = nil; $0.quietEnd = nil }
    let panel = AISettingsPanel(service:uiService)
    panel.perform(NSSelectorFromString("toggleMute"))
    precondition(uiService.isMuted)
    panel.perform(NSSelectorFromString("toggleMute"))
    precondition(!uiService.isMuted)
    panel.close()
    let card = AIStatusPanel(service:uiService)
    precondition(card.window!.frame.width == 360)
    card.perform(NSSelectorFromString("togglePin"))
    precondition(card.window!.level == .floating)
    card.perform(NSSelectorFromString("togglePin"))
    precondition(card.window!.level == .normal)
    card.close(); uiService.stop()
    let before = defaults.dictionaryRepresentation()
    let demo = AICompanionService(defaults:defaults,demo:true,reader:reader,authorizer:{})
    demo.connect(.codex); demo.refreshAll(); demo.updateSettings { $0.sound = false }; demo.stop()
    precondition(defaults.dictionaryRepresentation().count == before.count)
    precondition(demo.readings[.codex]?.source.contains("演示") == true)
}
