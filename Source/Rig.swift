import AppKit
import Accelerate

/// Transparent margin around each trimmed pose, in source pixels, so tails and paws can move past the art's edge.
let rigPad = 40

/// Layout of the per-draw parameter buffer shared by `RigRenderer`'s shader and `CatMotion`.
enum RigParams {
    static let header = 32
    static let bendSlots = 6, bendStride = 13, angleSamples = 9
    static let shiftSlots = 8, shiftStride = 3
    static let scaleSlots = 4, scaleStride = 5
    static let bendBase = header
    static let shiftBase = bendBase + bendSlots * bendStride
    static let scaleBase = shiftBase + shiftSlots * shiftStride
    static let count = scaleBase + scaleSlots * scaleStride

    // Header fields.
    static let canvasW = 0, canvasH = 1, pad = 2, baseW = 3, baseH = 4
    static let rotatePivotX = 5, rotatePivotY = 6, angle = 7, scaleX = 8, scaleY = 9, shiftX = 10, shiftY = 11
    static let opacity = 12, lidGrow = 13, lidLeft = 14, lidRight = 15, lidSplitX = 16, blinkSwap = 17
    static let mouthOpen = 18, mouthMask = 19, mouthOffsetX = 20, mouthOffsetY = 21, mouthW = 22, mouthH = 23
    static let overlayW = 24, overlayH = 25, lidClamp = 26, mouthSource = 27, scalePivotX = 28, scalePivotY = 29

    // Channels with a fixed meaning; the shader samples them at the displaced source position.
    static let yawnMouthChannel = 11, squeezeChannel = 12, swapChannel = 13, meowMouthChannel = 14, revealChannel = 15
    static let channelCount = 20
}

/// Soft weight maps and motion slots for one pose. Weights are baked once at launch from the same
/// hand-placed regions the prototype used; the GPU then bends, slides and scales parts every frame.
final class PoseRig {
    let pose: Pose
    /// Renderer and motion key: the pose name, or "walk.frontNear" etc. for a separately drawn leg.
    let key: String
    /// Art drawn for this layer: the pose frame, or a cut-out of it.
    private(set) var base: CGImage
    let width: Int, height: Int
    private(set) var channels: [[Float]?] = Array(repeating: nil, count: RigParams.channelCount)
    private(set) var bendSlots: [String: (slot: Int, pivot: CGPoint, along: Bool)] = [:]
    private(set) var shiftSlots: [String: Int] = [:]
    private(set) var scaleSlots: [String: Int] = [:]
    var lids = (left: CGFloat(0), right: CGFloat(0), splitX: CGFloat(0))
    private var freeChannels = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 16, 17, 18, 19]
    private var bendInfo: [(weight: Int, along: Int, pivot: CGPoint)] = []
    private var shiftInfo: [Int] = []
    private var scaleInfo: [Int] = []

    init(pose: Pose, key: String? = nil, frame: CGImage) {
        self.pose = pose
        self.key = key ?? "\(pose)"
        base = frame
        width = frame.width + rigPad * 2
        height = frame.height + rigPad * 2
    }

    /// Replaces the art with the frame multiplied by a canvas-sized mask; `hole` pixels are refilled
    /// from surrounding opaque colour (for fur hidden behind a nearer leg in the original drawing).
    func cutOut(_ frame: CGImage, keep: [Float], hole: [Float]? = nil) {
        let w = frame.width, h = frame.height
        var px = [Float](repeating: 0, count: w * h * 4)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        for i in 0..<(w * h * 4) { px[i] = Float(bytes[i]) / 255 }
        func canvas(_ x: Int, _ y: Int) -> Int { (y + rigPad) * width + x + rigPad }
        if let hole {
            // Straight colours of opaque pixels are known; hole pixels take the average of known neighbours, ring by ring.
            var known = [Bool](repeating: false, count: w * h)
            var color = [Float](repeating: 0, count: w * h * 3)
            var pending: [Int] = []
            for y in 0..<h { for x in 0..<w {
                let i = y * w + x
                if hole[canvas(x, y)] > 0.5 { pending.append(i); continue }
                let a = px[i * 4 + 3]
                if a > 0.9 { known[i] = true; for c in 0..<3 { color[i * 3 + c] = px[i * 4 + c] / a } }
            } }
            for _ in 0..<80 where !pending.isEmpty {
                var filled: [(Int, [Float])] = []
                pending = pending.filter { i in
                    let x = i % w, y = i / w
                    var sum: [Float] = [0, 0, 0], n: Float = 0
                    for dy in -1...1 { for dx in -1...1 where (dx != 0 || dy != 0) {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h, known[ny * w + nx] else { continue }
                        for c in 0..<3 { sum[c] += color[(ny * w + nx) * 3 + c] }; n += 1
                    } }
                    guard n > 0 else { return true }
                    filled.append((i, sum.map { $0 / n })); return false
                }
                for (i, c) in filled { known[i] = true; for k in 0..<3 { color[i * 3 + k] = c[k] } }
            }
            for y in 0..<h { for x in 0..<w where hole[canvas(x, y)] > 0.5 && known[y * w + x] {
                let i = y * w + x
                for c in 0..<3 { px[i * 4 + c] = color[i * 3 + c] }
                px[i * 4 + 3] = 1
            } }
        }
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x, k = keep[canvas(x, y)]
            for c in 0..<4 { bytes[i * 4 + c] = UInt8(max(0, min(255, (px[i * 4 + c] * k * 255).rounded()))) }
        } }
        let ctx = bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        base = ctx
    }

    // MARK: Fields (coordinates are trimmed-frame pixels, y down)

    private func context() -> CGContext {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.translateBy(x: CGFloat(rigPad), y: CGFloat(height - rigPad))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(gray: 1, alpha: 1)
        return ctx
    }

    private func blurred(_ ctx: CGContext, sigma: CGFloat) -> [Float] {
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](UnsafeBufferPointer(start: data, count: width * height))
        if sigma > 0 {
            // Three box passes approximate a Gaussian of the requested sigma.
            let box = UInt32(Int(sqrt(4 * sigma * sigma + 1).rounded()) | 1)
            var scratch = [UInt8](repeating: 0, count: pixels.count)
            for _ in 0..<3 {
                pixels.withUnsafeMutableBytes { src in
                    scratch.withUnsafeMutableBytes { dst in
                        var s = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                        var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                        _ = vImageBoxConvolve_Planar8(&s, &d, nil, 0, 0, box, box, 0, vImage_Flags(kvImageEdgeExtend))
                    }
                }
                swap(&pixels, &scratch)
            }
        }
        return pixels.map { Float($0) / 255 }
    }

    func polygon(_ points: [(CGFloat, CGFloat)], feather: CGFloat) -> [Float] {
        let ctx = context()
        ctx.move(to: CGPoint(x: points[0].0, y: points[0].1))
        for p in points.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
        ctx.closePath(); ctx.fillPath()
        return blurred(ctx, sigma: feather)
    }

    func ovals(_ items: [(center: (CGFloat, CGFloat), radii: (CGFloat, CGFloat))], feather: CGFloat) -> [Float] {
        let ctx = context()
        for item in items {
            ctx.fillEllipse(in: CGRect(x: item.center.0 - item.radii.0, y: item.center.1 - item.radii.1, width: item.radii.0 * 2, height: item.radii.1 * 2))
        }
        return blurred(ctx, sigma: feather)
    }

    /// Per-pixel function of the source position (trimmed-frame pixels).
    func field(_ f: (CGFloat, CGFloat) -> Float) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { out[y * width + x] = f(CGFloat(x - rigPad), CGFloat(y - rigPad)) } }
        return out
    }

    static func smooth(_ t: CGFloat) -> Float { let c = Float(min(1, max(0, t))); return c * c * (3 - 2 * c) }

    func radial(_ pivot: (CGFloat, CGFloat), start: CGFloat, reach: CGFloat) -> (weight: [Float], along: [Float]) {
        let along = field { x, y in Float(min(1, max(0, (hypot(x - pivot.0, y - pivot.1) - start) / reach))) }
        return (along.map { PoseRig.smooth(CGFloat($0)) }, along)
    }

    /// Progress along a limb from `from` toward `to`: 0 near the joint, 1 by the paw.
    func along(from a: (CGFloat, CGFloat), to b: (CGFloat, CGFloat), start: CGFloat, reach: CGFloat) -> [Float] {
        let dx = b.0 - a.0, dy = b.1 - a.1, len = hypot(dx, dy)
        return field { x, y in PoseRig.smooth((((x - a.0) * dx + (y - a.1) * dy) / len - start) / reach) }
    }

    func above(_ y0: CGFloat, span: CGFloat) -> [Float] { field { _, y in PoseRig.smooth((y0 - y) / span) } }
    func below(_ top: CGFloat, _ bottom: CGFloat) -> [Float] { field { _, y in PoseRig.smooth((y - top) / (bottom - top)) } }

    // MARK: Parts

    private func take(_ values: [Float], into channel: Int? = nil) -> Int {
        let c = channel ?? freeChannels.removeFirst()
        precondition(channels[c] == nil, "rig channel \(c) used twice")
        channels[c] = values
        return c
    }

    func bend(_ name: String, pivot: (CGFloat, CGFloat), weight: [Float], along: [Float]? = nil) {
        let w = take(weight), a = along.map { take($0) } ?? -1
        bendSlots[name] = (bendInfo.count, CGPoint(x: pivot.0 + CGFloat(rigPad), y: pivot.1 + CGFloat(rigPad)), a >= 0)
        bendInfo.append((w, a, CGPoint(x: pivot.0 + CGFloat(rigPad), y: pivot.1 + CGFloat(rigPad))))
        precondition(bendInfo.count <= RigParams.bendSlots)
    }

    func shift(_ name: String, weight: [Float]) {
        shiftSlots[name] = shiftInfo.count; shiftInfo.append(take(weight))
        precondition(shiftInfo.count <= RigParams.shiftSlots)
    }

    /// A shift that reuses another part's weights (e.g. the head both tilts and slides).
    func shift(_ name: String, sharing bendName: String) {
        shiftSlots[name] = shiftInfo.count; shiftInfo.append(bendInfo[bendSlots[bendName]!.slot].weight)
        precondition(shiftInfo.count <= RigParams.shiftSlots)
    }

    func scale(_ name: String, weight: [Float]) {
        scaleSlots[name] = scaleInfo.count; scaleInfo.append(take(weight))
        precondition(scaleInfo.count <= RigParams.scaleSlots)
    }

    func fixed(_ channel: Int, _ values: [Float]) { _ = take(values, into: channel) }

    /// Parameter buffer with channel wiring filled in and every motion at rest.
    func restParams(frame: CGImage) -> [Float] {
        var p = [Float](repeating: 0, count: RigParams.count)
        p[RigParams.canvasW] = Float(width); p[RigParams.canvasH] = Float(height); p[RigParams.pad] = Float(rigPad)
        p[RigParams.baseW] = Float(frame.width); p[RigParams.baseH] = Float(frame.height)
        p[RigParams.scaleX] = 1; p[RigParams.scaleY] = 1; p[RigParams.opacity] = 1
        p[RigParams.lidLeft] = Float(lids.left); p[RigParams.lidRight] = Float(lids.right); p[RigParams.lidSplitX] = Float(lids.splitX)
        p[RigParams.lidClamp] = 22; p[RigParams.mouthMask] = -1
        for i in 0..<RigParams.bendSlots {
            let o = RigParams.bendBase + i * RigParams.bendStride
            if i < bendInfo.count {
                p[o] = Float(bendInfo[i].pivot.x); p[o + 1] = Float(bendInfo[i].pivot.y)
                p[o + 2] = Float(bendInfo[i].weight); p[o + 3] = Float(bendInfo[i].along)
            } else { p[o + 2] = -1; p[o + 3] = -1 }
        }
        for i in 0..<RigParams.shiftSlots { p[RigParams.shiftBase + i * RigParams.shiftStride] = i < shiftInfo.count ? Float(shiftInfo[i]) : -1 }
        for i in 0..<RigParams.scaleSlots {
            let o = RigParams.scaleBase + i * RigParams.scaleStride
            p[o] = i < scaleInfo.count ? Float(scaleInfo[i]) : -1; p[o + 3] = 1; p[o + 4] = 1
        }
        return p
    }

    /// Frees the baked weights once they live on the GPU; slot wiring stays for the motion code.
    func releaseWeights() {
        channels = channels.map { $0.map { _ in [] } }
    }

    /// Channels packed four at a time into RGBA8 maps, rows top-down.
    func packedMaps() -> [[UInt8]] {
        (0..<RigParams.channelCount / 4).map { t in
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for c in 0..<4 {
                guard let values = channels[t * 4 + c] else { continue }
                for i in 0..<(width * height) { bytes[i * 4 + c] = UInt8(max(0, min(255, (values[i] * 255).rounded()))) }
            }
            return bytes
        }
    }
}

enum CatRigs {
    /// Offsets that line other frames' faces up with a pose's head, measured on zoomed grids of the trimmed art.
    static let waveMouthOffset = CGPoint(x: 7, y: 13)
    static let yawnMouthOffset = CGPoint(x: 120, y: 25)

    static func build(_ sprites: Sprites) -> [String: PoseRig] {
        var rigs = [sitting(sprites[.idle]), sleeping(sprites[.sleep]), waving(sprites[.wave])] + walking(sprites[.walk])
        rigs.sort { $0.key < $1.key }
        return Dictionary(uniqueKeysWithValues: rigs.map { ($0.key, $0) })
    }

    /// Layers drawn for a pose, back to front.
    static func layers(for pose: Pose) -> [String] {
        pose == .walk ? ["walk.backFar", "walk.frontFar", "walk", "walk.backNear", "walk.frontNear"] : ["\(pose)"]
    }

    struct Leg {
        let name: String
        /// Outline of the leg in the walking frame, reaching up into the body so the joint stays covered.
        let outline: [(CGFloat, CGFloat)]
        let shoulder: (CGFloat, CGFloat), paw: (CGFloat, CGFloat)
        /// Below this line the leg is removed from the body layer.
        let belly: CGFloat
        var length: CGFloat { hypot(paw.0 - shoulder.0, paw.1 - shoulder.1) }
    }

    static let legs = [
        Leg(name: "frontNear", outline: [(60, 345), (120, 300), (170, 278), (232, 292), (252, 328), (222, 378), (190, 412), (55, 412)],
            shoulder: (215, 300), paw: (125, 388), belly: 322),
        Leg(name: "frontFar", outline: [(206, 334), (288, 328), (290, 404), (278, 410), (216, 410), (203, 398), (200, 368)],
            shoulder: (256, 300), paw: (246, 392), belly: 338),
        Leg(name: "backFar", outline: [(292, 318), (400, 316), (404, 410), (296, 410), (291, 380)],
            shoulder: (348, 298), paw: (342, 388), belly: 332),
        Leg(name: "backNear", outline: [(428, 300), (468, 240), (534, 262), (532, 410), (436, 410), (432, 352)],
            shoulder: (480, 280), paw: (484, 386), belly: 318),
    ]

    static func sitting(_ frame: CGImage) -> PoseRig {
        let r = PoseRig(pose: .idle, frame: frame)
        let tailRegion: [(CGFloat, CGFloat)] = [(0, 262), (150, 262), (186, 330), (198, 470), (0, 470)]
        let tail = r.radial((180, 398), start: 10, reach: 150), tailMask = r.polygon(tailRegion, feather: 9)
        r.bend("tail", pivot: (180, 398), weight: zip(tailMask, tail.weight).map(*), along: tail.along)
        let tip = r.radial((180, 398), start: 95, reach: 60)
        r.bend("tip", pivot: (180, 398), weight: zip(tailMask, tip.weight).map(*), along: tip.along)
        let head = zip(r.polygon([(95, -30), (500, -30), (500, 320), (95, 320)], feather: 14), r.above(318, span: 85)).map(*)
        r.bend("head", pivot: (286, 318), weight: head)
        r.shift("head", sharing: "head")
        let earR = r.radial((398, 130), start: 10, reach: 80)
        r.bend("earRight", pivot: (398, 130), weight: zip(r.polygon([(345, 10), (480, 10), (480, 150), (402, 162), (348, 118)], feather: 7), earR.weight).map(*))
        let earL = r.radial((206, 120), start: 10, reach: 90)
        r.bend("earLeft", pivot: (206, 120), weight: zip(r.polygon([(125, -10), (270, -10), (270, 60), (232, 124), (135, 134)], feather: 7), earL.weight).map(*))
        r.shift("irises", weight: r.ovals([((236, 171), (19, 17)), ((344, 193), (18, 17))], feather: 4))
        r.shift("muzzle", weight: r.ovals([((278, 238), (50, 32))], feather: 10))
        r.shift("chin", weight: r.ovals([((270, 292), (46, 26))], feather: 10))
        r.scale("pupilLeft", weight: r.ovals([((236, 171), (17, 15))], feather: 4))
        r.scale("pupilRight", weight: r.ovals([((344, 193), (16, 15))], feather: 4))
        r.fixed(RigParams.squeezeChannel, r.ovals([((235, 172), (33, 25)), ((343, 195), (31, 25))], feather: 5))
        r.fixed(RigParams.swapChannel, r.ovals([((235, 172), (40, 32)), ((343, 195), (38, 32))], feather: 5))
        r.fixed(RigParams.meowMouthChannel, r.ovals([((271, 256), (27, 18))], feather: 4))
        r.fixed(RigParams.yawnMouthChannel, r.ovals([((268, 272), (30, 31))], feather: 5))
        // Opening mouths are revealed from the upper lip downward instead of fading in.
        r.fixed(RigParams.revealChannel, r.field { _, y in Float(min(1, max(0, (y - 238) / 68))) })
        r.lids = (172 + CGFloat(rigPad), 196 + CGFloat(rigPad), 290 + CGFloat(rigPad))
        return r
    }

    /// The walking cat is split into a body and four legs drawn as separate layers, so each leg can swing
    /// from its shoulder or hip in its own order without dragging its neighbours along.
    static func walking(_ frame: CGImage) -> [PoseRig] {
        let r = PoseRig(pose: .walk, frame: frame)
        let outlines = Dictionary(uniqueKeysWithValues: legs.map { ($0.name, r.polygon($0.outline, feather: 1.2)) })
        var lower = [Float](repeating: 0, count: r.width * r.height)
        for leg in legs {
            let below = r.below(leg.belly, leg.belly + 12)
            for i in lower.indices { lower[i] = max(lower[i], outlines[leg.name]![i] * below[i]) }
        }
        r.cutOut(frame, keep: lower.map { 1 - $0 })

        let tailRegion: [(CGFloat, CGFloat)] = [(356, -20), (570, -20), (570, 236), (472, 266), (430, 240), (423, 150), (368, 120)]
        let tailMask = r.polygon(tailRegion, feather: 8)
        let tail = r.radial((452, 240), start: 20, reach: 190)
        r.bend("tail", pivot: (452, 240), weight: zip(tailMask, tail.weight).map(*), along: tail.along)
        let tip = r.radial((452, 240), start: 130, reach: 80)
        r.bend("tip", pivot: (452, 240), weight: zip(tailMask, tip.weight).map(*), along: tip.along)
        r.bend("head", pivot: (205, 258), weight: r.polygon([(-20, -20), (300, -20), (306, 128), (266, 246), (190, 318), (-20, 318)], feather: 18))
        r.shift("head", sharing: "head")
        let ear = r.radial((222, 118), start: 10, reach: 90)
        r.bend("ear", pivot: (222, 118), weight: zip(r.polygon([(162, 12), (268, 12), (272, 126), (172, 122)], feather: 7), ear.weight).map(*))
        r.shift("irises", weight: r.ovals([((51, 151), (10, 13)), ((132, 169), (15, 16))], feather: 3))
        r.fixed(RigParams.squeezeChannel, r.ovals([((51, 151), (15, 17)), ((132, 169), (21, 21))], feather: 4))
        r.lids = (151 + CGFloat(rigPad), 169 + CGFloat(rigPad), 90 + CGFloat(rigPad))

        var layers = [r]
        for leg in legs {
            let layer = PoseRig(pose: .walk, key: "walk.\(leg.name)", frame: frame)
            // The far front leg is partly hidden behind the near one in the drawing; refill that fur.
            // Widen the near leg's footprint so its soft edge hairs are replaced too, not left floating on the far leg.
            let hole = leg.name == "frontFar" ? zip(outlines["frontFar"]!, r.polygon(CatRigs.legs[0].outline, feather: 4)).map { min($0 * 20, $1 * 20, 1) } : nil
            layer.cutOut(frame, keep: outlines[leg.name]!, hole: hole)
            let bend = layer.along(from: leg.shoulder, to: leg.paw, start: 12, reach: leg.length * 0.8)
            layer.bend("leg", pivot: leg.shoulder, weight: bend)
            layer.shift("lift", weight: bend.map { pow($0, 1.6) })
            layers.append(layer)
        }
        return layers
    }

    static func sleeping(_ frame: CGImage) -> PoseRig {
        let r = PoseRig(pose: .sleep, frame: frame)
        r.scale("breath", weight: r.polygon([(250, 40), (600, 40), (600, 360), (250, 360)], feather: 30))
        let head = r.polygon([(-40, -30), (300, -30), (320, 250), (240, 330), (-40, 330)], feather: 22)
        r.bend("head", pivot: (230, 290), weight: head)
        r.shift("head", sharing: "head")
        let earUp = r.radial((255, 100), start: 8, reach: 80)
        r.bend("earUp", pivot: (255, 100), weight: zip(r.polygon([(190, -20), (300, -20), (300, 105), (195, 105)], feather: 6), earUp.weight).map(*))
        let earSide = r.radial((92, 160), start: 8, reach: 70)
        r.bend("earSide", pivot: (92, 160), weight: zip(r.polygon([(-10, 108), (112, 108), (112, 196), (-10, 196)], feather: 6), earSide.weight).map(*))
        r.shift("muzzle", weight: r.ovals([((216, 244), (40, 24))], feather: 8))
        r.shift("paws", weight: zip(r.polygon([(55, 258), (292, 258), (292, 330), (55, 330)], feather: 8), r.below(262, 300)).map(*))
        r.lids = (220 + CGFloat(rigPad), 220 + CGFloat(rigPad), 0)
        return r
    }

    static func waving(_ frame: CGImage) -> PoseRig {
        let r = PoseRig(pose: .wave, frame: frame)
        let pawRegion: [(CGFloat, CGFloat)] = [(95, 205), (215, 205), (222, 300), (215, 365), (160, 365), (100, 300)]
        let pawMask = r.polygon(pawRegion, feather: 7)
        let paw = r.radial((190, 345), start: 20, reach: 120)
        r.bend("paw", pivot: (190, 345), weight: zip(pawMask, paw.weight).map(*))
        let headArea = zip(r.polygon([(110, -30), (500, -30), (500, 330), (110, 330)], feather: 14), r.above(330, span: 90)).map(*)
        r.bend("head", pivot: (275, 335), weight: zip(headArea, pawMask).map { $0 * (1 - $1) })
        r.shift("head", sharing: "head")
        let tailRegion: [(CGFloat, CGFloat)] = [(0, 290), (120, 290), (150, 350), (150, 470), (0, 470)]
        let tail = r.radial((118, 392), start: 10, reach: 120)
        r.bend("tail", pivot: (118, 392), weight: zip(r.polygon(tailRegion, feather: 9), tail.weight).map(*), along: tail.along)
        let earL = r.radial((190, 110), start: 10, reach: 90)
        r.bend("earLeft", pivot: (190, 110), weight: zip(r.polygon([(120, -10), (250, -10), (250, 60), (215, 115), (130, 125)], feather: 7), earL.weight).map(*))
        let earR = r.radial((400, 140), start: 10, reach: 80)
        r.bend("earRight", pivot: (400, 140), weight: zip(r.polygon([(350, 40), (480, 40), (480, 170), (405, 175), (355, 130)], feather: 7), earR.weight).map(*))
        return r
    }
}
