import AppKit
import QuartzCore

/// A ball of yarn with simple physics, living in its own small transparent window so it can roll
/// anywhere along the floor the cat stands on. You can drag and fling it, or click to nudge it.
final class YarnBall: NSObject {
    let panel: PetPanel
    let view: YarnBallView
    let radius: CGFloat
    /// Centre in screen coordinates.
    private(set) var center: CGPoint
    private(set) var velocity = CGVector.zero
    private var spin: CGFloat = 0
    var held = false
    /// Called when the user throws or nudges the ball, so the cat can get excited about it.
    var onPlayed: (() -> Void)?

    static let gravity: CGFloat = 1500, rollingFriction: CGFloat = 240, bounce: CGFloat = 0.42

    init(radius: CGFloat, center: CGPoint) {
        self.radius = radius
        self.center = center
        let side = ceil(radius * 2 + 6)
        panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view = YarnBallView(frame: NSRect(x: 0, y: 0, width: side, height: side), radius: radius)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        view.ball = self
        place()
    }

    var speed: CGFloat { hypot(velocity.dx, velocity.dy) }
    var isResting: Bool { speed < 1 && !held }

    func show(above catWindow: NSWindow) { panel.order(.above, relativeTo: catWindow.windowNumber) }
    func close() { panel.orderOut(nil); panel.close() }

    func kick(_ v: CGVector) { velocity = v; held = false }

    /// Advances the ball; `floor` is the screen y the cat's paws stand on.
    func step(dt: CGFloat, floor: CGFloat, walls: ClosedRange<CGFloat>) {
        guard !held else { return }
        let ground = floor + radius
        let airborne = center.y > ground + 0.5 || velocity.dy > 0
        if !airborne && speed < 1 && abs(center.y - ground) < 0.5 { return }
        if airborne { velocity.dy -= YarnBall.gravity * dt }
        center.x += velocity.dx * dt
        center.y += velocity.dy * dt
        if center.y <= ground {
            center.y = ground
            velocity.dy = velocity.dy < -90 ? -velocity.dy * YarnBall.bounce : 0
            velocity.dx *= 0.96
        }
        if center.y <= ground + 0.5 && velocity.dy == 0 {
            let slow = min(abs(velocity.dx), YarnBall.rollingFriction * dt)
            velocity.dx -= velocity.dx > 0 ? slow : -slow
        }
        if center.x - radius < walls.lowerBound { center.x = walls.lowerBound + radius; velocity.dx = abs(velocity.dx) * 0.6 }
        if center.x + radius > walls.upperBound { center.x = walls.upperBound - radius; velocity.dx = -abs(velocity.dx) * 0.6 }
        // Rolling without slipping: the yarn turns by the distance travelled over its radius.
        spin -= velocity.dx * dt / radius
        place()
    }

    /// Moves the ball with the pointer while it is being dragged.
    func drag(to point: CGPoint, velocity v: CGVector) {
        center = point
        velocity = v
        place()
    }

    private func place() {
        let side = panel.frame.width
        let scale = panel.backingScaleFactor > 0 ? panel.backingScaleFactor : 2
        let origin = NSPoint(x: ((center.x - side / 2) * scale).rounded() / scale, y: ((center.y - side / 2) * scale).rounded() / scale)
        panel.setFrameOrigin(origin)
        view.setSpin(spin)
    }

    func contains(screenPoint p: CGPoint) -> Bool { hypot(p.x - center.x, p.y - center.y) <= radius + 2 }
}

final class YarnBallView: NSView {
    weak var ball: YarnBall?
    private let yarn = CALayer()
    private let radius: CGFloat
    private var trail: [(point: CGPoint, time: Double)] = []
    private var grabOffset = CGVector.zero
    private var moved = false

    init(frame: NSRect, radius: CGFloat) {
        self.radius = radius
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer!.backgroundColor = NSColor.clear.cgColor
        yarn.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        yarn.position = CGPoint(x: frame.width / 2, y: frame.height / 2)
        yarn.actions = ["transform": NSNull(), "contents": NSNull()]
        layer!.addSublayer(yarn)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("毛线球：拖动可以甩出去，点一下拨动它")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); redraw() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); redraw() }
    private func redraw() {
        let scale = window?.backingScaleFactor ?? 2
        yarn.contentsScale = scale
        yarn.contents = YarnBallView.drawYarn(radius: radius, scale: scale)
    }

    func setSpin(_ angle: CGFloat) { yarn.transform = CATransform3DMakeRotation(angle, 0, 0, 1) }

    /// Soft pink yarn: a shaded sphere wrapped in a few strands, with one loose end.
    static func drawYarn(radius: CGFloat, scale: CGFloat) -> CGImage? {
        let px = Int(ceil(radius * 2 * scale))
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let r = radius, c = CGPoint(x: r, y: r)
        let body = CGRect(x: 0.6, y: 0.6, width: r * 2 - 1.2, height: r * 2 - 1.2)
        ctx.saveGState()
        ctx.addEllipse(in: body); ctx.clip()
        let colors = [CGColor(srgbRed: 1, green: 0.8, blue: 0.84, alpha: 1), CGColor(srgbRed: 0.93, green: 0.55, blue: 0.64, alpha: 1),
                      CGColor(srgbRed: 0.78, green: 0.4, blue: 0.5, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.6, 1])!
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: r * 0.7, y: r * 1.35), startRadius: 0, endCenter: c, endRadius: r * 1.05, options: [.drawsAfterEndLocation])
        // Wraps of yarn: arcs of strands at a few angles, lighter on top of each band.
        ctx.setLineCap(.round)
        for (i, angle) in [0.15, 0.95, 1.75, 2.45].enumerated() {
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y); ctx.rotate(by: CGFloat(angle))
            for k in 0..<4 {
                let inset = CGFloat(k) * r * 0.16 - r * 0.2
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.88 - 0.05 * CGFloat(i), blue: 0.9, alpha: 0.55 - 0.08 * CGFloat(k)))
                ctx.setLineWidth(max(0.6, r * 0.07))
                ctx.addEllipse(in: CGRect(x: -r * 1.02, y: -r * 0.42 + inset, width: r * 2.04, height: r * 0.84))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()
        // Rim shading so it reads as round on light and dark desktops.
        ctx.setStrokeColor(CGColor(srgbRed: 0.62, green: 0.3, blue: 0.4, alpha: 0.35))
        ctx.setLineWidth(max(0.6, r * 0.05))
        ctx.strokeEllipse(in: body)
        return ctx.makeImage()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let ball else { return }
        let p = NSEvent.mouseLocation
        grabOffset = CGVector(dx: ball.center.x - p.x, dy: ball.center.y - p.y)
        trail = [(p, CACurrentMediaTime())]
        moved = false
        ball.held = true
        ball.drag(to: ball.center, velocity: .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let ball else { return }
        let p = NSEvent.mouseLocation, now = CACurrentMediaTime()
        trail.append((p, now))
        trail.removeAll { now - $0.time > 0.1 }
        if hypot(p.x - trail[0].point.x, p.y - trail[0].point.y) > 2 { moved = true }
        ball.drag(to: CGPoint(x: p.x + grabOffset.dx, y: p.y + grabOffset.dy), velocity: .zero)
    }

    override func mouseUp(with event: NSEvent) {
        guard let ball else { return }
        ball.held = false
        let p = NSEvent.mouseLocation
        if moved, let first = trail.first, CACurrentMediaTime() - first.time > 0.001 {
            // Fling with the pointer's speed over the last tenth of a second.
            let dt = CGFloat(CACurrentMediaTime() - first.time)
            let v = CGVector(dx: (p.x - first.point.x) / dt, dy: (p.y - first.point.y) / dt)
            let limit: CGFloat = 1400, s = hypot(v.dx, v.dy)
            ball.kick(s > limit ? CGVector(dx: v.dx / s * limit, dy: v.dy / s * limit) : v)
        } else {
            // A click nudges it away from where it was touched.
            let side: CGFloat = p.x < ball.center.x ? 1 : -1
            ball.kick(CGVector(dx: side * CGFloat.random(in: 140...220), dy: CGFloat.random(in: 180...280)))
        }
        ball.onPlayed?()
    }
}
