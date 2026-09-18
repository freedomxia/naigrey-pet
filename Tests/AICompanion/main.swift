import Foundation
@main struct AITests {
    @MainActor static func main() async throws {
        try await runServiceTests()
        print("PASS: explicit connection, single flight, disconnect cancellation, persistence, offline demo")
        try runPolicyTests()
        print("PASS: stale queue, changed account and resolved waiting suppressed")
        try runProviderTests()
        print("PASS: quota parsers, auth isolation, invalid data and retry handling")
        try runRuleTests()
        print("PASS: quota thresholds, persisted dedupe, conservative reset and account isolation")
        try runSessionTests()
        print("PASS: session evidence, liveness, disappearance and transition handling")
    }
}
