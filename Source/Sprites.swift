import AppKit
import ImageIO

enum Pose: Int, CaseIterable { case idle, blink, wave, sleep, yawn, walk }

struct Sprites {
    let frames: [CGImage]
    /// Alpha of each trimmed frame, top row first, so clicks only land on the cat itself.
    let alphas: [[UInt8]]
    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "Sprites", code: 1, userInfo: [NSLocalizedDescriptionKey: "猫咪素材无法读取。"])
        }
        var loaded: [CGImage] = []
        var masks: [[UInt8]] = []
        // Atlas regions follow the actual asset: the sleeping tail crosses the nominal grid.
        // Coordinates are measured on the 1672 x 940 source and scaled if re-encoded.
        let regions: [CGRect] = [
            CGRect(x: 0, y: 0, width: 570, height: 470),
            CGRect(x: 570, y: 0, width: 550, height: 470),
            CGRect(x: 1120, y: 0, width: 552, height: 475),
            CGRect(x: 0, y: 560, width: 590, height: 347),
            CGRect(x: 620, y: 470, width: 465, height: 470),
            CGRect(x: 1090, y: 490, width: 582, height: 450)
        ]
        for region in regions {
            let r = CGRect(x: region.minX * CGFloat(sheet.width) / 1672,
                           y: region.minY * CGFloat(sheet.height) / 940,
                           width: region.width * CGFloat(sheet.width) / 1672,
                           height: region.height * CGFloat(sheet.height) / 940).integral
            guard let cell = sheet.cropping(to: r) else { throw NSError(domain: "Sprites", code: 2) }
            let w = cell.width, h = cell.height
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            let trim: (bounds: CGRect, alpha: [UInt8])? = pixels.withUnsafeMutableBytes { buffer in
                guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                ctx.draw(cell, in: CGRect(x: 0, y: 0, width: w, height: h))
                let p = buffer.bindMemory(to: UInt8.self)
                var left = w, right = 0, top = h, bottom = 0
                for y in 0..<h { for x in 0..<w where p[(y * w + x) * 4 + 3] > 24 {
                    left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                } }
                guard left < right && top < bottom else { return nil }
                let minX = max(0, left - 2), minY = max(0, top - 2), maxX = min(w, right + 3), maxY = min(h, bottom + 3)
                var alpha = [UInt8](repeating: 0, count: (maxX - minX) * (maxY - minY))
                for y in minY..<maxY { for x in minX..<maxX {
                    alpha[(y - minY) * (maxX - minX) + x - minX] = p[(y * w + x) * 4 + 3]
                } }
                return (CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), alpha)
            }
            guard let trim, let trimmed = cell.cropping(to: trim.bounds),
                  trimmed.width * trimmed.height == trim.alpha.count else {
                throw NSError(domain: "Sprites", code: 3, userInfo: [NSLocalizedDescriptionKey: "猫咪姿态为空。"])
            }
            loaded.append(trimmed)
            masks.append(trim.alpha)
        }
        frames = loaded
        alphas = masks
    }
    subscript(_ pose: Pose) -> CGImage { frames[pose.rawValue] }

    /// u, v in 0...1 measured from the frame's left and top edges.
    func isOpaque(_ pose: Pose, u: CGFloat, v: CGFloat) -> Bool {
        let image = self[pose], w = image.width, h = image.height
        let x = min(w - 1, max(0, Int(u * CGFloat(w)))), y = min(h - 1, max(0, Int(v * CGFloat(h))))
        return alphas[pose.rawValue][y * w + x] > 25
    }

    /// Pre-scaled to the exact backing pixels, so a small cat keeps fine whiskers instead of GPU minification shimmer.
    func image(_ pose: Pose, width: Int, height: Int) -> CGImage {
        let source = self[pose]
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return source }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? source
    }
}

/// Geometry shared by every pose: one scale so the cat keeps its size, one ground line, and a per-pose
/// horizontal shift (source pixels, picked by silhouette overlap) so cross-fades between poses don't jump.
struct PetLayout {
    static let sizes: [(name: String, height: CGFloat)] = [("迷你", 72), ("小巧", 100), ("标准", 130), ("大只", 170)]
    static let defaultHeight: CGFloat = 100
    static let shift: [CGFloat] = [0, 2, 4, 2, 68, -40]
    static let ground: CGFloat = 6

    let catHeight: CGFloat
    let scale: CGFloat
    let fontSize: CGFloat
    let size: CGSize
    let rects: [CGRect]

    init(catHeight: CGFloat, frameSizes: [CGSize]) {
        self.catHeight = catHeight
        scale = catHeight / frameSizes[Pose.idle.rawValue].height
        fontSize = min(13, max(10, catHeight * 0.1))
        let s = scale
        let reach = zip(frameSizes, Self.shift).map { ($0.width / 2 + abs($1)) * s }.max() ?? 0
        let tallest = (frameSizes.map(\.height).max() ?? 0) * s
        // Room for the widest pose facing either way, a speech bubble above the head, and hops.
        let width = ceil(max(reach * 2 + 8, fontSize * 11))
        size = CGSize(width: width, height: ceil(Self.ground + tallest + fontSize * 2.4 + 6))
        rects = zip(frameSizes, Self.shift).map { frame, dx in
            CGRect(x: width / 2 + dx * s - frame.width * s / 2, y: Self.ground, width: frame.width * s, height: frame.height * s)
        }
    }

    func rect(_ pose: Pose, mirrored: Bool) -> CGRect {
        var r = rects[pose.rawValue]
        if mirrored { r.origin.x = size.width - r.maxX }
        return r
    }
}

/// Borderless floating window that never takes focus from the app you're using.
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

func clampedOrigin(_ point: NSPoint, size: NSSize, visible: NSRect) -> NSPoint {
    NSPoint(x: min(max(point.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(point.y, visible.minY), max(visible.minY, visible.maxY - size.height)))
}
