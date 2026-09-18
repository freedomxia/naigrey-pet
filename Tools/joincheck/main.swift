import AppKit
import AVFoundation
import Metal

// Checks the joins between clips: for every hand-off the app can make, puts the last frame of one clip and
// the first frame of the next side by side and on top of each other, placed by the same anchor maths the app
// uses (the next clip starts where the previous one's paws ended).
//
//   Tools/joincheck.command out.png
let args = CommandLine.arguments
let output = args.count > 1 ? args[1] : "joincheck.png"
let sprites = try Sprites(url: URL(fileURLWithPath: "奶灰.app/Contents/Resources/cats.png"))
let rigs = CatRigs.build(sprites)
let renderer = try RigRenderer(sprites: sprites, rigs: rigs)
let motion = CatMotion(rigs: rigs, sprites: sprites, seed: 3)
let directory = URL(fileURLWithPath: "Assets/clips")
guard let library = ClipLibrary.load(from: directory) else { fatalError("Assets/clips/clips.json missing") }

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
let drawn = drawnCat()

func frame(_ name: String, last: Bool) throws -> CGImage {
    guard let clip = library[name] else { fatalError("no clip \(name)") }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: directory.appendingPathComponent(clip.file)))
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    return try generator.copyCGImage(at: last ? CMTime(seconds: max(0, clip.duration - 0.05), preferredTimescale: 600) : .zero, actualTime: nil)
}

// Each join: what is leaving, what is arriving.
let joins = [("坐着的猫", "standUp"), ("standUp", "walk"), ("walk", "sitDown"), ("sitDown", "坐着的猫"),
             ("坐着的猫", "wave"), ("wave", "坐着的猫"), ("坐着的猫", "lieDown"), ("lieDown", "sleep"),
             ("sleep", "wake"), ("wake", "坐着的猫"), ("坐着的猫", "play"), ("play", "坐着的猫")]

let cellW: CGFloat = 190, cellH: CGFloat = 170, labelW: CGFloat = 132
let W = Int((labelW + cellW * 3) * backing), H = Int(cellH * CGFloat(joins.count) * backing)
let canvas = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
canvas.scaleBy(x: backing, y: backing)
canvas.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1))
canvas.fill(CGRect(x: 0, y: 0, width: CGFloat(W) / backing, height: CGFloat(H) / backing))

func text(_ string: String, at point: CGPoint, size: CGFloat = 11, bold: Bool = false) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
    NSAttributedString(string: string, attributes: [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                                                    .foregroundColor: NSColor.black]).draw(at: point)
    NSGraphicsContext.restoreGraphicsState()
}

let r = layout.rects[Pose.idle.rawValue]
for (row, join) in joins.enumerated() {
    let bottom = cellH * CGFloat(joins.count - row - 1)
    text("\(join.0) → \(join.1)", at: CGPoint(x: 8, y: bottom + cellH / 2), size: 12, bold: true)
    for column in 0..<3 {
        let cell = CGRect(x: labelW + cellW * CGFloat(column), y: bottom + 16, width: cellW - 6, height: cellH - 24)
        canvas.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); canvas.fill(cell)
        let catOrigin = CGPoint(x: cell.midX - layout.size.width / 2, y: cell.minY + 8)
        let paws = CGPoint(x: catOrigin.x + r.minX + r.width * 0.545, y: catOrigin.y + PetLayout.ground)
        // Column 0: what is leaving. Column 1: what arrives. Column 2: both, to see how far they are apart.
        func draw(_ name: String, last: Bool, alpha: CGFloat) throws {
            canvas.saveGState(); canvas.setAlpha(alpha)
            if name == "坐着的猫" {
                canvas.draw(drawn, in: CGRect(origin: catOrigin, size: layout.size))
            } else if let clip = library[name] {
                let placed = ClipStage.frame(for: clip, anchor: paws, scale: scale, mirrored: false)
                // A clip that is leaving is placed so its *end* anchor is on the paw mark, like the app does.
                let shift = last ? ClipStage.point(clip.end, in: clip, frame: placed, scale: scale, mirrored: false) : paws
                canvas.draw(try frame(name, last: last), in: placed.offsetBy(dx: paws.x - shift.x, dy: 0))
            }
            canvas.restoreGState()
        }
        switch column {
        case 0: try draw(join.0, last: true, alpha: 1)
        case 1: try draw(join.1, last: false, alpha: 1)
        default:
            try draw(join.0, last: true, alpha: 1)
            try draw(join.1, last: false, alpha: 0.5)
        }
        canvas.setStrokeColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.2, alpha: 0.8)); canvas.setLineWidth(0.5)
        canvas.stroke(CGRect(x: paws.x - 26, y: paws.y, width: 52, height: 0.01))
        text(["上一段结尾", "下一段开头", "叠起来"][column], at: CGPoint(x: cell.minX + 2, y: bottom + 2), size: 9)
    }
}
let rep = NSBitmapImageRep(cgImage: canvas.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote", output)
