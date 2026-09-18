import AppKit
import Metal
import QuartzCore

/// Draws rigged poses on the GPU. Each pixel looks up how far each part (tail, head, legs...) has moved,
/// then samples the original art there, so the cat deforms smoothly at any size and frame rate.
final class RigRenderer {
    struct Draw {
        /// Rig key, e.g. "idle" or "walk.frontNear".
        var layer: String
        var params: [Float]
        /// Where the padded canvas lands, in target pixels with the origin at the bottom left.
        var rect: CGRect
        /// Horizontal scale for turning around: 1 faces the art's way, -1 mirrors it.
        var flip: CGFloat = 1
    }

    private struct PoseTextures { let base: MTLTexture; let overlay: MTLTexture; let maps: [MTLTexture] }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let artSampler: MTLSamplerState
    private let mapSampler: MTLSamplerState
    private var textures: [String: PoseTextures] = [:]
    private let waveMouth: MTLTexture
    private let yawnMouth: MTLTexture
    private let empty: MTLTexture
    let pixelFormat: MTLPixelFormat = .bgra8Unorm

    init(sprites: Sprites, rigs: [String: PoseRig]) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "RigRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "此 Mac 不支持 Metal。"])
        }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: RigRenderer.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "rig_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "rig_fragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = pixelFormat
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one; color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha; color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let art = MTLSamplerDescriptor()
        art.minFilter = .linear; art.magFilter = .linear; art.mipFilter = .linear
        art.sAddressMode = .clampToZero; art.tAddressMode = .clampToZero
        artSampler = device.makeSamplerState(descriptor: art)!
        let maps = MTLSamplerDescriptor()
        maps.minFilter = .linear; maps.magFilter = .linear
        maps.sAddressMode = .clampToZero; maps.tAddressMode = .clampToZero
        mapSampler = device.makeSamplerState(descriptor: maps)!

        empty = RigRenderer.texture(device, width: 1, height: 1, bytes: [0, 0, 0, 0], mipmapped: false)
        let art2 = { (image: CGImage) in RigRenderer.artTexture(device, queue, image) }
        waveMouth = art2(sprites[.wave])
        yawnMouth = art2(sprites[.yawn])
        let blink = art2(sprites[.blink])
        for (key, rig) in rigs {
            let maps = rig.packedMaps().map { RigRenderer.texture(device, width: rig.width, height: rig.height, bytes: $0, mipmapped: false) }
            textures[key] = PoseTextures(base: art2(rig.base), overlay: key == "idle" ? blink : empty, maps: maps)
        }
    }

    // MARK: Textures

    private static func texture(_ device: MTLDevice, width: Int, height: Int, bytes: [UInt8], mipmapped: Bool) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: mipmapped)
        d.usage = .shaderRead
        d.storageMode = .shared
        let t = device.makeTexture(descriptor: d)!
        bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        return t
    }

    /// Premultiplied, mipmapped copy of a frame so the shrunken cat stays crisp without shimmering.
    private static func artTexture(_ device: MTLDevice, _ queue: MTLCommandQueue, _ image: CGImage) -> MTLTexture {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let t = texture(device, width: w, height: h, bytes: bytes, mipmapped: true)
        if let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t); blit.endEncoding(); buffer.commit(); buffer.waitUntilCompleted()
        }
        return t
    }

    // MARK: Drawing

    /// `inspect` receives the presented frame (the layer must not be framebuffer-only); used for diagnostics.
    func render(_ draws: [Draw], to layer: CAMetalLayer, inspect: ((MTLTexture) -> Void)? = nil) {
        guard let drawable = layer.nextDrawable() else { return }
        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        render(draws, target: drawable.texture, size: size, clear: MTLClearColorMake(0, 0, 0, 0), present: drawable, wait: inspect != nil)
        inspect?(drawable.texture)
    }

    func render(_ draws: [Draw], target: MTLTexture, size: CGSize, clear: MTLClearColor, present drawable: CAMetalDrawable? = nil, wait: Bool = false) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clear
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(artSampler, index: 0)
        encoder.setFragmentSamplerState(mapSampler, index: 1)
        for draw in draws {
            guard let t = textures[draw.layer], draw.params[RigParams.opacity] > 0.001, abs(draw.flip) > 0.001 else { continue }
            let r = draw.rect
            let cx = r.midX, half = r.width / 2 * abs(draw.flip)
            let x0 = Float((cx - half) / size.width * 2 - 1), x1 = Float((cx + half) / size.width * 2 - 1)
            let y0 = Float(r.minY / size.height * 2 - 1), y1 = Float(r.maxY / size.height * 2 - 1)
            let cw = draw.params[RigParams.canvasW], ch = draw.params[RigParams.canvasH]
            let (u0, u1): (Float, Float) = draw.flip < 0 ? (cw, 0) : (0, cw)
            var vertices: [Float] = [x0, y0, u0, ch, x1, y0, u1, ch, x0, y1, u0, 0, x1, y1, u1, 0]
            encoder.setVertexBytes(&vertices, length: vertices.count * 4, index: 0)
            var params = draw.params
            encoder.setFragmentBytes(&params, length: params.count * 4, index: 0)
            encoder.setFragmentTexture(t.base, index: 0)
            encoder.setFragmentTexture(t.overlay, index: 1)
            encoder.setFragmentTexture(draw.params[RigParams.mouthSource] > 0.5 ? yawnMouth : waveMouth, index: 2)
            for (i, map) in t.maps.enumerated() { encoder.setFragmentTexture(map, index: 3 + i) }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        if let drawable { buffer.present(drawable) }
        buffer.commit()
        if wait { buffer.waitUntilCompleted() }
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 canvas; };

    vertex VOut rig_vertex(uint vid [[vertex_id]], constant float *V [[buffer(0)]]) {
        VOut o;
        o.position = float4(V[vid * 4], V[vid * 4 + 1], 0.0, 1.0);
        o.canvas = float2(V[vid * 4 + 2], V[vid * 4 + 3]);
        return o;
    }

    static float channel(int c, array<float4, 5> m) {
        if (c < 0) return 0.0;
        return m[c / 4][c % 4];
    }

    fragment float4 rig_fragment(VOut in [[stage_in]], constant float *P [[buffer(0)]],
                                 texture2d<float> base [[texture(0)]], texture2d<float> overlay [[texture(1)]],
                                 texture2d<float> mouth [[texture(2)]],
                                 texture2d<float> m0 [[texture(3)]], texture2d<float> m1 [[texture(4)]],
                                 texture2d<float> m2 [[texture(5)]], texture2d<float> m3 [[texture(6)]],
                                 texture2d<float> m4 [[texture(7)]],
                                 sampler art [[sampler(0)]], sampler maps [[sampler(1)]]) {
        float2 canvas = float2(P[\(RigParams.canvasW)], P[\(RigParams.canvasH)]);
        // Whole-body motion first (sway, pitch, breathing, rise), as an inverse mapping.
        float2 q = in.canvas - float2(P[\(RigParams.shiftX)], P[\(RigParams.shiftY)]);
        float2 pivot = float2(P[\(RigParams.rotatePivotX)], P[\(RigParams.rotatePivotY)]);
        float ca = cos(-P[\(RigParams.angle)]), sa = sin(-P[\(RigParams.angle)]);
        float2 r = q - pivot;
        q = pivot + float2(ca * r.x - sa * r.y, sa * r.x + ca * r.y);
        float2 scalePivot = float2(P[\(RigParams.scalePivotX)], P[\(RigParams.scalePivotY)]);
        q = scalePivot + (q - scalePivot) / float2(P[\(RigParams.scaleX)], P[\(RigParams.scaleY)]);

        float2 uv = q / canvas;
        array<float4, 5> m = { m0.sample(maps, uv), m1.sample(maps, uv), m2.sample(maps, uv), m3.sample(maps, uv), m4.sample(maps, uv) };
        float2 d = float2(0.0);
        for (int i = 0; i < \(RigParams.bendSlots); i++) {
            int o = \(RigParams.bendBase) + i * \(RigParams.bendStride);
            float w = channel(int(P[o + 2]), m);
            if (w < 0.0005) continue;
            float angle = P[o + 4];
            int alongChannel = int(P[o + 3]);
            if (alongChannel >= 0) {
                float a = clamp(channel(alongChannel, m), 0.0, 1.0) * \(Float(RigParams.angleSamples - 1));
                int k = min(int(a), \(RigParams.angleSamples - 2));
                angle = mix(P[o + 4 + k], P[o + 5 + k], a - float(k));
            }
            float th = -angle * w;
            float2 rr = q - float2(P[o], P[o + 1]);
            float c = cos(th), s = sin(th);
            d += float2((c - 1.0) * rr.x - s * rr.y, s * rr.x + (c - 1.0) * rr.y);
        }
        for (int i = 0; i < \(RigParams.shiftSlots); i++) {
            int o = \(RigParams.shiftBase) + i * \(RigParams.shiftStride);
            float w = channel(int(P[o]), m);
            d += w * float2(P[o + 1], P[o + 2]);
        }
        for (int i = 0; i < \(RigParams.scaleSlots); i++) {
            int o = \(RigParams.scaleBase) + i * \(RigParams.scaleStride);
            float w = channel(int(P[o]), m);
            if (w < 0.0005) continue;
            float2 k = float2(P[o + 3], P[o + 4]);
            d -= (q - float2(P[o + 1], P[o + 2])) * (1.0 - 1.0 / k) * w;
        }

        float2 s = q + d;
        float2 suv = s / canvas;
        array<float4, 5> n = { m0.sample(maps, suv), m1.sample(maps, suv), m2.sample(maps, suv), m3.sample(maps, suv), m4.sample(maps, suv) };
        float pad = P[\(RigParams.pad)];
        // Eyelids: squeeze the open eye toward the lid line before the closed-eye art takes over.
        float lid = s.x < P[\(RigParams.lidSplitX)] ? P[\(RigParams.lidLeft)] : P[\(RigParams.lidRight)];
        float squeeze = clamp((s.y - lid) * P[\(RigParams.lidGrow)], -P[\(RigParams.lidClamp)], P[\(RigParams.lidClamp)]) * n[3].r;
        float2 baseSize = float2(P[\(RigParams.baseW)], P[\(RigParams.baseH)]);
        float4 color = base.sample(art, (s + float2(0.0, squeeze) - pad) / baseSize);
        float swapAmount = P[\(RigParams.blinkSwap)] * n[3].g;
        if (swapAmount > 0.0) {
            color = mix(color, overlay.sample(art, (s - pad) / float2(P[\(RigParams.overlayW)], P[\(RigParams.overlayH)])), swapAmount);
        }
        float open = P[\(RigParams.mouthOpen)];
        if (open > 0.0) {
            float mask = channel(int(P[\(RigParams.mouthMask)]), n);
            float edge = open * 1.15;
            float shown = mask * (1.0 - smoothstep(edge - 0.15, edge, n[3].a));
            float2 offset = float2(P[\(RigParams.mouthOffsetX)], P[\(RigParams.mouthOffsetY)]);
            color = mix(color, mouth.sample(art, (s - pad - offset) / float2(P[\(RigParams.mouthW)], P[\(RigParams.mouthH)])), shown);
        }
        return color * P[\(RigParams.opacity)];
    }
    """
}
