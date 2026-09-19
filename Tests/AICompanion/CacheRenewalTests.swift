import Foundation
// Compressed synthetic fixture from Codenotch v1.14.0 tests (MIT).
@MainActor func runCacheRenewalTests() async throws {
    let body = Data(base64Encoded:
        "KLUv/WROAH0EACIIGxlQdw4862yq1vdy7GtBVDUou1+jNaOqbCoEwOcgypwRcnPq3g5+rfrB" +
        "+rpAadPzoUpO9xo+rZKSc5dJEIWLEKxaa3rhe7DELifLFDssyxrn1whpbdrYhSX24FeWrLGT" +
        "U9bsHh/LLAm2JqN7AQwAuSzCVXCUogCzLBIqWA3UBBZsCvNhCnOvBgBYAm4PaQlsxA==")!
    func entry(org:String)->Data {
        let key = Data("1/0/https://claude.ai/api/organizations/\(org)/usage?skip_spend=1".utf8)
        var data = Data()
        withUnsafeBytes(of:UInt64(0xfcfb6d1ba7725c30).littleEndian) { data.append(contentsOf:$0) }
        withUnsafeBytes(of:UInt32(5).littleEndian) { data.append(contentsOf:$0) }
        withUnsafeBytes(of:UInt32(key.count).littleEndian) { data.append(contentsOf:$0) }
        data.append(Data(repeating:0,count:8)); data.append(key); data.append(body)
        data.append(Data("\0date:Wed, 09 Sep 2026 16:12:08 GMT\0".utf8))
        return data
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:dir) }
    try entry(org:"fixture-org").write(to:dir.appendingPathComponent("entry_0"))
    let cache = ClaudeDesktopUsageCache(directory:dir)
    let read = cache.read(organization:"fixture-org")
    precondition(read?.windows.first?.id == "session", "Bounded zstd cache entry must decode into real quota windows")
    precondition(cache.read(organization:"other-org") == nil, "Never use another organization's cache")
    precondition(ClaudeDesktopUsageCache.parse(entry:Data(entry(org:"fixture-org").prefix(40))) == nil)
    let now = Date(), expiry = now.addingTimeInterval(100)
    var launches = 0
    let failed = ClaudeTokenRefresher(expiry:{expiry},reload:{expiry},cli:URL(fileURLWithPath:"/fixture/claude"),launcher:{_,_ in launches += 1; return (999,{1}) })
    await failed.considerRenewing(now:now)
    await failed.considerRenewing(now:now.addingTimeInterval(1200))
    precondition(launches == 1, "Failed renewal attempts at most once per credential expiry")
    let renewed = now.addingTimeInterval(8*3600)
    let success = ClaudeTokenRefresher(expiry:{expiry},reload:{renewed},cli:URL(fileURLWithPath:"/fixture/claude"),launcher:{_,_ in (999,{1}) })
    await success.considerRenewing(now:now)
    precondition(success.outcome == .refreshed(until:renewed), "Expiry change, not subprocess exit, proves renewal")
}
