import AppKit
import AVFoundation
import Metal

// Composites the drawn cat and a clip's first frame over a desktop-like background exactly the way the
// window server does - drawn cat in the lower window at its opacity, clip on top at its opacity - so the
// hand-off can be judged by eye and measured:
//
//   Tools/fadecheck.command out.png [clip]
//
// Three strategies are drawn, each as a filmstrip across the transition:
//   现在   the cross-dissolve 3.0.x used: both part transparent at once, so the desktop shows through
//   进动作  entering an action now: the clip covers first, the cat leaves after
//   出动作  leaving one: the cat comes back underneath, then the clip is taken away
// The timings come from ClipStage, so this strip always shows what the app really does.
let args = CommandLine.arguments
let output = args.count > 1 ? args[1] : "fadecheck.png"
let clipName = args.count > 2 ? args[2] : "yawn"

let sprites = try Sprites(url: URL(fileURLWithPath: "奶灰.app/Contents/Resources/cats.png"))
let rigs = CatRigs.build(sprites)
let renderer = try RigRenderer(sprites: sprites, rigs: rigs)
let motion = CatMotion(rigs: rigs, sprites: sprites, seed: 3)
let directory = URL(fileURLWithPath: "Assets/clips")
guard let library = ClipLibrary.load(from: directory), let clip = library[clipName] else { fatalError("no clip \(clipName)") }

let catHeight: CGFloat = 130, backing: CGFloat = 2
let layout = PetLayout(catHeight: catHeight, frameSizes: sprites.frames.map { CGSize(width: $0.width, height: $0.height) })
let scale = catHeight / CGFloat(library.sitHeight)

func drawnCat() -> CGImage {
    let size = CGSize(width: layout.size.width * backing, height: layout.size.height * backing)
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let t = renderer.device.makeTexture(descriptor: d)!
    let pad = CGFloat(rigPad) * layout.scale
    let r = layout.rects[Pose.idle.rawValue].insetBy(dx: -pad, dy: -pad)
    motion.update(dt: 0.016, pose: .idle, walking: false, senses: CatSenses())
    renderer.render([.init(layer: "idle", params: motion.params(for: "idle", opacity: 1),
                           rect: CGRect(x: r.minX * backing, y: r.minY * backing, width: r.width * backing, height: r.height * backing))],
                    target: t, size: size, clear: MTLClearColorMake(0, 0, 0, 0), wait: true)
    var bytes = [UInt8](repeating: 0, count: t.width * t.height * 4)
    t.getBytes(&bytes, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
    let ctx = CGContext(data: &bytes, width: t.width, height: t.height, bitsPerComponent: 8, bytesPerRow: t.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    return ctx.makeImage()!
}
let cat = drawnCat()
let asset = AVURLAsset(url: directory.appendingPathComponent(clip.file))
let generator = AVAssetImageGenerator(asset: asset)
generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
let firstFrame = try generator.copyCGImage(at: .zero, actualTime: nil)

// Core Animation's ease curves, so the strip shows what the screen really does rather than a straight line.
func bezier(_ x: Double, _ c: (Double, Double, Double, Double)) -> Double {
    func curve(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let mt = 1 - t
        return 3 * mt * mt * t * a + 3 * mt * t * t * b + t * t * t
    }
    var t = x
    for _ in 0..<8 {  // Newton: find the t whose x matches, then read its y
        let error = curve(t, c.0, c.2) - x
        if abs(error) < 1e-4 { break }
        let slope = (curve(t + 1e-4, c.0, c.2) - curve(t - 1e-4, c.0, c.2)) / 2e-4
        if abs(slope) < 1e-6 { break }
        t -= error / slope
        t = min(1, max(0, t))
    }
    return curve(t, c.1, c.3)
}
let easeOut = (0.0, 0.0, 0.58, 1.0), easeIn = (0.42, 0.0, 1.0, 1.0)
func ramp(_ time: Double, from start: Double, over length: Double, curve: (Double, Double, Double, Double)? = nil) -> CGFloat {
    let u = min(1, max(0, (time - start) / length))
    return CGFloat(curve.map { bezier(u, $0) } ?? u)
}

// (label, sample times in seconds, opacity of the drawn cat, opacity of the clip) for each row.
let rows: [(String, [Double], (Double) -> CGFloat, (Double) -> CGFloat)] = [
    ("现在：交叉淡化 0.2s", [0, 0.05, 0.1, 0.15, 0.2],
     { 1 - ramp($0, from: 0, over: 0.2) }, { ramp($0, from: 0, over: 0.2) }),
    ("改后：进动作", [0, 0.04, ClipStage.catHold, ClipStage.catHold + ClipStage.catOut / 2, ClipStage.catHold + ClipStage.catOut],
     { 1 - ramp($0, from: ClipStage.catHold, over: ClipStage.catOut) },
     { ramp($0, from: 0, over: ClipStage.coverIn, curve: easeOut) }),
    ("改后：出动作", [0, ClipStage.uncoverDelay, 0.12, 0.2, 0.26],
     { ramp($0, from: 0, over: ClipStage.uncoverDelay) },
     { 1 - ramp($0, from: ClipStage.uncoverDelay, over: 0.2, curve: easeIn) }),
]
let steps = 5
let names = rows.map { $0.0 }

let cellW: CGFloat = 200, cellH: CGFloat = 190, labelW: CGFloat = 108
let W = Int((labelW + cellW * CGFloat(steps)) * backing), H = Int(cellH * CGFloat(names.count) * backing)
let canvas = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
canvas.scaleBy(x: backing, y: backing)

/// A busy desktop: anything showing through the cat is obvious against it.
func desktop(_ rect: CGRect) {
    canvas.saveGState()
    canvas.clip(to: rect)
    let colors = [CGColor(srgbRed: 0.16, green: 0.42, blue: 0.75, alpha: 1), CGColor(srgbRed: 0.85, green: 0.45, blue: 0.25, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    canvas.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    canvas.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
    var y = rect.minY + 8
    while y < rect.maxY { canvas.fill(CGRect(x: rect.minX + 6, y: y, width: rect.width - 12, height: 3)); y += 14 }
    canvas.restoreGState()
}

func text(_ string: String, at point: CGPoint, size: CGFloat = 11, bold: Bool = false, white: Bool = false) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
    NSAttributedString(string: string, attributes: [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                                                    .foregroundColor: white ? NSColor.white : NSColor.black]).draw(at: point)
    NSGraphicsContext.restoreGraphicsState()
}

canvas.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.97, alpha: 1))
canvas.fill(CGRect(x: 0, y: 0, width: CGFloat(W) / backing, height: CGFloat(H) / backing))

// Where the paws land, and where the clip goes, exactly as the app computes it.
let r = layout.rects[Pose.idle.rawValue]
for (row, name) in names.enumerated() {
    let bottom = cellH * CGFloat(names.count - row - 1)
    text(name, at: CGPoint(x: 8, y: bottom + cellH / 2), size: 12, bold: true)
    for step in 0..<steps {
        let cell = CGRect(x: labelW + cellW * CGFloat(step), y: bottom + 18, width: cellW - 6, height: cellH - 26)
        desktop(cell)
        let catOrigin = CGPoint(x: cell.midX - layout.size.width / 2, y: cell.minY + 6)
        let paws = CGPoint(x: catOrigin.x + r.minX + r.width * 0.545, y: catOrigin.y + PetLayout.ground)
        let placed = ClipStage.frame(for: clip, anchor: paws, scale: scale, mirrored: false)
        let time = rows[row].1[step]
        let alpha = (cat: rows[row].2(time), clip: rows[row].3(time))
        canvas.saveGState()
        canvas.setAlpha(alpha.cat)
        canvas.draw(cat, in: CGRect(origin: catOrigin, size: layout.size))
        canvas.restoreGState()
        canvas.saveGState()
        canvas.setAlpha(alpha.clip)
        canvas.draw(firstFrame, in: placed)
        canvas.restoreGState()
        // How much desktop shows through a spot where both cats are solid.
        let seeThrough = (1 - alpha.cat) * (1 - alpha.clip) * 100
        text(String(format: "%.0fms  猫 %.0f%% · 片段 %.0f%% → 透出 %.0f%%", time * 1000, alpha.cat * 100, alpha.clip * 100, seeThrough),
             at: CGPoint(x: cell.minX, y: bottom + 3), size: 9)
    }
}
let rep = NSBitmapImageRep(cgImage: canvas.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)  clip=\(clipName)")
