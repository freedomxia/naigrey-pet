import AppKit
import Metal

// Renders the real rig and behaviour code offscreen into an MP4 for review:
//   Tools/preview.command out.mp4 [seconds]
// Panels: sitting (with a scripted mouse pointer), walking, sleeping, waving.

let args = CommandLine.arguments
let atlas = URL(fileURLWithPath: args[1])
let seconds = args.count > 3 ? Double(args[3])! : 18
let fps = 60.0
let sprites = try Sprites(url: atlas)
let rigs = CatRigs.build(sprites)
let renderer = try RigRenderer(sprites: sprites, rigs: rigs)
let W = 1280, H = 960
let target: MTLTexture = {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    return renderer.device.makeTexture(descriptor: d)!
}()

struct Panel { let pose: Pose; let motion: CatMotion; let scale: CGFloat; let origin: CGPoint } // origin: canvas top-left, y down
func panel(_ pose: Pose, height: CGFloat, center: CGPoint, seed: UInt64) -> Panel {
    let rig = rigs["\(pose)"]!
    let s = height / CGFloat(sprites[pose].height)
    return Panel(pose: pose, motion: CatMotion(rigs: rigs, sprites: sprites, seed: seed), scale: s,
                 origin: CGPoint(x: center.x - CGFloat(rig.width) * s / 2, y: center.y - CGFloat(rig.height) * s / 2))
}
var walkTravel: CGFloat = 0
let sit = panel(.idle, height: 400, center: CGPoint(x: 330, y: 250), seed: 11)
let walk = panel(.walk, height: 330, center: CGPoint(x: 960, y: 250), seed: 23)
let sleep = panel(.sleep, height: 250, center: CGPoint(x: 330, y: 730), seed: 5)
let wave = panel(.wave, height: 380, center: CGPoint(x: 960, y: 710), seed: 9)
let panels = [sit, walk, sleep, wave]

// Scripted pointer for the sitting cat, in output pixels (y down).
let nose = CGPoint(x: sit.origin.x + 320 * sit.scale, y: sit.origin.y + 265 * sit.scale)
let headTop = CGPoint(x: sit.origin.x + 320 * sit.scale, y: sit.origin.y + 90 * sit.scale)
func pointer(_ t: Double) -> CGPoint? {
    guard t >= 2.5 && t <= 10.4 else { return nil }
    if t >= 7.0 && t <= 9.4 {  // stroking the head back and forth
        let s = (t - 7.0) * 2 * .pi / 0.9
        return CGPoint(x: headTop.x + 70 * sin(s), y: headTop.y + 10 * cos(2 * s))
    }
    let path: [(Double, CGPoint)] = [(2.5, CGPoint(x: 640, y: 120)), (3.4, CGPoint(x: 470, y: 30)), (4.3, CGPoint(x: 120, y: 60)),
                                     (5.1, CGPoint(x: nose.x + 150, y: nose.y + 10)), (6.6, CGPoint(x: nose.x + 140, y: nose.y + 16)),
                                     (7.0, CGPoint(x: headTop.x, y: headTop.y + 11)), (9.4, CGPoint(x: headTop.x, y: headTop.y + 11)),
                                     (10.4, CGPoint(x: 640, y: 470))]
    return CGPoint(x: keys(t, path.map { ($0.0, Double($0.1.x)) }), y: keys(t, path.map { ($0.0, Double($0.1.y)) }))
}

let ffmpeg = Process()
ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
ffmpeg.arguments = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(W)x\(H)", "-r", "\(Int(fps))",
                    "-i", "-", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "17", "-preset", "medium", "-movflags", "+faststart", args[2]]
let pipe = Pipe()
ffmpeg.standardInput = pipe
try ffmpeg.run()

var bytes = [UInt8](repeating: 0, count: W * H * 4)
var lastPointer: CGPoint?
let frames = Int(seconds * fps)
for i in 0..<frames {
    let t = Double(i) / fps, dt = 1 / fps
    if abs(t - 6.2) < dt / 2 { sit.motion.meow() }
    if abs(t - 11.6) < dt / 2 { sit.motion.sigh() }
    if abs(t - 14.2) < dt / 2 { sit.motion.yawn() }
    var draws: [RigRenderer.Draw] = []
    for p in panels {
        var senses = CatSenses()
        if p.pose == .idle, let ptr = pointer(t) {
            let canvas = CGPoint(x: (ptr.x - p.origin.x) / p.scale, y: (ptr.y - p.origin.y) / p.scale)
            if let last = lastPointer { senses.pointerSpeed = hypot(canvas.x - last.x, canvas.y - last.y) * CGFloat(fps) }
            senses.pointer = canvas
            senses.pointerOverHead = canvas.x > 135 && canvas.x < 520 && canvas.y > 10 && canvas.y < 300
            lastPointer = canvas
        } else if p.pose == .idle { lastPointer = nil }
        p.motion.update(dt: dt, pose: p.pose, walking: p.pose == .walk, senses: senses)
        let rig = rigs["\(p.pose)"]!
        let w = CGFloat(rig.width) * p.scale, h = CGFloat(rig.height) * p.scale
        var x = p.origin.x
        if p.pose == .walk {
            // Walk across the panel at the speed the app moves the window, over fixed ground marks.
            walkTravel += CGFloat(p.motion.walkSpeed * dt) * p.scale
            x += 150 - walkTravel.truncatingRemainder(dividingBy: 300)
        }
        for layer in CatRigs.layers(for: p.pose) {
            draws.append(.init(layer: layer, params: p.motion.params(for: layer, opacity: 1),
                               rect: CGRect(x: x, y: CGFloat(H) - p.origin.y - h, width: w, height: h)))
        }
    }
    renderer.render(draws, target: target, size: CGSize(width: W, height: H), clear: MTLClearColorMake(0.93, 0.915, 0.89, 1), wait: true)
    bytes.withUnsafeMutableBytes { raw in
        target.getBytes(raw.baseAddress!, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        do {
            let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let groundY = walk.origin.y + CGFloat(rigs["walk"]!.height - rigPad - 8) * walk.scale
            ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
            for mark in stride(from: 660, to: 1280, by: 30) { ctx.fill(CGRect(x: CGFloat(mark), y: CGFloat(H) - groundY - 6, width: 2, height: 6)) }
        }
        if let ptr = pointer(t) {
            let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
            let arrow: [(CGFloat, CGFloat)] = [(0, 0), (0, 24), (6.5, 18.5), (11, 28), (15, 26), (10.5, 17), (18, 17)]
            ctx.move(to: CGPoint(x: ptr.x, y: ptr.y))
            for a in arrow.dropFirst() { ctx.addLine(to: CGPoint(x: ptr.x + a.0, y: ptr.y + a.1)) }
            ctx.closePath()
            ctx.setFillColor(.white); ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1)); ctx.setLineWidth(1.5)
            ctx.drawPath(using: .fillStroke)
        }
    }
    bytes.withUnsafeBytes { pipe.fileHandleForWriting.write(Data($0)) }
    if args.count > 4, args[4...].contains(String(format: "%.2f", t)) {
        let ctx = CGContext(data: &bytes, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2].replacingOccurrences(of: ".mp4", with: "-\(String(format: "%.2f", t)).png")))
    }
}
pipe.fileHandleForWriting.closeFile()
ffmpeg.waitUntilExit()
print("wrote \(args[2]) (\(frames) frames)")
