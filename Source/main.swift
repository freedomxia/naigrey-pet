import AppKit
import QuartzCore

private func curve(_ name: CAMediaTimingFunctionName) -> CAMediaTimingFunction { CAMediaTimingFunction(name: name) }
private func squash(_ x: CGFloat, _ y: CGFloat) -> NSValue { NSValue(caTransform3D: CATransform3DMakeScale(x, y, 1)) }
private let unscaled = NSValue(caTransform3D: CATransform3DIdentity)
private func still(_ changes: () -> Void) {
    CATransaction.begin(); CATransaction.setDisableActions(true); changes(); CATransaction.commit()
}

/// Motion runs on Core Animation's render server, so it stays smooth at the display's refresh rate
/// no matter what the main thread is doing. Each rig layer animates a single key path, which lets a
/// new motion blend in from wherever the previous one currently is instead of snapping.
private func play(_ layer: CALayer, _ keyPath: String, rest: Any, from: Any? = nil, values: [Any] = [],
                  times: [NSNumber]? = nil, curves: [CAMediaTimingFunction]? = nil,
                  duration: CFTimeInterval = 0.2, repeats: Bool = false, blend: CFTimeInterval = 0.15) {
    let current = from ?? layer.presentation()?.value(forKeyPath: keyPath) ?? rest
    layer.removeAnimation(forKey: "settle"); layer.removeAnimation(forKey: "motion")
    still { layer.setValue(rest, forKeyPath: keyPath) }
    let now = CACurrentMediaTime()
    if !values.isEmpty {
        let motion = CAKeyframeAnimation(keyPath: keyPath)
        motion.values = values
        motion.keyTimes = times
        motion.timingFunctions = curves ?? Array(repeating: curve(.easeInEaseOut), count: values.count - 1)
        motion.duration = duration
        motion.beginTime = now + blend
        motion.fillMode = .backwards
        if repeats { motion.repeatCount = .infinity }
        layer.add(motion, forKey: "motion")
    }
    let settle = CABasicAnimation(keyPath: keyPath)
    settle.fromValue = current
    settle.toValue = values.first ?? rest
    settle.duration = values.isEmpty ? duration : blend
    settle.timingFunction = curve(values.isEmpty ? .easeInEaseOut : .easeOut)
    layer.add(settle, forKey: "settle")
}

final class PetView: NSView {
    enum Motion { case sit, sleep, walk }

    weak var owner: PetController?
    private(set) var layout: PetLayout?
    private(set) var pose: Pose = .idle
    private(set) var facingRight = false
    /// The waving art raises its paw on the viewer's left; mirror it to swat at something on the right.
    var waveMirrored = false
    var mirrored: Bool { (pose == .walk && facingRight) || (pose == .wave && waveMirrored) }
    var pressPoint = NSPoint.zero
    var pressOrigin = NSPoint.zero
    var dragged = false
    var renderer: RigRenderer? { didSet { canvas.device = renderer?.device } }
    var cat: CatMotion?

    // rig: hops · tilt: sway · body: squash for pose changes and being carried.
    // The cat itself is drawn on the GPU into `canvas`, where its tail, ears, eyes, head and legs move.
    private let rig = CALayer(), tilt = CALayer(), body = CALayer()
    private let canvas = CAMetalLayer()
    private let groundShadow = CAGradientLayer()
    private let bubble = CALayer(), bubbleText = CATextLayer()
    private var motion: Motion?
    private var motionToken = 0
    private var bubbleToken = 0
    private var lifted = false
    private var clock: AnyObject?
    private var backupClock: Timer?
    private var lastFrame = CACurrentMediaTime()
    private var lastTickAt = CACurrentMediaTime()
    private var fade: (from: Pose, start: Double, duration: Double)?
    private var flipFrom: CGFloat = 1, flipTo: CGFloat = 1, flipStart = -10.0
    private var lastPointer: (point: CGPoint, time: Double)?
    private var pointerSpeed: CGFloat = 0
    /// Diagnostics: how many frames were drawn since the last check (NAIGREY_CPULOG).
    private(set) var framesDrawn = 0
    private(set) var ticksRun = 0
    /// Diagnostics: longest gap between drawn frames since the last check (a hitch shows up here).
    private(set) var worstGap = 0.0
    private var fullFrameRate = true
    private var skipTick = false
    /// False while a video clip stands in for the drawn cat; rendering pauses once it has faded out.
    private(set) var catVisible = true
    private var hiddenAt = 0.0
    /// Diagnostics: NAIGREY_SNAPSHOT=/path/prefix saves what the GPU presents twice a second (up to 60 frames).
    private let snapshotPrefix = ProcessInfo.processInfo.environment["NAIGREY_SNAPSHOT"]
    private var snapshotsTaken = 0, lastSnapshot = 0.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let root = layer!
        root.backgroundColor = NSColor.clear.cgColor
        groundShadow.type = .radial
        groundShadow.colors = [NSColor(white: 0, alpha: 0.2).cgColor, NSColor(white: 0, alpha: 0).cgColor]
        groundShadow.startPoint = CGPoint(x: 0.5, y: 0.5)
        groundShadow.endPoint = CGPoint(x: 1, y: 1)
        root.addSublayer(groundShadow)
        root.addSublayer(rig); rig.addSublayer(tilt); tilt.addSublayer(body)
        canvas.pixelFormat = .bgra8Unorm
        canvas.isOpaque = false
        canvas.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        canvas.framebufferOnly = snapshotPrefix == nil
        body.addSublayer(canvas)
        bubble.backgroundColor = NSColor(calibratedRed: 1, green: 0.98, blue: 0.95, alpha: 0.97).cgColor
        bubble.anchorPoint = CGPoint(x: 0.5, y: 0)
        bubble.opacity = 0
        bubble.shadowColor = NSColor.black.cgColor
        bubble.shadowOpacity = 0.14
        bubble.shadowRadius = 2
        bubble.shadowOffset = CGSize(width: 0, height: -1)
        bubbleText.alignmentMode = .center
        bubbleText.foregroundColor = NSColor(calibratedWhite: 0.26, alpha: 1).cgColor
        bubble.addSublayer(bubbleText)
        root.addSublayer(bubble)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityFrame() -> NSRect {
        guard let layout, let window else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(layout.rect(pose, mirrored: mirrored), to: nil))
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    // MARK: Layout

    func apply(_ layout: PetLayout) {
        self.layout = layout
        let size = layout.size
        still {
            for layer in [rig, tilt, body] {
                layer.anchorPoint = CGPoint(x: 0.5, y: PetLayout.ground / size.height)
                layer.bounds = CGRect(origin: .zero, size: size)
                layer.position = CGPoint(x: size.width / 2, y: PetLayout.ground)
            }
            canvas.frame = CGRect(origin: .zero, size: size)
        }
        updateScale()
        placeShadow(animated: false)
        motion = nil
        startLoops()
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        still {
            canvas.contentsScale = scale
            canvas.drawableSize = CGSize(width: canvas.bounds.width * scale, height: canvas.bounds.height * scale)
            bubble.contentsScale = scale
            bubbleText.contentsScale = scale
        }
    }

    private func placeShadow(animated: Bool) {
        guard let layout else { return }
        let r = layout.rect(pose, mirrored: mirrored)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.35)
        groundShadow.bounds = CGRect(x: 0, y: 0, width: r.width * 0.78, height: max(4, layout.catHeight * 0.075))
        groundShadow.position = CGPoint(x: r.midX, y: PetLayout.ground + 1)
        CATransaction.commit()
    }

    func resetFrameCount() { framesDrawn = 0; ticksRun = 0; worstGap = 0 }

    /// Diagnostics: why the frame clock might not be firing.
    func clockStatus() -> String {
        var parts: [String] = []
        if #available(macOS 14.0, *), let link = clock as? CADisplayLink {
            parts.append("link paused=\(link.isPaused) ts=\(String(format: "%.1f", link.timestamp))")
        } else if clock is Timer {
            parts.append("timer")
        } else {
            parts.append("no clock")
        }
        if let window {
            parts.append("onScreen=\(window.isVisible) occluded=\(!window.occlusionState.contains(.visible)) alpha=\(window.alphaValue)")
        } else {
            parts.append("no window")
        }
        parts.append("hidden=\(!catVisible)")
        return parts.joined(separator: " ")
    }

    func setCatVisible(_ visible: Bool, duration: Double = 0.2) {
        guard visible != catVisible else { return }
        catVisible = visible
        hiddenAt = CACurrentMediaTime()
        for layer in [canvas, groundShadow] as [CALayer] {
            let from = layer.presentation()?.opacity ?? layer.opacity
            still { layer.opacity = visible ? 1 : 0 }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = visible ? 1 : 0
            fade.duration = duration
            layer.add(fade, forKey: "visibility")
        }
    }

    // MARK: Frame clock

    /// Renders once per display refresh (capped at 60 fps). Everything alive about the cat happens here.
    func startClock() {
        guard clock == nil else { return }
        if #available(macOS 14.0, *) {
            let link = displayLink(target: self, selector: #selector(renderTick(_:)))
            // Without a range the link runs at the display's full 120 Hz, which the cat doesn't need.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            clock = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(renderTick(_:)), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
        }
        let backup = Timer(timeInterval: 1.0 / 20, target: self, selector: #selector(checkClock), userInfo: nil, repeats: true)
        RunLoop.main.add(backup, forMode: .common)
        backupClock = backup
    }

    func stopClock() {
        if #available(macOS 14.0, *) { (clock as? CADisplayLink)?.invalidate() }
        (clock as? Timer)?.invalidate()
        clock = nil
        backupClock?.invalidate()
        backupClock = nil
    }

    /// macOS pauses a display link while its window is covered. That is fine when nothing is visible, but if the
    /// window is on screen and the link has gone quiet, keep drawing at a modest rate from a timer instead.
    @objc private func checkClock() {
        let now = CACurrentMediaTime()
        guard now - lastTickAt > 0.25, let window, window.occlusionState.contains(.visible), window.isVisible else { return }
        renderTick(nil)
    }

    private func currentFlip(_ now: Double) -> CGFloat {
        flipFrom + (flipTo - flipFrom) * CGFloat(ease((now - flipStart) / 0.18))
    }

    /// Converts a point in this view to a pose's canvas pixels (y down), undoing the walking mirror.
    private func canvasPoint(_ local: CGPoint, pose: Pose, flip: CGFloat) -> CGPoint {
        guard let layout else { return .zero }
        let r = layout.rects[pose.rawValue], pad = CGFloat(rigPad) * layout.scale
        let mirror = (pose == .walk && flip < 0) || (pose == .wave && waveMirrored)
        let x = mirror ? layout.size.width - local.x : local.x
        return CGPoint(x: (x - r.minX + pad) / layout.scale, y: (r.maxY + pad - local.y) / layout.scale)
    }

    private func draws(_ pose: Pose, opacity: Double, flip: CGFloat, backing: CGFloat) -> [RigRenderer.Draw] {
        guard let layout, let cat else { return [] }
        let pad = CGFloat(rigPad) * layout.scale
        var r = layout.rects[pose.rawValue].insetBy(dx: -pad, dy: -pad)
        let f = pose == .walk ? flip : (pose == .wave && waveMirrored ? -1 : 1)
        r.origin.x = layout.size.width / 2 + (r.midX - layout.size.width / 2) * f - r.width / 2
        let rect = CGRect(x: r.minX * backing, y: r.minY * backing, width: r.width * backing, height: r.height * backing)
        return CatRigs.layers(for: pose).map { RigRenderer.Draw(layer: $0, params: cat.params(for: $0, opacity: opacity), rect: rect, flip: f) }
    }

    @objc func renderTick(_ sender: Any?) {
        guard let renderer, let cat, let owner, let window else { return }
        let now = CACurrentMediaTime()
        let dt = min(0.05, max(0.001, now - lastFrame)); lastFrame = now
        ticksRun += 1
        worstGap = max(worstGap, now - lastTickAt)
        lastTickAt = now
        let flip = currentFlip(now)

        var senses = CatSenses()
        owner.stepBall(dt)
        // Look at the ball while playing with it or while it moves; otherwise at the mouse.
        let focus = owner.gazeFocus()
        let local = convert(window.convertPoint(fromScreen: focus?.point ?? NSEvent.mouseLocation), from: nil)
        let point = canvasPoint(local, pose: pose, flip: flip)
        if let last = lastPointer {
            let instant = hypot(point.x - last.point.x, point.y - last.point.y) / CGFloat(max(0.001, now - last.time))
            pointerSpeed += (instant - pointerSpeed) * 0.35
        }
        lastPointer = (point, now)
        senses.pointer = point
        senses.pointerSpeed = pointerSpeed
        senses.pointerOverHead = focus == nil && pose == .idle && point.x > 135 && point.x < 520 && point.y > 10 && point.y < 300
        senses.fixated = focus?.fixated ?? false
        senses.held = lifted
        cat.update(dt: dt, pose: pose, walking: owner.wantsToWalk, senses: senses)
        let busy = cat.needsFullFrameRate || fade != nil || now - flipStart < 0.3 || lifted || owner.ballIsLively || owner.act != nil
        if #available(macOS 14.0, *), let link = clock as? CADisplayLink, fullFrameRate != busy {
            fullFrameRate = busy
            link.preferredFrameRateRange = busy ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60) : CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        }
        if !busy && clock is Timer {  // macOS 13 fallback: skip every other tick when nothing quick is happening
            skipTick.toggle()
            if skipTick { return }
        }

        if !catVisible && now - hiddenAt > 0.3 { return }
        let backing = canvas.contentsScale
        var draws: [RigRenderer.Draw] = []
        if let f = fade {
            let u = (now - f.start) / f.duration
            if u >= 1 { fade = nil } else {
                // The incoming pose covers the outgoing one before that fades, so the cat never turns see-through.
                draws += self.draws(f.from, opacity: 1 - ease((u - 0.3) / 0.7), flip: flip, backing: backing)
                draws += self.draws(pose, opacity: ease(u / 0.7), flip: flip, backing: backing)
            }
        }
        if draws.isEmpty { draws = self.draws(pose, opacity: 1, flip: flip, backing: backing) }
        framesDrawn += 1
        guard let prefix = snapshotPrefix, now - lastSnapshot >= 0.5, snapshotsTaken < 60 else {
            renderer.render(draws, to: canvas); return
        }
        lastSnapshot = now
        snapshotsTaken += 1
        let name = String(format: "%@-%02d-%@.png", prefix, snapshotsTaken, "\(pose)")
        renderer.render(draws, to: canvas) { texture in
            let w = texture.width, h = texture.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            if let image = ctx?.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: name))
            }
        }
    }

    // MARK: Poses

    func show(_ next: Pose, from old: Pose) {
        pose = next
        guard let layout else { return }
        startLoops()
        placeShadow(animated: true)
        let bodyChange = [old, next].contains(.sleep) || [old, next].contains(.walk)
        if bodyChange && !lifted {
            // Sitting, walking and lying share few pixels, so a plain dissolve shows two cats.
            // Hide the swap inside a quick crouch-and-spring; the new pose lands on the rebound.
            let hop = layout.catHeight * 0.04
            switch (old, next) {
            case (.sleep, .idle):
                crossfade(from: old, over: 0.12, delay: 0.15)
                play(body, "transform", rest: unscaled, values: [unscaled, squash(1.05, 0.9), squash(0.96, 1.08), squash(0.97, 1.07), unscaled],
                     times: [0, 0.18, 0.55, 0.8, 1], duration: 1.1, blend: 0.03)
                play(tilt, "transform.rotation.z", rest: 0, values: [0, 0, -0.03, -0.03, 0], times: [0, 0.18, 0.55, 0.8, 1], duration: 1.1)
                resumeLoops(after: 1.15)
            case (_, .sleep):
                crossfade(from: old, over: 0.12, delay: 0.13)
                play(body, "transform", rest: unscaled, values: [unscaled, squash(1.05, 0.88), squash(1.01, 1.02), unscaled],
                     times: [0, 0.35, 0.7, 1], duration: 0.5, blend: 0.03)
                resumeLoops(after: 0.52)
            default:
                crossfade(from: old, over: 0.1, delay: 0.1)
                play(body, "transform", rest: unscaled, values: [unscaled, squash(1.05, 0.9), squash(0.97, 1.05), unscaled],
                     times: [0, 0.35, 0.7, 1], duration: 0.38, blend: 0.03)
                play(rig, "transform.translation.y", rest: 0, values: [0, 0, hop, 0], times: [0, 0.3, 0.62, 1],
                     curves: [curve(.linear), curve(.easeOut), curve(.easeIn)], duration: 0.38, blend: 0.03)
                resumeLoops(after: 0.4)
            }
        } else {
            crossfade(from: old, over: 0.22)
        }
        if next == .wave && owner?.play != .swat { wave() }
    }

    /// Crouch low and wiggle before pouncing.
    func crouch(duration: Double) {
        guard !lifted else { return }
        let d = max(0.35, duration)
        play(body, "transform", rest: unscaled, values: [unscaled, squash(1.05, 0.9), squash(1.06, 0.89), squash(1.05, 0.9), unscaled],
             times: [0, 0.25, 0.6, 0.9, 1], duration: d, blend: 0.03)
        play(tilt, "transform.rotation.z", rest: 0, values: [0, 0.025, -0.025, 0.025, -0.02, 0], duration: d)
        resumeLoops(after: d + 0.05)
    }

    private func crossfade(from old: Pose, over duration: Double, delay: Double = 0) {
        fade = (old, CACurrentMediaTime() + delay, duration)
    }

    /// Breathing, stepping and sway live in the GPU rig now; the layers only settle back to rest.
    private func startLoops() {
        guard !lifted else { return }
        let next: Motion = pose == .sleep ? .sleep : pose == .walk ? .walk : .sit
        guard next != motion else { return }
        motion = next
        motionToken += 1
        play(rig, "transform.translation.y", rest: 0)
        play(tilt, "transform.rotation.z", rest: 0)
        play(body, "transform", rest: unscaled)
        play(groundShadow, "transform", rest: unscaled)
    }

    /// A one-off body motion; the resting state picks up again once it finishes.
    private func resumeLoops(after seconds: Double) {
        motion = nil
        motionToken += 1
        let token = motionToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, token == self.motionToken else { return }
            self.startLoops()
        }
    }

    func face(right: Bool, animated: Bool) {
        guard right != facingRight else { return }
        facingRight = right
        let now = CACurrentMediaTime()
        flipFrom = currentFlip(now)
        flipTo = right ? -1 : 1
        flipStart = animated ? now : now - 1
        placeShadow(animated: animated)
    }

    private func wave() {
        guard let layout, !lifted else { return }
        let hop = layout.catHeight * 0.035
        play(rig, "transform.translation.y", rest: 0, values: [0, hop, 0], times: [0, 0.4, 1],
             curves: [curve(.easeOut), curve(.easeIn)], duration: 0.4, blend: 0.05)
        let paw = layout.rects[Pose.wave.rawValue]
        let start = CGPoint(x: paw.minX + paw.width * 0.3, y: paw.minY + paw.height * 0.7)
        for i in 0..<2 {
            particle("♥", color: NSColor(calibratedRed: 1, green: 0.52, blue: 0.62, alpha: 1), at: start,
                     size: layout.fontSize * (i == 0 ? 1.1 : 0.85), rise: layout.catHeight * 0.32, duration: 1.4, delay: Double(i) * 0.3)
        }
    }

    func replayWave() { wave() }

    func lift() {
        guard let layout, !lifted else { return }
        lifted = true
        motion = nil
        motionToken += 1
        play(rig, "transform.translation.y", rest: layout.catHeight * 0.06, duration: 0.18)
        play(tilt, "transform.rotation.z", rest: 0, values: [0, 0.06, 0, -0.06, 0], duration: 1.1, repeats: true)
        play(body, "transform", rest: squash(0.97, 1.04), duration: 0.2)
        play(groundShadow, "transform", rest: squash(0.65, 0.65), duration: 0.2)
    }

    func drop() {
        guard let layout, lifted else { return }
        lifted = false
        let h = layout.catHeight * 0.06
        play(rig, "transform.translation.y", rest: 0, values: [h, 0, h * 0.3, 0], times: [0, 0.5, 0.75, 1],
             curves: [curve(.easeIn), curve(.easeOut), curve(.easeIn)], duration: 0.4, blend: 0.03)
        play(tilt, "transform.rotation.z", rest: 0, duration: 0.25)
        play(body, "transform", rest: unscaled, values: [squash(0.97, 1.04), squash(0.97, 1.04), squash(1.07, 0.92), unscaled],
             times: [0, 0.45, 0.62, 1], duration: 0.5, blend: 0.03)
        play(groundShadow, "transform", rest: unscaled, duration: 0.3)
        resumeLoops(after: 0.55)
    }

    // MARK: Effects

    func puffZ() {
        guard let layout else { return }
        let head = layout.rects[Pose.sleep.rawValue]
        particle("z", color: NSColor(calibratedRed: 0.5, green: 0.53, blue: 0.7, alpha: 1),
                 at: CGPoint(x: head.minX + head.width * 0.26, y: head.minY + head.height * 0.85),
                 size: layout.fontSize * CGFloat.random(in: 0.9...1.3), rise: layout.catHeight * 0.4, duration: 2.6)
    }

    private func particle(_ text: String, color: NSColor, at start: CGPoint, size: CGFloat, rise: CGFloat,
                          duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        let p = CATextLayer()
        p.string = text
        p.font = NSFont.systemFont(ofSize: size, weight: .bold)
        p.fontSize = size
        p.foregroundColor = color.cgColor
        p.alignmentMode = .center
        p.contentsScale = window?.backingScaleFactor ?? 2
        p.shadowColor = NSColor.white.cgColor
        p.shadowOpacity = 0.9
        p.shadowRadius = 1.2
        p.shadowOffset = .zero
        still {
            p.bounds = CGRect(x: 0, y: 0, width: size * 1.6, height: size * 1.4)
            p.position = start
            p.opacity = 0
            layer?.addSublayer(p)
        }
        let drift = CGFloat.random(in: -0.4...0.7) * size
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = [start, CGPoint(x: start.x + drift, y: start.y + rise * 0.5), CGPoint(x: start.x + drift * 0.4, y: start.y + rise)].map { NSValue(point: $0) }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.2, 0.65, 1]
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.6
        grow.toValue = 1.15
        let group = CAAnimationGroup()
        group.animations = [move, fade, grow]
        group.duration = duration
        group.beginTime = CACurrentMediaTime() + delay
        group.timingFunction = curve(.easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { p.removeFromSuperlayer() }
        p.add(group, forKey: "float")
        CATransaction.commit()
    }

    func showBubble(_ text: String, for seconds: Double) {
        guard let layout else { return }
        let font = NSFont.systemFont(ofSize: layout.fontSize, weight: .medium)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let pad = layout.fontSize * 0.75
        let size = CGSize(width: ceil(textSize.width + pad * 2), height: ceil(textSize.height + pad * 0.7))
        let top = layout.rect(pose, mirrored: mirrored).maxY
        still {
            bubble.bounds = CGRect(origin: .zero, size: size)
            bubble.cornerRadius = size.height / 2
            bubble.shadowPath = CGPath(roundedRect: bubble.bounds, cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil)
            bubble.position = CGPoint(x: bounds.width / 2, y: min(bounds.height - size.height - 1, top + 3))
            bubbleText.string = text
            bubbleText.font = font
            bubbleText.fontSize = layout.fontSize
            bubbleText.frame = CGRect(x: 0, y: (size.height - ceil(textSize.height)) / 2, width: size.width, height: ceil(textSize.height))
            bubble.opacity = 1
        }
        bubble.removeAllAnimations()
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.5
        pop.toValue = 1
        pop.mass = 0.6
        pop.stiffness = 220
        pop.damping = 11
        pop.duration = pop.settlingDuration
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = 0.15
        bubble.add(pop, forKey: "pop")
        bubble.add(appear, forKey: "appear")
        bubbleToken += 1
        let token = bubbleToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, token == self.bubbleToken else { return }
            let vanish = CABasicAnimation(keyPath: "opacity")
            vanish.fromValue = 1
            vanish.toValue = 0
            vanish.duration = 0.35
            still { self.bubble.opacity = 0 }
            self.bubble.add(vanish, forKey: "vanish")
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let c = owner else { return }
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        pressPoint = NSEvent.mouseLocation; pressOrigin = c.panel.frame.origin; dragged = false
        c.dragging = true
        c.setWalking(false)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let c = owner else { return }
        let p = NSEvent.mouseLocation
        if !dragged && hypot(p.x - pressPoint.x, p.y - pressPoint.y) > 3 { dragged = true; c.clickTimer?.invalidate(); c.pickedUp(); lift() }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? c.panel.screen ?? NSScreen.main!
        let next = NSPoint(x: pressOrigin.x + p.x - pressPoint.x, y: pressOrigin.y + p.y - pressPoint.y)
        c.panel.setFrameOrigin(clampedOrigin(next, size: c.panel.frame.size, visible: screen.visibleFrame))
    }
    override func mouseUp(with event: NSEvent) {
        guard let c = owner else { return }
        c.dragging = false
        if dragged { drop(); c.save(); c.say("这里也很舒服～") }
        else if event.clickCount >= 2 { c.clickTimer?.invalidate(); c.toggleSleep() }
        else { c.queueGreet() }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let c = owner else { return }
        NSMenu.popUpContextMenu(c.makeMenu(), with: event, for: self)
    }
}

final class PetController: NSObject, NSApplicationDelegate {
    let sprites: Sprites
    let defaults = UserDefaults.standard
    var panel: PetPanel!
    var petView: PetView!
    var statusItem: NSStatusItem!
    var timer: Timer?
    var clickTimer: Timer?
    var walkClock: AnyObject?
    var pose: Pose = .idle {
        didSet {
            petView?.setAccessibilityValue(["坐着", "眨眼", "招手", "睡觉", "打哈欠", "散步"][pose.rawValue])
            guard pose != oldValue else { return }
            if pose == .sleep { nextPuff = CACurrentMediaTime() + 0.8 }
            petView?.show(pose, from: oldValue)
        }
    }
    var poseUntil: TimeInterval = 0
    var nextAction: TimeInterval = 0
    var nextPuff: TimeInterval = 0
    var direction: CGFloat = -1 {
        didSet { if direction != oldValue { petView?.face(right: direction > 0, animated: pose == .walk) } }
    }
    var walkX: CGFloat = 0
    var lastWalkFrame: CFTimeInterval = 0
    var dragging = false
    var sleeping = false
    var roaming = true
    var petSize = PetLayout.defaultHeight
    var ticks = 0

    let renderer: RigRenderer
    let cat: CatMotion
    var lastPurr: TimeInterval = 0
    /// Diagnostics: NAIGREY_DEMO=1 plays a fixed sequence of behaviours instead of random choices.
    let demo = ProcessInfo.processInfo.environment["NAIGREY_DEMO"] != nil
    var launched: TimeInterval = 0
    var demoStep = 0
    /// Diagnostics: NAIGREY_CPULOG=1 prints this process's CPU use every 5 seconds.
    let cpuLog = ProcessInfo.processInfo.environment["NAIGREY_CPULOG"] != nil
    var cpuMark: (wall: TimeInterval, cpu: TimeInterval)?
    /// Whether the cat means to be walking right now; it still pauses on its own to look around.
    var wantsToWalk: Bool { pose == .walk && (roaming || play == .chase) && !sleeping && !dragging }

    /// Which pose the video cat is in. The drawn cat is always a sitting cat, so whenever it is the one on
    /// screen the pose is `.sitting`.
    var posture: Posture = .sitting
    /// Set when an action ends mid-ball-game: the cat stays on its feet on the last frame instead of sitting
    /// down, because chasing the ball is probably the next thing it will do.
    var holdingStand = false

    enum Play { case off, watch, chase, windup, swat }
    var ball: YarnBall?
    var play: Play = .off {
        didSet {
            if demo && play != oldValue, let ball {
                print(String(format: "t=%.1f play %@ -> %@  ball x=%.0f v=%.0f  cat x=%.0f pose %@", CACurrentMediaTime() - launched, "\(oldValue)", "\(play)",
                             ball.center.x, ball.speed, panel.frame.midX, "\(pose)"))
                fflush(stdout)
            }
        }
    }
    var playUntil: TimeInterval = 0
    var swatAt: TimeInterval = 0
    var swatKicked = false
    var playEnergy = 0.0
    var lastPlayTick = CACurrentMediaTime()
    /// Online updates from GitHub.
    let updater = Updater()
    var pendingUpdate: Updater.Release?
    var updateBusy = false
    /// Diagnostics: NAIGREY_UPDATE=check looks for an update straight away; =now also installs it.
    let updateProbe = ProcessInfo.processInfo.environment["NAIGREY_UPDATE"]
    /// Video actions cut from the green-screen clip; nil when the clips are missing, in which case the drawn cat acts alone.
    var library: ClipLibrary?
    var stage: ClipStage?
    var act: String? {
        didSet {
            if demo && act != oldValue {
                print(String(format: "t=%.1f act %@ -> %@  sleeping=%d", CACurrentMediaTime() - launched, oldValue ?? "-", act ?? "-", sleeping ? 1 : 0)); fflush(stdout)
            }
        }
    }
    var actUntil: TimeInterval = .infinity
    var videoWalking = false
    var walkSpeedPoints: CGFloat = 0
    var napUntil: TimeInterval?
    /// Daily rhythm: follows how you use the computer and the time of day.
    var routineOn = true
    var autoSlept = false
    var activeSince = CACurrentMediaTime()
    var lastBreakNudge: TimeInterval = 0
    var yawnedWhileIdle = false
    var ballIsLively: Bool { ball.map { $0.held || !$0.isResting } ?? false || play != .off }

    override init() {
        do {
            sprites = try Sprites(url: Bundle.main.url(forResource: "cats", withExtension: "png")!)
            let rigs = CatRigs.build(sprites)
            renderer = try RigRenderer(sprites: sprites, rigs: rigs)
            cat = CatMotion(rigs: rigs, sprites: sprites)
            rigs.values.forEach { $0.releaseWeights() }
        } catch { fatalError("无法加载猫咪素材: \(error)") }
        super.init()
    }
    func makeLayout() -> PetLayout {
        PetLayout(catHeight: petSize, frameSizes: sprites.frames.map { CGSize(width: $0.width, height: $0.height) })
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.naigrey.desktop-pet").filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty { NSApp.terminate(nil); return }
        // 1.0 stored a much larger window size plus the settings its acceptance run left behind; start 1.1 fresh.
        let upgrading = defaults.object(forKey: "catSize") == nil && defaults.object(forKey: "size") != nil
        let oldWidth = CGFloat(defaults.double(forKey: "size"))
        if upgrading { defaults.removeObject(forKey: "size"); defaults.removeObject(forKey: "roaming") }
        roaming = defaults.object(forKey: "roaming") == nil ? true : defaults.bool(forKey: "roaming")
        routineOn = defaults.object(forKey: "routine") == nil ? true : defaults.bool(forKey: "routine")
        if let directory = Bundle.main.resourceURL?.appendingPathComponent("clips"), let clips = ClipLibrary.load(from: directory) {
            library = clips
            stage = ClipStage(directory: directory)
        }
        let savedSize = CGFloat(defaults.double(forKey: "catSize"))
        petSize = PetLayout.sizes.contains { $0.height == savedSize } ? savedSize : PetLayout.defaultHeight
        let layout = makeLayout()
        panel = PetPanel(contentRect: NSRect(origin: .zero, size: layout.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false; panel.title = "奶灰桌宠"
        petView = PetView(frame: NSRect(origin: .zero, size: layout.size))
        petView.owner = self
        petView.setAccessibilityElement(true)
        petView.setAccessibilityRole(.image)
        petView.setAccessibilityLabel("奶灰桌宠：单击摸摸，双击睡觉，拖动搬家，右键菜单")
        petView.autoresizingMask = [.width, .height]
        panel.contentView = petView
        petView.renderer = renderer
        petView.cat = cat
        petView.apply(layout)
        petView.startClock()
        if let stage, let library { stage.prewarm(library, scale: clipScale) }
        let screen = NSScreen.main!
        var origin = NSPoint(x: screen.visibleFrame.maxX - layout.size.width - 40, y: screen.visibleFrame.minY + 8)
        if defaults.object(forKey: "x") != nil {
            origin = NSPoint(x: defaults.double(forKey: "x"), y: defaults.double(forKey: "y"))
            if upgrading { origin.x += (oldWidth - layout.size.width) / 2 }
        }
        let targetScreen = NSScreen.screens.first(where: { $0.visibleFrame.contains(origin) }) ?? screen
        panel.setFrameOrigin(clampedOrigin(origin, size: panel.frame.size, visible: targetScreen.visibleFrame))
        panel.orderFrontRegardless()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "奶灰桌宠") ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "奶灰桌宠")
        statusItem.button?.toolTip = "奶灰 · 点击管理桌宠"
        refreshMenu()
        launched = CACurrentMediaTime()
        nextAction = demo ? .infinity : launched + 5
        say("你好，我是奶灰 ♡", for: 4)
        if upgrading { save() }
        // Decisions and click-through checks only; motion runs on the view's display-synced frame clock.
        timer = Timer(timeInterval: 1.0 / 20.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        if updateProbe != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startUpdateCheck(manual: true) } }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenChanged), name: NSWorkspace.didWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenLocked), name: .init("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenUnlocked), name: .init("com.apple.screenIsUnlocked"), object: nil)
    }
    func applicationWillTerminate(_ notification: Notification) { save(); timer?.invalidate(); setWalking(false); petView?.stopClock(); ball?.close() }
    func save() {
        defaults.set(Double(petSize), forKey: "catSize"); defaults.set(roaming, forKey: "roaming"); defaults.set(routineOn, forKey: "routine")
        defaults.set(panel.frame.minX, forKey: "x"); defaults.set(panel.frame.minY, forKey: "y")
    }
    @objc func screenChanged() {
        let screen = panel.screen ?? NSScreen.main!
        panel.setFrameOrigin(clampedOrigin(panel.frame.origin, size: panel.frame.size, visible: screen.visibleFrame))
        walkX = panel.frame.minX
    }
    func say(_ text: String, for seconds: Double = 2.5) { petView.showBubble(text, for: seconds) }
    func setPose(_ value: Pose, duration: TimeInterval) {
        pose = value; poseUntil = CACurrentMediaTime() + duration
    }
    @objc func tick() {
        let now = CACurrentMediaTime()
        if demo { runDemo(now - launched) }
        if !dragging {
            if sleeping && act == nil { pose = .sleep }
            else if pose != .idle && !sleeping && now >= poseUntil { pose = .idle; nextAction = now + Double.random(in: 2.5...6) }
            else if pose == .idle && act == nil && !sleeping && now >= nextAction && play == .off {
                // Blinks, glances, twitches and sniffs happen on their own; these are the bigger choices.
                nextAction = now + Double.random(in: 8...16)
                chooseSomethingToDo()
            }
            if act == "walk" && now >= actUntil { settle() }
            if holdingStand && play == .off { settle() }
            if pose == .idle && act == nil && cat.pettingLevel > 0.8 && now - lastPurr > 7 { lastPurr = now; say("呼噜呼噜…", for: 2) }
            if sleeping && now >= nextPuff { petView.puffZ(); nextPuff = now + 1.4 }
            if let napUntil, sleeping, now >= napUntil { self.napUntil = nil; wakeUp(nil) }
        }
        if ticks % 20 == 0 { routineTick(now) }
        if ticks % 200 == 0 { updateTick(now) }
        if let ball { updatePlay(now, ball) }
        setWalking(wantsToWalk || (videoWalking && !dragging))
        // Let the surrounding desktop receive clicks; only the cat's visible pixels are interactive.
        let mouse = NSEvent.mouseLocation
        let local = NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
        let passThrough = !dragging && !hitCat(local)
        if panel.ignoresMouseEvents != passThrough { panel.ignoresMouseEvents = passThrough }
        if let ball {
            let ballThrough = !ball.held && !ball.contains(screenPoint: mouse)
            if ball.panel.ignoresMouseEvents != ballThrough { ball.panel.ignoresMouseEvents = ballThrough }
        }
        ticks += 1
        if ticks % 600 == 0 { save() }
        if cpuLog && ticks % 100 == 0 { logCPU(now) }
    }
    func logCPU(_ now: TimeInterval) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = TimeInterval(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        if let mark = cpuMark {
            let fps = Double(petView.framesDrawn) / (now - mark.wall)
            let ticks = Double(petView.ticksRun) / (now - mark.wall)
            let status = petView.clockStatus() + String(format: " clipFrames/s %.1f worstGap %.0f ms",
                                                        Double(stage?.takeFrameCount() ?? 0) / (now - mark.wall), petView.worstGap * 1000)
            petView.resetFrameCount()
            print("   " + status)
            print(String(format: "cpu %.1f%%  fps %.1f  clock %.1f  pose %@  act %@  rss %.0f MiB", (cpu - mark.cpu) / (now - mark.wall) * 100, fps, ticks, "\(pose)", act ?? "-", Double(usage.ru_maxrss) / 1_048_576))
            fflush(stdout)
        }
        cpuMark = (now, cpu)
    }
    // MARK: Playing with the ball

    func stepBall(_ dt: Double) {
        guard let ball else { return }
        let visible = (panel.screen ?? NSScreen.main!).visibleFrame
        ball.step(dt: CGFloat(dt), floor: panel.frame.minY + PetLayout.ground, walls: visible.minX...visible.maxX)
    }

    func gazeFocus() -> (point: CGPoint, fixated: Bool)? {
        guard let ball, play != .off || ball.held || !ball.isResting else { return nil }
        return (ball.center, play != .off || ball.held)
    }

    @objc func toggleBall() {
        if let ball {
            ball.close(); self.ball = nil; stopPlaying(); refreshMenu(); return
        }
        guard let layout = petView.layout else { return }
        if sleeping { sleeping = false; pose = .idle }
        let visible = (panel.screen ?? NSScreen.main!).visibleFrame
        var side: CGFloat = direction > 0 ? 1 : -1
        if panel.frame.midX + side * layout.size.width < visible.minX + 40 || panel.frame.midX + side * layout.size.width > visible.maxX - 40 { side = -side }
        let b = YarnBall(radius: max(7, layout.catHeight * 0.13),
                         center: CGPoint(x: panel.frame.midX + side * layout.size.width * 0.9, y: panel.frame.minY + layout.catHeight * 1.1))
        b.kick(CGVector(dx: side * 70, dy: 0))
        b.onPlayed = { [weak self] in
            guard let self else { return }
            self.playEnergy = min(1, self.playEnergy + 0.6)
            if self.play == .off && !self.sleeping { self.play = .watch; self.playUntil = CACurrentMediaTime() + 0.4 }
        }
        b.show(above: panel)
        ball = b
        playEnergy = 1; play = .watch; playUntil = CACurrentMediaTime() + 0.9
        say("毛线球！", for: 1.8)
        refreshMenu()
    }

    func stopPlaying() {
        play = .off
        cat.chasing = false
        if act == "walk" || holdingStand { holdingStand = false; settle() }
        if let ball, ball.panel.isVisible == false, act != "play" { ball.held = false; ball.show(above: panel) }
        if pose == .walk || pose == .wave { pose = .idle }
    }

    /// Watch the ball, trot after it, crouch and wiggle, swat it away, and do it again until tired.
    func updatePlay(_ now: TimeInterval, _ ball: YarnBall) {
        if library?["play"] != nil { updateVideoPlay(now, ball); return }
        let dt = now - lastPlayTick
        lastPlayTick = now
        guard play != .off else { return }
        guard !sleeping, !dragging, let layout = petView.layout else { stopPlaying(); return }
        playEnergy = max(0, playEnergy - dt / 50)
        if playEnergy <= 0 { stopPlaying(); say("玩累啦～", for: 2); return }
        let dx = ball.center.x - panel.frame.midX, distance = abs(dx)
        let reach = layout.size.width * 0.3 + ball.radius
        let side: CGFloat = dx >= 0 ? 1 : -1
        switch play {
        case .watch:
            if pose == .walk { cat.chasing = false; pose = .idle }
            guard now >= playUntil, !ball.held else { return }
            if ball.speed < 260 && distance > reach * 1.2 {
                play = .chase; cat.chasing = true; direction = side; setPose(.walk, duration: 60)
            } else if ball.speed < 120 && distance <= reach * 1.2 {
                play = .windup; playUntil = now + Double.random(in: 0.5...0.9); petView.crouch(duration: playUntil - now)
            }
        case .chase:
            direction = side
            if ball.held || ball.speed > 700 {
                cat.chasing = false; pose = .idle; play = .watch; playUntil = now + 0.4
            } else if distance <= reach {
                cat.chasing = false; pose = .idle
                play = .windup; playUntil = now + Double.random(in: 0.45...0.8); petView.crouch(duration: playUntil - now)
            }
        case .windup:
            guard now >= playUntil else { return }
            if distance > reach * 1.4 || ball.speed > 150 || ball.held { play = .watch; playUntil = now + 0.3; return }
            petView.waveMirrored = side > 0
            play = .swat; swatAt = now + 0.2; swatKicked = false
            setPose(.wave, duration: 0.85)
            cat.bat()
        case .swat:
            if !swatKicked && now >= swatAt {
                swatKicked = true
                if distance <= reach * 1.5 && !ball.held {
                    ball.kick(CGVector(dx: side * CGFloat.random(in: 170...380), dy: CGFloat.random(in: 120...320)))
                }
            }
            if now >= swatAt + 0.65 { play = .watch; playUntil = now + Double.random(in: 0.5...1.2) }
        case .off:
            break
        }
    }

    // MARK: Video actions

    /// Where the drawn sitting cat's front paws meet the floor, in screen points.
    func pawAnchor() -> CGPoint {
        guard let layout = petView.layout else { return panel.frame.origin }
        let r = layout.rects[Pose.idle.rawValue]
        // Centre of the white paws in the sitting art, measured the same way as the clips' anchors.
        return CGPoint(x: panel.frame.minX + r.minX + r.width * 0.545, y: panel.frame.minY + PetLayout.ground)
    }

    var clipScale: CGFloat {
        guard let library, let layout = petView.layout else { return 1 }
        return layout.catHeight / CGFloat(library.sitHeight)
    }

    /// Plays a video action in place of the drawn cat. Returns false when the clip isn't available,
    /// so callers can fall back to the drawn cat. `next` runs just before the clip ends and may chain another.
    @discardableResult
    func perform(_ name: String, mirrored: Bool = false, loopFor: Double? = nil, then next: (() -> Void)? = nil) -> Bool {
        guard let library, let stage, let clip = library[name], petView.layout != nil, !dragging else { return false }
        if pose != .idle { pose = .idle }
        let anchor = stage.isPlaying ? (stage.endAnchor ?? pawAnchor()) : pawAnchor()
        act = name
        posture = ClipInfo.posture[name]?.to ?? .sitting
        holdingStand = false
        videoWalking = name == "walk"
        if videoWalking { walkSpeedPoints = CGFloat(clip.speed ?? 0) * clipScale }
        actUntil = clip.loop == true ? CACurrentMediaTime() + (loopFor ?? .infinity) : .infinity
        stage.play(clip, anchor: anchor, scale: clipScale, mirrored: mirrored, above: panel,
                   ready: { [weak self] in
                       guard let self else { return }
                       if self.demo { print(String(format: "t=%.1f clip %@ on screen", CACurrentMediaTime() - self.launched, name)); fflush(stdout) }
                       // Hold the drawn cat until the clip has covered it, then take it away quickly. Fading
                       // the two past each other would let the desktop show through both at once - a flash.
                       DispatchQueue.main.asyncAfter(deadline: .now() + ClipStage.catHold) { [weak self] in
                           guard let self, self.act != nil else { return }
                           self.petView.setCatVisible(false, duration: ClipStage.catOut)
                       }
                   },
                   ending: { [weak self] in self?.actEnding(name, then: next) })
        return true
    }

    /// Plays an action, first playing whatever move gets the cat from the pose it is in now into the one the
    /// action starts from. This is what makes it get up and go instead of jumping straight into a walk.
    @discardableResult
    func begin(_ name: String, mirrored: Bool = false, loopFor: Double? = nil, then next: (() -> Void)? = nil) -> Bool {
        guard let needs = ClipInfo.posture[name]?.from, needs != posture,
              let bridge = ClipInfo.link(posture, needs), bridge != name, library?[bridge] != nil else {
            return perform(name, mirrored: mirrored, loopFor: loopFor, then: next)
        }
        // The link keeps the direction the action will be played in, so the cat turns before it moves.
        return perform(bridge, mirrored: mirrored) { [weak self] in
            self?.begin(name, mirrored: mirrored, loopFor: loopFor, then: next)
        }
    }

    private func actEnding(_ name: String, then next: (() -> Void)?) {
        guard act == name else { return }
        next?()
        if act == name { settle() }
    }

    /// Hands back to the drawn cat once an action is over - but a drawn cat is a *sitting* cat, so anything
    /// else gets the move back to sitting first. Mid-ball-game the cat stays standing instead: it is about to
    /// run after the ball again, and sitting down in between looks like a twitch.
    func settle() {
        guard act != nil else { return }
        if play != .off, posture == .standing { holdingStand = true; return }
        if posture != .sitting, let bridge = ClipInfo.link(posture, .sitting), library?[bridge] != nil {
            _ = perform(bridge, mirrored: stage?.mirrored ?? false)
            return
        }
        endAct()
    }

    /// Brings the drawn cat back where the video cat is standing and fades the clip out.
    func endAct(fade: Double = 0.2) {
        guard let stage, act != nil else { return }
        if let end = stage.endAnchor {
            let visible = (panel.screen ?? NSScreen.main!).visibleFrame
            let target = NSPoint(x: panel.frame.minX + end.x - pawAnchor().x, y: panel.frame.minY)
            panel.setFrameOrigin(clampedOrigin(target, size: panel.frame.size, visible: visible))
            walkX = panel.frame.minX
        }
        // A play clip cut short (picked up, put to sleep) must not leave the real ball hidden.
        if act == "play", let ball, !ball.panel.isVisible { ball.held = false; ball.show(above: panel) }
        act = nil
        videoWalking = false
        posture = .sitting
        holdingStand = false
        if fade > 0 {
            // The drawn cat comes back up underneath the clip that is still covering it; only once it is
            // there does the clip go away, so the picture is never see-through in between.
            petView.setCatVisible(true, duration: ClipStage.uncoverDelay)
            DispatchQueue.main.asyncAfter(deadline: .now() + ClipStage.uncoverDelay) { [weak self] in
                guard let self, self.act == nil else { return }
                self.stage?.stop(fadeOut: fade)
            }
        } else {
            stage.stop(fadeOut: 0)
            petView.setCatVisible(true, duration: 0)
        }
    }

    /// Being picked up interrupts whatever the video cat was doing.
    func pickedUp() {
        if act != nil { endAct(fade: 0.1) }
        if sleeping { sleeping = false; autoSlept = false; napUntil = nil; pose = .idle; refreshMenu() }
    }

    func doYawn() { if !begin("yawn") { _ = cat.yawn() } }
    func doStretch() { if !begin("stretch") { petView.crouch(duration: 0.8) } }
    @objc func stretchNow() { if sleeping { wakeUp(nil) }; if act == nil { doStretch() } }
    @objc func yawnNow() { if sleeping { wakeUp(nil) }; if act == nil { doYawn() } }

    func startWalk(duration: Double, toward x: CGFloat? = nil) {
        direction = x.map { $0 > pawAnchor().x ? 1 : -1 } ?? (Bool.random() ? -1 : 1)
        guard begin("walk", mirrored: direction > 0, loopFor: duration) else {
            setPose(.walk, duration: duration); return
        }
        setWalking(true)
    }

    /// The walking clip faces left; turning around swaps to its mirror image in place.
    func turnVideoWalk() {
        let remaining = max(1, actUntil - CACurrentMediaTime())
        if perform("walk", mirrored: direction > 0, loopFor: remaining) { videoWalking = true }
    }

    func fallAsleep(auto: Bool, nap: Double? = nil) {
        guard !sleeping else { return }
        if play != .off { stopPlaying() }
        sleeping = true
        autoSlept = auto
        napUntil = nap.map { CACurrentMediaTime() + $0 }
        if !begin("lieDown", then: { [weak self] in self?.begin("sleep") }) { pose = .sleep }
        nextPuff = CACurrentMediaTime() + 1.6
        refreshMenu()
    }

    func wakeUp(_ greeting: String?) {
        guard sleeping else { return }
        sleeping = false
        autoSlept = false
        napUntil = nil
        if act == "sleep" || act == "lieDown" {
            if !begin("wake") { endAct() }
        } else {
            pose = .idle
        }
        if let greeting { say(greeting, for: 2.5) }
        nextAction = CACurrentMediaTime() + 6
        activeSince = CACurrentMediaTime()
        refreshMenu()
    }

    func chooseSomethingToDo() {
        // While you're typing, stay put and keep you company instead of doing anything big.
        if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 4 { return }
        let hour = Calendar.current.component(.hour, from: Date())
        let drowsy = (14...15).contains(hour) || hour >= 22 || hour < 6
        let roll = Double.random(in: 0..<1)
        if roll < (drowsy ? 0.16 : 0.07) { doYawn() }
        else if roll < 0.2 { if cat.meow() { say("喵～", for: 1.6) } }
        else if roll < 0.25 { doStretch() }
        else if roll < 0.37 && roaming { startWalk(duration: Double.random(in: 5...10)) }
        else if roll < 0.4 { fallAsleep(auto: false, nap: Double.random(in: 15...30)) }
    }

    // MARK: Daily rhythm

    @objc func toggleRoutine() {
        routineOn.toggle()
        say(routineOn ? "我会跟着你的作息来～" : "好的，我自己玩", for: 2)
        save(); refreshMenu()
    }

    /// Fires a time-of-day rule at most once per day; a "day" runs 6am to 6am so a late night counts as one.
    func once(_ rule: String) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date().addingTimeInterval(-6 * 3600))
        let key = "once." + rule
        guard defaults.string(forKey: key) != day else { return false }
        defaults.set(day, forKey: key)
        return true
    }

    func returnGreeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<11: return "早上好～"
        case 23..., 0..<5: return "这么晚还在呀"
        default: return "你回来啦～"
        }
    }

    /// Once a second: gets drowsy when you step away, wakes when you're back, nudges you to take breaks,
    /// and says hello at the right times of day.
    func routineTick(_ now: TimeInterval) {
        guard routineOn, !dragging, !demo else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let date = Date(), calendar = Calendar.current
        let hour = calendar.component(.hour, from: date), minute = calendar.component(.minute, from: date)
        let late = hour >= 23 || hour < 5
        if idle > 300 { activeSince = now }
        if sleeping {
            if autoSlept && idle < 1.5 { wakeUp(returnGreeting()) }
            return
        }
        guard act == nil, play == .off, pose == .idle else { return }
        if idle < 5 { yawnedWhileIdle = false }
        if idle > (late ? 40 : 90) && !yawnedWhileIdle { yawnedWhileIdle = true; doYawn(); return }
        if idle > (late ? 100 : 240) { fallAsleep(auto: true); return }
        if idle < 30 && now - activeSince > 50 * 60 && now - lastBreakNudge > 25 * 60 {
            lastBreakNudge = now
            doStretch()
            say("用电脑快一小时啦，起来伸个懒腰吧～", for: 4)
            return
        }
        guard idle < 20 else { return }
        if (5..<11).contains(hour) && once("morning") { doStretch(); say("早上好～ 今天也加油！", for: 3) }
        else if (hour == 11 && minute >= 45 || hour == 12) && once("lunch") { greetWith("该吃午饭啦～") }
        else if (18..<20).contains(hour) && once("evening") { greetWith("辛苦啦，今天也很棒～") }
        else if late && once("late") { doYawn(); say("很晚了，早点休息吧", for: 3) }
    }

    private func greetWith(_ text: String) {
        if !perform("wave") { setPose(.wave, duration: 1.8) }
        say(text, for: 3)
    }

    @objc func screenLocked() {
        guard routineOn, !sleeping else { return }
        fallAsleep(auto: true)
    }

    @objc func screenUnlocked() {
        guard autoSlept else { return }
        wakeUp(returnGreeting())
    }

    // MARK: Playing with the ball (video)

    /// Walk over to the ball, then play the batting clip; the video's own ball rolls in, and when it leaves
    /// the frame the real yarn ball takes over from the same spot and speed.
    func updateVideoPlay(_ now: TimeInterval, _ ball: YarnBall) {
        let dt = now - lastPlayTick
        lastPlayTick = now
        guard play != .off else { return }
        guard !sleeping, !dragging, let clip = library?["play"] else { stopPlaying(); return }
        playEnergy = max(0, playEnergy - dt / 60)
        if playEnergy <= 0 && act == nil { stopPlaying(); say("玩累啦～", for: 2); return }
        let paw = pawAnchor()
        let dx = ball.center.x - paw.x
        let side: CGFloat = dx >= 0 ? 1 : -1
        let reach = CGFloat(abs((clip.ballStart?[0] ?? clip.start[0] + 250) - clip.start[0])) * clipScale
        switch play {
        case .watch:
            guard act == nil || holdingStand, now >= playUntil, !ball.held, ball.speed < 90 else { return }
            if abs(abs(dx) - reach) < reach * 0.45 {
                play = .windup; playUntil = now + 0.45; petView.crouch(duration: 0.45)
            } else {
                play = .chase
                startWalk(duration: 30, toward: ball.center.x - side * reach)
            }
        case .chase:
            let goal = ball.center.x - side * reach
            let heading: CGFloat = goal > paw.x ? 1 : -1
            if ball.held || ball.speed > 400 || !(act == "walk" || act == "standUp") {
                if act == "walk" { settle() }
                play = .watch; playUntil = now + 0.5
            } else if abs(goal - paw.x) < reach * 0.25 || heading != direction {
                settle(); play = .watch; playUntil = now + 0.35
            }
        case .windup:
            guard now >= playUntil else { return }
            play = .swat
            ball.held = true
            let started = begin("play", mirrored: side < 0, then: { [weak self] in
                self?.releaseBall()
                self?.begin("getUp", mirrored: side < 0)   // up on its feet, ready to run after the ball
            })
            if started {
                // The cat may have to sit down first, so wait for the clip with the ball in it to really be
                // on screen before taking the real ball away - otherwise it blinks out early.
                hideBallForSwat(ball, until: now + 4)
            } else {
                ball.held = false
                ball.kick(CGVector(dx: side * 260, dy: 200))
                play = .watch; playUntil = now + 1
            }
        case .swat:
            // The swat runs until the cat is back on its feet and idle again.
            guard act == nil || holdingStand else { return }
            // Interrupted before the hand-off (picked up, woken): put the real ball back where it was.
            if !ball.panel.isVisible { ball.held = false; ball.show(above: panel) }
            play = .watch; playUntil = now + Double.random(in: 0.6...1.2)
        case .off:
            break
        }
    }

    /// Swaps the real ball for the one in the video, once that clip is actually the picture on screen.
    private func hideBallForSwat(_ ball: YarnBall, until deadline: TimeInterval) {
        guard play == .swat, CACurrentMediaTime() < deadline else { return }
        guard act == "play" else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.hideBallForSwat(ball, until: deadline) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.act == "play" else { return }
            if self.demo { print(String(format: "t=%.1f 收起真球（视频里的球接手）", CACurrentMediaTime() - self.launched)); fflush(stdout) }
            ball.panel.orderOut(nil)
        }
    }

    private func releaseBall() {
        guard let ball, let stage, let hand = stage.ballHandOff else { return }
        ball.held = false
        ball.drag(to: CGPoint(x: hand.point.x, y: max(hand.point.y, panel.frame.minY + PetLayout.ground + ball.radius)), velocity: .zero)
        // The video's ball leaves the frame half cut off, which under-reads its speed; roll it a few cat-lengths away.
        let away: CGFloat = hand.velocity.dx >= 0 ? 1 : -1
        ball.kick(CGVector(dx: away * max(abs(hand.velocity.dx), CGFloat.random(in: 260...380)), dy: 0))
        ball.show(above: panel)
    }

    func runDemo(_ t: TimeInterval) {
        if ProcessInfo.processInfo.environment["NAIGREY_DEMO"] == "ball" {
            if demoStep == 0 && t >= 1 { demoStep = 1; roaming = false; toggleBall() }
            return
        }
        let script: [(TimeInterval, () -> Void)] = [
            (1.5, { if self.cat.meow() { self.say("喵～", for: 1.6) } }),
            (4.0, { self.doYawn() }),
            (8.0, { self.startWalk(duration: 6) }),
            (16.0, { self.fallAsleep(auto: false) }),
            (24.0, { self.wakeUp("睡醒啦～") }),
            (28.0, { self.greet() }),
            (32.0, { self.doStretch() }),
        ]
        while demoStep < script.count && t >= script[demoStep].0 { script[demoStep].1(); demoStep += 1 }
    }
    /// Walking moves the window once per display refresh, so it glides instead of stepping at the logic rate.
    func setWalking(_ on: Bool) {
        guard on != (walkClock != nil) else { return }
        if on {
            walkX = panel.frame.minX
            lastWalkFrame = CACurrentMediaTime()
            if #available(macOS 14.0, *) {
                let link = petView.displayLink(target: self, selector: #selector(walkFrame(_:)))
                link.add(to: .main, forMode: .common)
                walkClock = link
            } else {
                let clock = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(walkFrame(_:)), userInfo: nil, repeats: true)
                RunLoop.main.add(clock, forMode: .common)
                walkClock = clock
            }
        } else {
            if #available(macOS 14.0, *) { (walkClock as? CADisplayLink)?.invalidate() }
            (walkClock as? Timer)?.invalidate()
            walkClock = nil
        }
    }
    @objc func walkFrame(_ sender: Any?) {
        let now = CACurrentMediaTime()
        let dt = min(0.05, max(0, now - lastWalkFrame)); lastWalkFrame = now
        let visible = (panel.screen ?? NSScreen.main!).visibleFrame
        // Match the paws: planted feet slide back at exactly the speed the window moves forward.
        let speed = videoWalking ? walkSpeedPoints : CGFloat(dt > 0 ? cat.walkSpeed : 0) * (petView.layout?.scale ?? 0)
        let before = panel.frame.minX
        walkX += direction * CGFloat(dt) * speed
        if walkX < visible.minX || walkX + panel.frame.width > visible.maxX {
            walkX = min(max(walkX, visible.minX), visible.maxX - panel.frame.width)
            direction = -direction
            if videoWalking { turnVideoWalk() }
        }
        let scale = panel.backingScaleFactor
        panel.setFrameOrigin(NSPoint(x: (walkX * scale).rounded() / scale, y: panel.frame.minY))
        stage?.shift(dx: panel.frame.minX - before)
    }
    func hitCat(_ p: NSPoint) -> Bool {
        guard let layout = petView.layout else { return false }
        let r = layout.rect(pose, mirrored: petView.mirrored)
        guard r.contains(p) else { return false }
        var u = (p.x - r.minX) / r.width
        if petView.mirrored { u = 1 - u }
        return sprites.isOpaque(pose, u: u, v: 1 - (p.y - r.minY) / r.height)
    }
    func queueGreet() {
        clickTimer?.invalidate()
        clickTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.doubleClickInterval, repeats: false) { [weak self] _ in self?.greet() }
    }
    @objc func greet() {
        if sleeping { wakeUp("睡醒啦～"); return }
        if act == "walk" { endAct(fade: 0.1) }
        guard act == nil else { return }
        if !perform("wave") {
            if pose == .wave { petView.replayWave() }
            setPose(.wave, duration: 1.8)
        }
        say(["喵～ ♡", "摸摸头，好开心", "我陪着你呢", "休息一下吧～"].randomElement()!)
        refreshMenu()
    }
    @objc func toggleSleep() {
        if sleeping { wakeUp("睡醒啦～") } else { fallAsleep(auto: false); say("呼噜… z Z") }
        nextAction = CACurrentMediaTime() + 5
    }
    @objc func toggleRoaming() {
        roaming.toggle(); if pose == .walk { pose = .idle }; if videoWalking { endAct() }
        say(roaming ? "去散个步～" : "乖乖待在这里")
        save(); refreshMenu()
    }
    @objc func walkNow() {
        if sleeping { wakeUp(nil) }
        roaming = true; startWalk(duration: 15)
        say("一起走走～"); save(); refreshMenu()
    }
    @objc func resize(_ sender: NSMenuItem) {
        if act != nil { endAct(fade: 0) }
        let oldMid = panel.frame.midX
        petSize = CGFloat(sender.tag)
        let layout = makeLayout()
        panel.setContentSize(layout.size)
        petView.apply(layout)
        let screen = panel.screen ?? NSScreen.main!
        panel.setFrameOrigin(clampedOrigin(NSPoint(x: oldMid - layout.size.width / 2, y: panel.frame.minY), size: panel.frame.size, visible: screen.visibleFrame))
        walkX = panel.frame.minX
        // The warmed-up clips were prepared for the old size; get the new size ready too.
        if let stage, let library { stage.prewarm(library, scale: clipScale) }
        save(); refreshMenu()
    }
    @objc func bringBack() {
        if act != nil { endAct(fade: 0) }
        let screen = NSScreen.main!
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2, y: screen.visibleFrame.minY + 8))
        walkX = panel.frame.minX
        panel.orderFrontRegardless(); save(); greet()
    }
    @objc func quit() { NSApp.terminate(nil) }
    // MARK: Staying up to date

    /// Looks for a new build at most once a day, quietly. Nothing is downloaded until you say so.
    func updateTick(_ now: TimeInterval) {
        guard !demo, updateProbe == nil, !updateBusy, pendingUpdate == nil, now - launched > 30 else { return }
        guard Date().timeIntervalSince1970 - defaults.double(forKey: "lastUpdateCheck") > 24 * 3600 else { return }
        startUpdateCheck(manual: false)
    }

    @objc func checkForUpdates() { startUpdateCheck(manual: true) }

    func startUpdateCheck(manual: Bool) {
        guard !updateBusy else { return }
        updateBusy = true
        if manual { say("我看看有没有新衣服…", for: 2) }
        refreshMenu()
        updater.check { [weak self] result in
            guard let self else { return }
            self.updateBusy = false
            self.defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            switch result {
            case .success(let release):
                self.pendingUpdate = release
                if let release {
                    NSLog("奶灰: 发现新版本 %@（build %d）", release.version, release.build)
                    self.offerUpdate(release, manual: manual)
                } else if manual {
                    self.say("已经是最新的啦（\(Updater.currentVersion)）", for: 3)
                }
            case .failure(let error):
                NSLog("奶灰: 检查更新失败 %@", error.localizedDescription)
                if manual { self.say("没连上更新服务器…", for: 3) }
            }
            self.refreshMenu()
        }
    }

    /// A check you asked for gets a dialog; one the cat did on its own just gets a word from the cat.
    func offerUpdate(_ release: Updater.Release, manual: Bool) {
        if updateProbe == "now" { installUpdate(); return }
        guard manual, updateProbe == nil else {
            say("有新衣服啦～ \(release.version)，菜单里点一下就换", for: 6)
            return
        }
        let alert = NSAlert()
        alert.messageText = "奶灰有新版本 \(release.version)"
        var text = "现在是 \(Updater.currentVersion)，更新后奶灰会自己重启，位置和设置都还在。"
        if let notes = release.notes, !notes.isEmpty { text = notes + "\n\n" + text }
        alert.informativeText = text
        alert.addButton(withTitle: "现在更新")
        alert.addButton(withTitle: "以后再说")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { installUpdate() }
    }

    @objc func installUpdate() {
        guard let release = pendingUpdate, !updateBusy else { return }
        updateBusy = true
        refreshMenu()
        if act != nil { endAct(fade: 0) }
        say("我去换件新衣服，马上回来～", for: 8)
        updater.install(release) { [weak self] result in
            guard let self else { return }
            self.updateBusy = false
            switch result {
            case .success(let app):
                self.save()
                Updater.relaunch(app)
                NSApp.terminate(nil)
            case .failure(let error):
                NSLog("奶灰: 更新失败 %@", error.localizedDescription)
                self.say("更新没成功，等会儿再试～", for: 4)
                if self.updateProbe == nil {
                    let alert = NSAlert()
                    alert.messageText = "更新没能完成"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "打开下载页")
                    alert.addButton(withTitle: "好")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Updater.releasesPage) }
                }
                self.refreshMenu()
            }
        }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem(title: "奶灰 · 你的桌面小伙伴", action: nil, keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
        menu.addItem(.separator())
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item); return item
        }
        _ = add("摸摸 / 打招呼", #selector(greet))
        _ = add(sleeping ? "叫醒奶灰" : "让奶灰睡觉", #selector(toggleSleep))
        _ = add("现在散步", #selector(walkNow))
        if library != nil { _ = add("伸个懒腰", #selector(stretchNow)); _ = add("打个哈欠", #selector(yawnNow)) }
        _ = add(ball == nil ? "丢个毛线球" : "收起毛线球", #selector(toggleBall))
        let roam = add("自动散步", #selector(toggleRoaming)); roam.state = roaming ? .on : .off
        let rhythm = add("跟着我的作息", #selector(toggleRoutine)); rhythm.state = routineOn ? .on : .off
        let sizes = NSMenuItem(title: "猫咪大小", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (name, size) in PetLayout.sizes {
            let item = NSMenuItem(title: name, action: #selector(resize(_:)), keyEquivalent: ""); item.target = self; item.tag = Int(size)
            item.state = petSize == size ? .on : .off; submenu.addItem(item)
        }
        sizes.submenu = submenu; menu.addItem(sizes)
        _ = add("把奶灰叫回来", #selector(bringBack))
        menu.addItem(.separator())
        if updateBusy {
            let busy = NSMenuItem(title: pendingUpdate == nil ? "正在检查更新…" : "正在更新…", action: nil, keyEquivalent: "")
            busy.isEnabled = false; menu.addItem(busy)
        } else if let pending = pendingUpdate {
            _ = add("换上新衣服 · \(pending.version)", #selector(installUpdate))
        } else {
            _ = add("检查更新…", #selector(checkForUpdates))
        }
        let help = NSMenuItem(title: "单击招手 · 双击睡觉 · 拖动搬家 · 头上划一划是撸猫", action: nil, keyEquivalent: ""); help.isEnabled = false; menu.addItem(help)
        _ = add("退出奶灰", #selector(quit))
        return menu
    }
    func refreshMenu() { statusItem?.menu = makeMenu() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = PetController()
app.delegate = controller
app.run()
