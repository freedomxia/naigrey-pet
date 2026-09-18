import AppKit
import ImageIO
import Metal
import CryptoKit

let visible = CGRect(x: -1440, y: 25, width: 1440, height: 875)
let size = CGSize(width: 240, height: 275)
assert(clampedOrigin(CGPoint(x: -1600, y: -50), size: size, visible: visible) == CGPoint(x: -1440, y: 25))
assert(clampedOrigin(CGPoint(x: 400, y: 2000), size: size, visible: visible) == CGPoint(x: -240, y: 625))
assert(clampedOrigin(CGPoint(x: -900, y: 300), size: size, visible: visible) == CGPoint(x: -900, y: 300))
let tiny = CGRect(x: 0, y: 0, width: 200, height: 200)
assert(clampedOrigin(CGPoint(x: 800, y: 800), size: size, visible: tiny) == .zero)
print("PASS: display bounds, negative monitor coordinates, oversized window, stable valid position")
if CommandLine.arguments.count > 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let sprites = try Sprites(url: url)
    for (i, image) in sprites.frames.enumerated() {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            var clear = 0, solid = 0
            let p = raw.bindMemory(to: UInt8.self)
            for n in 0..<(w * h) { if p[n * 4 + 3] < 10 { clear += 1 }; if p[n * 4 + 3] > 240 { solid += 1 } }
            assert(Double(clear) / Double(w * h) > 0.05, "Frame must contain real transparency")
            assert(Double(solid) / Double(w * h) > 0.10, "Frame must contain visible cat")
            // The click mask must agree with the rendered pixels.
            for n in stride(from: 0, to: w * h, by: 97) { assert(sprites.alphas[i][n] == p[n * 4 + 3], "Alpha mask must match frame") }
            print("PASS: pose \(i), \(w)x\(h), transparent \(clear), opaque \(solid)")
        }
    }
    assert(!sprites.isOpaque(.idle, u: 0.01, v: 0.01), "Frame corner must click through")
    assert(sprites.isOpaque(.idle, u: 0.55, v: 0.6), "Cat body must be clickable")
    let frameSizes = sprites.frames.map { CGSize(width: $0.width, height: $0.height) }
    for (name, height) in PetLayout.sizes {
        let layout = PetLayout(catHeight: height, frameSizes: frameSizes)
        let window = CGRect(origin: .zero, size: layout.size)
        assert(abs(layout.rects[Pose.idle.rawValue].height - height) < 0.01, "Sitting cat must match the chosen size")
        for pose in Pose.allCases {
            for mirrored in [false, true] {
                let r = layout.rect(pose, mirrored: mirrored)
                assert(window.contains(r), "\(name): \(pose) must fit inside the window")
                assert(r.minY == PetLayout.ground, "\(name): \(pose) must stand on the shared ground line")
                assert(window.maxY - r.maxY >= layout.fontSize * 2, "\(name): \(pose) must leave room for the bubble")
            }
        }
        assert(layout.size.width >= layout.fontSize * 11, "\(name): bubble must fit the window width")
        let sprite = sprites.image(.walk, width: Int(layout.rects[Pose.walk.rawValue].width * 2), height: Int(layout.rects[Pose.walk.rawValue].height * 2))
        assert(sprite.width == Int(layout.rects[Pose.walk.rawValue].width * 2), "Pre-scaled sprite must match backing pixels")
        print("PASS: size \(name) \(Int(height))pt -> window \(Int(layout.size.width))x\(Int(layout.size.height)), all poses fit both directions")
    }
    assert(PetLayout.sizes.contains { $0.height == PetLayout.defaultHeight }, "Default size must be a menu option")
}

// Rig: every pose builds, parameter wiring stays inside the shader's layout, and the GPU pipeline compiles.
if CommandLine.arguments.count > 1 {
    let sprites = try Sprites(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    let rigs = CatRigs.build(sprites)
    assert(Set(rigs.keys) == Set([Pose.idle, .sleep, .wave, .walk].flatMap { CatRigs.layers(for: $0) }), "Every drawn layer needs a rig")
    for (key, rig) in rigs.sorted(by: { $0.key < $1.key }) {
        assert(rig.width == rig.base.width + 2 * rigPad && rig.height == rig.base.height + 2 * rigPad)
        let params = rig.restParams(frame: rig.base)
        assert(params.count == RigParams.count)
        for i in 0..<RigParams.bendSlots {
            let o = RigParams.bendBase + i * RigParams.bendStride
            let weight = Int(params[o + 2]), along = Int(params[o + 3])
            assert(weight < RigParams.channelCount && along < RigParams.channelCount)
            if weight >= 0 { assert(rig.channels[weight] != nil, "\(key) bend \(i) points at an empty channel") }
        }
        let maps = rig.packedMaps()
        assert(maps.count == RigParams.channelCount / 4 && maps.allSatisfy { $0.count == rig.width * rig.height * 4 })
        let used = rig.channels.compactMap { $0 }
        assert(used.allSatisfy { $0.count == rig.width * rig.height && $0.allSatisfy { $0 >= 0 && $0 <= 1.0001 } }, "\(key) weights must be 0...1")
        assert(used.allSatisfy { $0.contains { $0 > 0.5 } }, "\(key) has a part whose mask is empty")
        print("PASS: rig \(key) \(rig.width)x\(rig.height), \(used.count) channels, \(rig.bendSlots.count) bends, \(rig.shiftSlots.count) slides, \(rig.scaleSlots.count) scales")
    }
    // Leg layers must hold their leg (the refilled far front leg included) and the body must have lost it.
    let legOpaque = { (image: CGImage) -> Int in
        var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &px, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 3, to: px.count, by: 4).filter { px[$0] > 200 }.count
    }
    for leg in CatRigs.legs { assert(legOpaque(rigs["walk.\(leg.name)"]!.base) > 2500, "\(leg.name) layer must contain the leg") }
    assert(legOpaque(rigs["walk"]!.base) < legOpaque(sprites[.walk]) - 10000, "Body layer must no longer contain the lower legs")

    // Paws stay planted: during stance each paw sweeps back exactly as fast as the window moves forward.
    let motion = CatMotion(rigs: rigs, sprites: sprites, seed: 1)
    for _ in 0..<600 { motion.update(dt: 1 / 60, pose: .walk, walking: true, senses: CatSenses()) }
    for leg in CatRigs.legs {
        var paw: [Double] = []
        for _ in 0..<2 {
            let a = motion.leg(leg.name).degrees * .pi / 180
            paw.append(-Double(leg.length) * sin(a))
            motion.update(dt: 1 / 240, pose: .walk, walking: true, senses: CatSenses())
        }
        if motion.leg(leg.name).lift == 0 {
            let sweep = (paw[1] - paw[0]) * 240
            assert(abs(sweep - motion.walkSpeed) / motion.walkSpeed < 0.08, "\(leg.name) paw slides: \(sweep) vs \(motion.walkSpeed)")
        }
    }
    assert(motion.walkSpeed > 0)
    for layer in rigs.keys {
        let p = motion.params(for: layer, opacity: 1)
        assert(p.count == RigParams.count && p.allSatisfy { $0.isFinite }, "\(layer) params must be finite")
    }
    let renderer = try RigRenderer(sprites: sprites, rigs: rigs)
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 256, height: 256, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let target = renderer.device.makeTexture(descriptor: d)!
    let rig = rigs["idle"]!
    renderer.render([.init(layer: "idle", params: motion.params(for: "idle", opacity: 1), rect: CGRect(x: 0, y: 0, width: CGFloat(rig.width) * 0.4, height: CGFloat(rig.height) * 0.4))],
                    target: target, size: CGSize(width: 256, height: 256), clear: MTLClearColorMake(0, 0, 0, 0), wait: true)
    var pixels = [UInt8](repeating: 0, count: 256 * 256 * 4)
    target.getBytes(&pixels, bytesPerRow: 256 * 4, from: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0)
    let covered = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 200 }.count
    assert(covered > 5000, "GPU render must draw the cat (covered \(covered))")
    print("PASS: shader compiles and draws the sitting cat (\(covered) opaque px), paws planted at \(String(format: "%.1f", motion.walkSpeed)) px/s")
}

// Yarn ball physics: falls to the floor and settles, bounces off walls, and rolling friction stops it.
if CommandLine.arguments.count > 1 {
    _ = NSApplication.shared
    let ball = YarnBall(radius: 13, center: CGPoint(x: 500, y: 400))
    ball.kick(CGVector(dx: 300, dy: 0))
    var bounced = false
    for _ in 0..<(60 * 8) {
        let before = ball.velocity.dx
        ball.step(dt: 1 / 60, floor: 100, walls: 0...640)
        if before > 0 && ball.velocity.dx < 0 { bounced = true }
    }
    assert(abs(ball.center.y - 113) < 0.6, "Ball must come to rest on the floor (y=\(ball.center.y))")
    assert(ball.isResting, "Rolling friction must stop the ball (v=\(ball.speed))")
    assert(bounced && ball.center.x + 13 <= 640 && ball.center.x - 13 >= 0, "Ball must bounce off the wall and stay on screen")
    let image = YarnBallView.drawYarn(radius: 13, scale: 2)
    assert(image?.width == 52, "Yarn art must match the ball size")
    ball.close()
    print("PASS: yarn ball settles at y=\(Int(ball.center.y)), bounced off the wall, stopped at x=\(Int(ball.center.x))")
}

// Clips: the library decodes, and a placed clip puts its paw anchor exactly on the drawn cat's paws, mirrored too.
do {
    let json = """
    {"sitHeight": 620, "clips": [{"name": "wave", "file": "wave.mov", "duration": 2.7, "size": [600, 700], "start": [310, 680], "end": [300, 682]},
      {"name": "play", "file": "play.mov", "duration": 4.4, "size": [900, 600], "start": [300, 580], "end": [350, 590],
       "ballStart": [600, 560], "ballEnd": [880, 570], "ballVelocity": [500, -20]}]}
    """
    let library = try JSONDecoder().decode(ClipLibrary.self, from: Data(json.utf8))
    let wave = library["wave"]!, play = library["play"]!
    let paws = CGPoint(x: 812.5, y: 206)
    for mirrored in [false, true] {
        let frame = ClipStage.frame(for: wave, anchor: paws, scale: 0.17, mirrored: mirrored)
        let landed = ClipStage.point(wave.start, in: wave, frame: frame, scale: 0.17, mirrored: mirrored)
        assert(abs(landed.x - paws.x) < 0.001 && abs(landed.y - paws.y) < 0.001, "Clip anchor must land on the paws (mirrored: \(mirrored))")
        assert(abs(frame.width - 102) < 0.001 && abs(frame.height - 119) < 0.001)
    }
    let placed = ClipStage.frame(for: play, anchor: paws, scale: 0.2, mirrored: true)
    let ball = ClipStage.point(play.ballStart!, in: play, frame: placed, scale: 0.2, mirrored: true)
    assert(ball.x < paws.x, "Mirrored play clip must bring the ball in from the left")
    assert(library["missing"] == nil)
    print("PASS: clip library decodes; anchors land on the paws, mirrored placement flips the ball side")
}

// Updates: the feed is read correctly, older or equal builds are ignored, and a download is only accepted
// when it matches the published digest *and* carries a signature from the release key.
do {
    let feed = """
    {"mac": {"version": "3.1.0", "build": 9, "url": "https://example.com/naigrey-mac.zip",
             "sha256": "abc", "signature": "sig", "minimumSystem": "13.0", "notes": "新动作", "date": "2026-09-18"},
     "windows": null}
    """
    let data = Data(feed.utf8)
    let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 0)
    let offered = try Updater.pick(data, currentBuild: 6, system: sonoma)
    assert(offered?.build == 9 && offered?.version == "3.1.0", "A newer build must be offered")
    assert(offered?.url.host == "example.com")
    let sameBuild = try Updater.pick(data, currentBuild: 9, system: sonoma)
    assert(sameBuild == nil, "The same build must not be offered")
    let downgrade = try Updater.pick(data, currentBuild: 12, system: sonoma)
    assert(downgrade == nil, "A downgrade must never be offered")
    let ventura = OperatingSystemVersion(majorVersion: 12, minorVersion: 7, patchVersion: 0)
    let tooNew = try Updater.pick(data, currentBuild: 6, system: ventura)
    assert(tooNew == nil, "A build needing a newer macOS must be skipped")
    assert(Updater.runs(on: sonoma, atLeast: nil) && Updater.runs(on: sonoma, atLeast: "14.6") && !Updater.runs(on: sonoma, atLeast: "14.7"))
    assert((try? Updater.pick(Data("not json".utf8), currentBuild: 1, system: sonoma)) == nil, "A broken feed must be an error")
    let empty = try Updater.pick(Data(#"{"mac": null, "windows": null}"#.utf8), currentBuild: 1, system: sonoma)
    assert(empty == nil, "An empty feed offers nothing")
    print("PASS: update feed parses; older, equal and too-new-for-this-mac builds are all refused")
}

do {
    let key = Curve25519.Signing.PrivateKey()
    let published = key.publicKey.rawRepresentation.base64EncodedString()
    let payload = Data((0..<4096).map { UInt8($0 % 251) })
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let signature = try key.signature(for: payload).base64EncodedString()
    try Updater.verify(payload, sha256: digest, signature: signature, publicKey: published)
    var tampered = payload; tampered[17] ^= 0xFF
    let tamperedDigest = SHA256.hash(data: tampered).map { String(format: "%02x", $0) }.joined()
    // Changed bytes fail the digest; changed bytes *and* a matching digest still fail the signature.
    assert((try? Updater.verify(tampered, sha256: digest, signature: signature, publicKey: published)) == nil, "A corrupted download must be refused")
    assert((try? Updater.verify(tampered, sha256: tamperedDigest, signature: signature, publicKey: published)) == nil, "A re-hashed download must still fail the signature")
    let stranger = Curve25519.Signing.PrivateKey()
    let strangerSignature = try stranger.signature(for: payload).base64EncodedString()
    assert((try? Updater.verify(payload, sha256: digest, signature: strangerSignature, publicKey: published)) == nil, "Another key's signature must be refused")
    assert(Data(base64Encoded: Updater.publicKey)?.count == 32, "The shipped release key must be a 32-byte Ed25519 key")
    assert(Updater.feedURL.absoluteString.hasPrefix("https://"), "The feed must be fetched over TLS")
    print("PASS: update verification accepts a signed build and refuses corrupted, re-hashed and foreign-signed ones")
}

do {
    // Swapping in a new bundle keeps a copy of the old one and leaves no staging files behind.
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("naigrey-swap-\(UUID().uuidString)")
    let installed = root.appendingPathComponent("奶灰.app"), incoming = root.appendingPathComponent("incoming/奶灰.app")
    for url in [installed, incoming] { try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true) }
    try Data("old".utf8).write(to: installed.appendingPathComponent("Contents/marker"))
    try Data("new".utf8).write(to: incoming.appendingPathComponent("Contents/marker"))
    let backups = root.appendingPathComponent("backup")
    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    let result = try Updater.swapIn(incoming, destination: installed, backups: backups)
    assert(result == installed)
    let marker = try String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8)
    assert(marker == "new", "The new bundle must take the old one's place")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }
    assert(leftovers.isEmpty, "Staging copies must not be left behind: \(leftovers)")
    let kept = try FileManager.default.contentsOfDirectory(atPath: backups.path)
    assert(kept.count == 1, "The replaced version must be kept as a backup, got \(kept)")
    let keptMarker = try String(contentsOf: backups.appendingPathComponent(kept[0]).appendingPathComponent("Contents/marker"), encoding: .utf8)
    assert(keptMarker == "old", "The backup must hold the version that was replaced")
    assert(Updater.quote("/Users/me/Documents/奶灰 桌宠/奶灰.app") == "'/Users/me/Documents/奶灰 桌宠/奶灰.app'")
    assert(Updater.quote("/tmp/it's here") == "'/tmp/it'\\''s here'", "Paths with a quote must survive the shell")
    try? FileManager.default.removeItem(at: root)
    print("PASS: update swap replaces the bundle in place, cleans up staging, and quotes odd paths")
}
