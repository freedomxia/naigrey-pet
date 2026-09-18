import AppKit
import AVFoundation
import Metal

// Puts the three sources of cat side by side, each scaled to the same sitting height and stood on the same
// floor line, so it is obvious which of them actually look like the same animal:
//   Tools/stylecheck.command out.png <一张序列帧 png>
let args = CommandLine.arguments
let output = args.count > 1 ? args[1] : "stylecheck.png"
let sheet = args.count > 2 ? args[2] : ""

let sprites = try Sprites(url: URL(fileURLWithPath: "奶灰.app/Contents/Resources/cats.png"))
let rigs = CatRigs.build(sprites)
let renderer = try RigRenderer(sprites: sprites, rigs: rigs)
let motion = CatMotion(rigs: rigs, sprites: sprites, seed: 3)
let directory = URL(fileURLWithPath: "Assets/clips")
guard let library = ClipLibrary.load(from: directory) else { fatalError("no clips") }
let catHeight: CGFloat = 300, backing: CGFloat = 2
let layout = PetLayout(catHeight: catHeight, frameSizes: sprites.frames.map { CGSize(width: $0.width, height: $0.height) })

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
    return CGContext(data: &bytes, width: t.width, height: t.height, bitsPerComponent: 8, bytesPerRow: t.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!.makeImage()!
}

/// The tight box around what is actually drawn, so different sources can be put on the same floor.
func solidBounds(_ image: CGImage) -> CGRect {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h {
        for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 140 {
            // ignore the speckles the generated sheets carry: only count pixels with solid neighbours
            guard x > 0, y > 0, x < w - 1, y < h - 1,
                  pixels[(y * w + x - 1) * 4 + 3] > 140, pixels[(y * w + x + 1) * 4 + 3] > 140,
                  pixels[((y - 1) * w + x) * 4 + 3] > 140, pixels[((y + 1) * w + x) * 4 + 3] > 140 else { continue }
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

var panels: [(String, CGImage)] = [("画的猫（现在待机用的）", drawnCat())]
if let clip = library["standUp"] {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: directory.appendingPathComponent(clip.file)))
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    panels.append(("视频猫（动作片段用的）", try generator.copyCGImage(at: .zero, actualTime: nil)))
}
if !sheet.isEmpty, let source = NSImage(contentsOfFile: sheet)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
    // first frame of a 4x3 sheet
    let cw = source.width / 4, ch = source.height / 3
    if let cell = source.cropping(to: CGRect(x: 0, y: 0, width: cw, height: ch)) {
        panels.append(("序列帧（你给的补全动作）", cell))
    }
}

let cellW: CGFloat = 320, cellH: CGFloat = 400
let W = Int(cellW * CGFloat(panels.count + 1) * backing), H = Int(cellH * backing)
let canvas = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
canvas.scaleBy(x: backing, y: backing)
canvas.setFillColor(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: cellW * CGFloat(panels.count + 1), height: cellH))

func text(_ s: String, at p: CGPoint, size: CGFloat = 12, bold: Bool = false) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
    NSAttributedString(string: s, attributes: [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black]).draw(at: p)
    NSGraphicsContext.restoreGraphicsState()
}

let floorY: CGFloat = 60, target: CGFloat = 250   // every cat drawn 250pt tall, paws on the same line
func place(_ image: CGImage, in column: Int, alpha: CGFloat = 1) {
    let box = solidBounds(image)
    let scale = target / box.height
    let drawW = CGFloat(image.width) * scale, drawH = CGFloat(image.height) * scale
    let x = cellW * CGFloat(column) + cellW / 2 - (box.midX * scale)
    // CGImage y is top-down; the box's bottom edge is at image height - maxY
    let bottomGap = (CGFloat(image.height) - box.maxY) * scale
    canvas.saveGState(); canvas.setAlpha(alpha)
    canvas.draw(image, in: CGRect(x: x, y: floorY - bottomGap, width: drawW, height: drawH))
    canvas.restoreGState()
}
for (i, panel) in panels.enumerated() {
    place(panel.1, in: i)
    text(panel.0, at: CGPoint(x: cellW * CGFloat(i) + 10, y: cellH - 24), size: 12, bold: true)
}
// last column: the drawn cat and the video cat on top of each other
place(panels[0].1, in: panels.count)
if panels.count > 1 { place(panels[1].1, in: panels.count, alpha: 0.5) }
text("画的猫 + 视频猫 叠起来", at: CGPoint(x: cellW * CGFloat(panels.count) + 10, y: cellH - 24), size: 12, bold: true)
canvas.setStrokeColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 0.6)); canvas.setLineWidth(0.5)
canvas.stroke(CGRect(x: 0, y: floorY, width: cellW * CGFloat(panels.count + 1), height: 0.01))
let rep = NSBitmapImageRep(cgImage: canvas.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote", output)

// How close each clip's first and last frame is to the drawn cat, placed exactly as the app places them.
func mask(_ image: CGImage, in rect: CGRect, size: CGSize) -> [Bool] {
    let w = Int(size.width), h = Int(size.height)
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: rect)
    return (0..<(w * h)).map { pixels[$0 * 4 + 3] > 140 }
}
let board = CGSize(width: 420, height: 420)
let appLayout = PetLayout(catHeight: 130, frameSizes: sprites.frames.map { CGSize(width: $0.width, height: $0.height) })
let appScale = 130 / CGFloat(library.sitHeight)
let rect0 = appLayout.rects[Pose.idle.rawValue]
let origin = CGPoint(x: board.width / 2 - appLayout.size.width / 2, y: 40)
let paws = CGPoint(x: origin.x + rect0.minX + rect0.width * 0.545, y: origin.y + PetLayout.ground)
let drawnMask = mask(drawnCat(), in: CGRect(origin: origin, size: appLayout.size), size: board)
print("片段        首帧重合  末帧重合")
for clip in library.clips {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: directory.appendingPathComponent(clip.file)))
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    var scores: [Double] = []
    for last in [false, true] {
        let image = try generator.copyCGImage(at: last ? CMTime(seconds: max(0, clip.duration - 0.05), preferredTimescale: 600) : .zero, actualTime: nil)
        let placed = ClipStage.frame(for: clip, anchor: paws, scale: appScale, mirrored: false)
        let anchorNow = last ? ClipStage.point(clip.end, in: clip, frame: placed, scale: appScale, mirrored: false) : paws
        // As the app places it, and then the best it could ever be if the clip were scaled differently:
        // that separates "the wrong size" from "a different shape".
        var best = (score: 0.0, factor: 1.0)
        for step in 0...24 {
            let factor = 0.7 + Double(step) * 0.025
            let scaled = ClipStage.frame(for: clip, anchor: paws, scale: appScale * factor, mirrored: false)
            let anchorScaled = last ? ClipStage.point(clip.end, in: clip, frame: scaled, scale: appScale * factor, mirrored: false) : paws
            let m = mask(image, in: scaled.offsetBy(dx: paws.x - anchorScaled.x, dy: 0), size: board)
            var inter = 0, union = 0
            for i in 0..<m.count { if m[i] && drawnMask[i] { inter += 1 }; if m[i] || drawnMask[i] { union += 1 } }
            let score = union > 0 ? Double(inter) / Double(union) : 0
            if score > best.score { best = (score, factor) }
            if abs(factor - 1.0) < 0.0125 { scores.append(score) }
        }
        scores.append(best.score); scores.append(best.factor)
    }
    print(String(format: "%-9@ 首帧 %.2f（最好 %.2f，需缩放 ×%.2f）  末帧 %.2f（最好 %.2f，×%.2f）",
                 clip.name as NSString, scores[0], scores[1], scores[2], scores[3], scores[4], scores[5]))
}
