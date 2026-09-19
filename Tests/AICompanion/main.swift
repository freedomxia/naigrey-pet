import Foundation
@main struct AITests {
    @MainActor static func main() async throws {
        try await runCacheRenewalTests()
        print("PASS: compressed Desktop cache, organization match and Claude renewal outcome")
        try await runSourceParityTests()
        print("PASS: Codenotch source ordering, account isolation, independent backoffs and reset formatting")
        try await runServiceTests()
        print("PASS: explicit connection, single flight, disconnect cancellation, persistence, offline demo")
        try runPolicyTests()
        print("PASS: stale queue, changed account and resolved waiting suppressed")
        try runProviderTests()
        print("PASS: quota parsers, auth isolation, invalid data and retry handling")
        try runRuleTests()
        print("PASS: Codenotch headline thresholds, exhaustion and reset behavior")
        try runSessionTests()
        print("PASS: session evidence, liveness, disappearance and transition handling")
    }
}
