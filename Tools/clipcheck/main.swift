import AppKit
import AVFoundation
import Metal

// Renders the drawn sitting cat next to each clip's first and last frame, placed exactly as the app places them,
// plus a half-transparent overlay, so size and paw alignment can be checked by eye:
//   Tools/clipcheck.command out.png
let args = CommandLine.arguments
let sprites = try Sprites(url: URL(fileURLWithPath: "奶灰.app/Contents/Resources/cats.png"))
let rigs = CatRigs.build(sprites)
let renderer = try RigRenderer(sprites: sprites, rigs: rigs)
let motion = CatMotion(rigs: rigs, sprites: sprites, seed: 3)
let directory = URL(fileURLWithPath: "Assets/clips")
guard let library = ClipLibrary.load(from: directory) else { fatalError("Assets/clips/clips.json missing") }

let catHeight: CGFloat = 130, backing: CGFloat = 2
let layout = PetLayout(catHeight: catHeight, frameSizes: sprites.frames.map { CGSize(width: $0.width, height: $0.height) })
let scale = catHeight / CGFloat(library.sitHeight)
let cellW: CGFloat = 260, cellH: CGFloat = 230
let columns = 3
let W = Int(cellW * CGFloat(columns) * backing), H = Int(cellH * CGFloat(library.clips.count) * backing)

// The drawn cat, rendered once into a texture-sized image.
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

let canvas = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
canvas.setFillColor(CGColor(srgbRed: 0.93, green: 0.92, blue: 0.9, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: W, height: H))
canvas.scaleBy(x: backing, y: backing)

for (row, clip) in library.clips.enumerated() {
    let asset = AVURLAsset(url: directory.appendingPathComponent(clip.file))
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let first = try generator.copyCGImage(at: .zero, actualTime: nil)
    let last = try generator.copyCGImage(at: CMTime(seconds: max(0, clip.duration - 0.05), preferredTimescale: 600), actualTime: nil)
    let top = cellH * CGFloat(library.clips.count - row - 1)
    // Window origin for the drawn cat inside each cell; paws land at the same spot in every column.
    let catOrigin = CGPoint(x: (cellW - layout.size.width) / 2 - 20, y: top + 16)
    let r = layout.rects[Pose.idle.rawValue]
    let paws = CGPoint(x: catOrigin.x + r.minX + r.width * 0.545, y: catOrigin.y + PetLayout.ground)
    for column in 0..<columns {
        let dx = cellW * CGFloat(column)
        let anchor = CGPoint(x: paws.x + dx, y: paws.y)
        let catRect = CGRect(x: catOrigin.x + dx, y: catOrigin.y, width: layout.size.width, height: layout.size.height)
        let placed = ClipStage.frame(for: clip, anchor: anchor, scale: scale, mirrored: false)
        switch column {
        case 0: canvas.draw(cat, in: catRect)
        case 1: canvas.draw(first, in: placed)
        default:
            // Last frame placed so its end anchor sits where the drawn cat will reappear, over a faint drawn cat.
            let endShift = ClipStage.point(clip.end, in: clip, frame: placed, scale: scale, mirrored: false)
            let back = placed.offsetBy(dx: anchor.x - endShift.x, dy: 0)
            canvas.setAlpha(0.45); canvas.draw(cat, in: catRect); canvas.setAlpha(1)
            canvas.saveGState(); canvas.setAlpha(0.7); canvas.draw(last, in: back); canvas.restoreGState()
        }
        canvas.setStrokeColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.2, alpha: 1)); canvas.setLineWidth(0.5)
        canvas.stroke(CGRect(x: anchor.x - 30, y: anchor.y, width: 60, height: 0.01))
        canvas.stroke(CGRect(x: anchor.x, y: anchor.y - 4, width: 0.01, height: 10))
    }
    let label = NSAttributedString(string: clip.name, attributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.black])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
    label.draw(at: CGPoint(x: 6, y: top + cellH - 16))
    NSGraphicsContext.restoreGraphicsState()
}
let rep = NSBitmapImageRep(cgImage: canvas.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
print("wrote", args[1])
