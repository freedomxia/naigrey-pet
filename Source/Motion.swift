import CoreGraphics
import Foundation

/// What the cat can perceive this frame, in the current pose's canvas pixels (y down).
struct CatSenses {
    var pointer: CGPoint?
    /// Canvas pixels per second, smoothed.
    var pointerSpeed: CGFloat = 0
    var pointerOverHead = false
    var held = false
    /// Keep attention on the target even while it is still (a ball the cat is playing with).
    var fixated = false
}

/// Deterministic when seeded, so preview renders are repeatable.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Critically damped spring: responds quickly, never overshoots, and lags the way attention does.
final class Follow {
    private(set) var value: Double
    private var velocity = 0.0
    let omega: Double
    init(_ omega: Double, _ value: Double = 0) { self.omega = omega; self.value = value }
    @discardableResult func step(_ target: Double, _ dt: Double) -> Double {
        let steps = 4, h = dt / Double(steps)
        for _ in 0..<steps {
            velocity += (omega * omega * (target - value) - 2 * omega * velocity) * h
            value += velocity * h
        }
        return value
    }
}

func ease(_ x: Double) -> Double { let c = min(1, max(0, x)); return 0.5 - 0.5 * cos(.pi * c) }

/// 0 before `start`, eases up over `rise`, holds, then eases down over `fall` after `end`.
func window(_ t: Double, _ start: Double, _ rise: Double, _ end: Double, _ fall: Double) -> Double {
    ease((t - start) / rise) * (1 - ease((t - end) / fall))
}

/// Eased interpolation through (time, value) pairs; repeated values make holds.
func keys(_ t: Double, _ frames: [(Double, Double)]) -> Double {
    guard let first = frames.first, t > first.0 else { return frames.first?.1 ?? 0 }
    for (a, b) in zip(frames, frames.dropFirst()) where t <= b.0 {
        return a.1 + (b.1 - a.1) * ease((t - a.0) / (b.0 - a.0))
    }
    return frames.last!.1
}

/// A quick twitch that overshoots and settles like a spring.
func flick(_ t: Double, at: Double, amp: Double, freq: Double = 6.5, decay: Double = 0.13) -> Double {
    guard t >= at else { return 0 }
    let s = t - at
    return amp * exp(-s / decay) * sin(2 * .pi * freq * s) * min(1, s / 0.02)
}

/// The cat's behaviour and body mechanics. It decides the small, involuntary things (blinks, glances,
/// ear and tail twitches, breathing, sniffing, sighs, pauses on walks) and turns everything into
/// per-part motion for the renderer. Big decisions (walk, nap, wave) stay with the controller.
final class CatMotion {
    /// Four-beat walk: hind leg, then the front leg on the same side, then the other side.
    static let stance = 0.6
    static let legPhase: [String: Double] = ["backNear": 0, "frontNear": 0.25, "backFar": 0.5, "frontFar": 0.75]

    private(set) var time = 0.0
    private var rng: SplitMix64
    private let rest: [String: [Float]]
    private let rigs: [String: PoseRig]
    private let mouthSizes: (wave: CGSize, yawn: CGSize)
    private let blinkSize: CGSize
    private var pose: Pose = .idle
    private var poseSince = 0.0

    // Attention
    private let eyeX = Follow(38), eyeY = Follow(38)
    private let headTilt = Follow(7), headX = Follow(7), headY = Follow(7)
    private let interest = Follow(3), petting = Follow(4), squint = Follow(9), heldness = Follow(6)
    private var lastPointerMove = -100.0, lastPet = -100.0
    private var glance = (x: 0.0, y: 0.0), nextGlance = 1.5
    private var jitter = (x: 0.0, y: 0.0), nextJitter = 0.0
    private var wasInterested = false

    // Blinks and expressions
    private var blinkAt = -100.0, blinkShut = 0.06, nextBlink = 1.8, doubleBlinkAt: Double?
    private(set) var meowAt = -100.0
    private(set) var yawnAt = -100.0
    private var sniffAt = -100.0, sighAt = -100.0, slowBlinkAt = -100.0
    private var nextSlowBlink = 20.0, nextIdleSniff = 14.0

    // Twitches
    private var earFlicks: [(at: Double, ear: Int, amp: Double)] = []
    private var tipFlicks: [Double] = []
    private var swishAt = -100.0
    private var nextEarFlick = 3.0, nextTip = 0.0, nextSwish = 9.0, nextDream = 9.0
    private var dreamAt = -100.0

    // Breathing
    private var breathPhase = 0.0, sleepPhase = 0.0, exertion = 0.0

    // Walking
    private(set) var gait = 0.0
    private let speed = Follow(4.5)
    private let hurry = Follow(3)
    /// Set while chasing something: a quicker, longer stride and no stopping to look around.
    var chasing = false
    private var pauseStart = -100.0, pauseEnd = -100.0, nextPause = 5.0
    private var walkRise = 0.0, walkPitch = 0.0, walkBreath = 0.0, walkLook = 0.0

    init(rigs: [String: PoseRig], sprites: Sprites, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        self.rigs = rigs
        rng = SplitMix64(seed: seed)
        self.rest = rigs.mapValues { $0.restParams(frame: $0.base) }
        mouthSizes = (CGSize(width: sprites[.wave].width, height: sprites[.wave].height),
                      CGSize(width: sprites[.yawn].width, height: sprites[.yawn].height))
        blinkSize = CGSize(width: sprites[.blink].width, height: sprites[.blink].height)
    }

    private func random(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &rng) }
    private func chance(_ p: Double) -> Bool { random(0...1) < p }

    var isWalkingSpeed: Double { speed.value }
    /// Seconds per full stride and how far a planted paw travels during it, in canvas pixels.
    var cycle: Double { 0.9 - 0.42 * hurry.value }
    var stepLength: Double { 40 + 16 * hurry.value }
    /// How fast the window should move, in canvas pixels per second, so planted paws don't slide.
    var walkSpeed: Double { stepLength / (CatMotion.stance * cycle) * speed.value }
    var pettingLevel: Double { petting.value }
    var isBusy: Bool { time - yawnAt < 2.8 || time - meowAt < 0.8 }

    /// Quick movements (blinks, twitches, walking, reacting to the mouse) need 60 fps; slow breathing and
    /// tail sway look the same at 30 fps for half the work.
    var needsFullFrameRate: Bool {
        let t = time
        return pose == .walk || pose == .wave || speed.value > 0.01 || interest.value > 0.03 || petting.value > 0.03
            || heldness.value > 0.03 || isBusy || t - blinkAt < 0.3 || doubleBlinkAt != nil || t - sniffAt < 1
            || t - swishAt < 1 || t - slowBlinkAt < 2 || t - sighAt < 2.2 || t - dreamAt < 0.8 || t - poseSince < 1.5
            || earFlicks.contains { t - $0.at < 0.7 } || tipFlicks.contains { t - $0 < 0.7 }
    }

    // MARK: Requests

    @discardableResult func meow() -> Bool {
        guard pose == .idle, !isBusy else { return false }
        meowAt = time; return true
    }

    @discardableResult func yawn() -> Bool {
        guard pose == .idle, !isBusy, interest.value < 0.3 else { return false }
        yawnAt = time; return true
    }

    func sniff() { if time - sniffAt > 1.5 { sniffAt = time } }

    func sigh() { if pose == .idle && time - sighAt > 4 { sighAt = time } }

    private var batAt = -100.0
    /// A swat with the raised paw (used from the waving pose while playing).
    func bat() { batAt = time }

    // MARK: Simulation

    func update(dt: Double, pose newPose: Pose, walking: Bool, senses: CatSenses) {
        time += dt
        let t = time
        if newPose != pose {
            if newPose == .walk { nextPause = t + random(3.5...6.5); gait = 0 }
            if pose == .walk { exertion = 1 }
            pose = newPose; poseSince = t
        }

        // Interest: something moving nearby catches the eye; it fades once things go quiet.
        let head = pose == .walk ? CGPoint(x: 180, y: 190) : CGPoint(x: 325, y: 230)
        if let p = senses.pointer, senses.pointerSpeed > 25, hypot(p.x - head.x, p.y - head.y) < 1100, !senses.held {
            lastPointerMove = t
        }
        let noticing = t - lastPointerMove < 2.6 || senses.fixated
        interest.step(noticing ? 1 : 0, dt)
        if wasInterested && interest.value < 0.2 {
            wasInterested = false
            if chance(0.5) && t - sighAt > 15 && pose == .idle { sighAt = t }
        }
        if interest.value > 0.7 { wasInterested = true }
        if senses.pointerOverHead && senses.pointerSpeed > 12 && pose == .idle && !senses.held { lastPet = t }
        petting.step(t - lastPet < 0.45 ? 1 : 0, dt)
        heldness.step(senses.held ? 1 : 0, dt)
        exertion = max(0, exertion - dt / 20)

        // Where to look.
        if t >= nextGlance {
            glance = chance(0.45) ? (0, 0) : (random(-3.6...3.6), random(-1.6...1.4))
            nextGlance = t + random(1.2...4.5)
            if t - blinkAt > 1.2 && chance(0.4) { blink(t) }  // gaze shifts often come with a blink
        }
        if t >= nextJitter { jitter = (random(-0.35...0.35), random(-0.25...0.25)); nextJitter = t + random(0.25...0.7) }
        var ex = glance.x, ey = glance.y, tilt = glance.x * 0.6, hx = 0.0, hy = 0.0
        if let p = senses.pointer, interest.value > 0.02 {
            let dx = Double(p.x - head.x), dy = Double(p.y - head.y), k = interest.value
            ex += (4.6 * tanh(dx / 140) - ex) * k
            ey += (3.2 * tanh(dy / 140) - ey) * k
            tilt += (5.5 * tanh(dx / 220) - tilt) * k
            hx = 5 * tanh(dx / 220) * k
            hy = 4 * tanh(dy / 220) * k
        }
        let pet = petting.value
        tilt += 4 * pet * sin(2 * .pi * t / 1.6)
        eyeX.step(ex, dt); eyeY.step(ey, dt)
        headTilt.step(tilt, dt); headX.step(hx, dt); headY.step(hy, dt)

        // Blinks, slow affectionate blinks, and squinting while being stroked.
        if t >= nextBlink { blink(t) }
        if let second = doubleBlinkAt, t >= second { doubleBlinkAt = nil; blinkAt = t; blinkShut = 0.05 }
        if t >= nextSlowBlink {
            if interest.value < 0.2 && pose == .idle { slowBlinkAt = t }
            nextSlowBlink = t + random(14...32)
        }
        squint.step(0.55 * pet, dt)

        // Ears, tail, sniffing.
        if t >= nextEarFlick {
            earFlicks.append((t, Int.random(in: 0...1, using: &rng), random(8...14) * (chance(0.5) ? 1 : -1)))
            if chance(0.25) { earFlicks.append((t + random(0.18...0.3), Int.random(in: 0...1, using: &rng), random(6...10))) }
            nextEarFlick = t + random(pose == .sleep ? 5...14 : 2.5...8)
        }
        earFlicks.removeAll { t - $0.at > 1.5 }
        if interest.value > 0.5 && t >= nextTip { tipFlicks.append(t); nextTip = t + random(0.6...1.6) }
        tipFlicks.removeAll { t - $0 > 1.5 }
        if t >= nextSwish { swishAt = t; nextSwish = t + random(8...20) }
        if let p = senses.pointer, pose == .idle, interest.value > 0.4, senses.pointerSpeed < 40,
           hypot(p.x - 318, p.y - 265) < 150, t - sniffAt > 3.5 { sniffAt = t }
        if t >= nextIdleSniff { if interest.value < 0.2 && pose == .idle && !isBusy { sniffAt = t }; nextIdleSniff = t + random(15...40) }
        if pose == .sleep && t >= nextDream { dreamAt = t; nextDream = t + random(9...24) }

        // Breathing speeds up with excitement or after a walk.
        let rate = 3.1 - 0.8 * interest.value - 0.9 * exertion
        breathPhase += dt / rate
        sleepPhase += dt / 3.8

        // Walking pace, with pauses to look around.
        var wantSpeed = walking && pose == .walk ? 1.0 : 0.0
        hurry.step(chasing ? 1 : 0, dt)
        if walking && pose == .walk && !chasing {
            if t >= nextPause && t > pauseEnd {
                pauseStart = t; pauseEnd = t + random(1.9...3.4); nextPause = pauseEnd + random(3.5...8)
            }
            if t < pauseEnd { wantSpeed = 0 }
        }
        speed.step(wantSpeed, dt)
        gait += dt * speed.value / cycle

        // Whole-body motion shared by the walking body and its legs.
        let v = speed.value, g = gait
        walkLook = window(t, pauseStart + 0.55, 0.3, pauseEnd - 0.75, 0.35) * (pauseEnd - pauseStart > 1.5 ? 1 : 0)
        walkRise = 1.8 * v * (0.5 - 0.5 * cos(4 * .pi * (g - 0.1)))
        walkPitch = 0.6 * v * sin(2 * .pi * (g - 0.3)) + 1.4 * window(t, pauseStart + 0.35, 0.15, pauseStart + 0.5, 0.35)
            - 1.2 * window(t, pauseEnd - 0.4, 0.25, pauseEnd - 0.15, 0.2)
        walkBreath = 0.012 * (1 - v) * breath(breathPhase)
    }

    private func blink(_ t: Double) {
        blinkAt = t; blinkShut = random(0.04...0.08)
        nextBlink = t + random(2.2...6.5)
        if chance(0.2) { doubleBlinkAt = t + random(0.28...0.4) }
    }

    private func blinkAmount(_ t: Double) -> Double {
        let s = t - blinkAt, close = 0.04, open = 0.08
        if s < 0 || s > close + blinkShut + open { return 0 }
        if s < close { return ease(s / close) }
        if s < close + blinkShut { return 1 }
        return 1 - ease((s - close - blinkShut) / open)
    }

    // MARK: Parameters

    private func setBend(_ p: inout [Float], _ rig: PoseRig, _ name: String, lag: Double = 0, _ degrees: (Double) -> Double) {
        guard let info = rig.bendSlots[name] else { return }
        let o = RigParams.bendBase + info.slot * RigParams.bendStride
        if info.along {
            for k in 0..<RigParams.angleSamples {
                p[o + 4 + k] = Float(degrees(time - lag * Double(k) / Double(RigParams.angleSamples - 1)) * .pi / 180)
            }
        } else {
            p[o + 4] = Float(degrees(time) * .pi / 180)
        }
    }

    /// Moves a part's content by (dx, dy) canvas pixels (y down).
    private func move(_ p: inout [Float], _ rig: PoseRig, _ name: String, _ dx: Double, _ dy: Double) {
        guard let slot = rig.shiftSlots[name] else { return }
        let o = RigParams.shiftBase + slot * RigParams.shiftStride
        p[o + 1] = Float(-dx); p[o + 2] = Float(-dy)
    }

    private func setScale(_ p: inout [Float], _ rig: PoseRig, _ name: String, center: CGPoint, _ kx: Double, _ ky: Double) {
        guard let slot = rig.scaleSlots[name] else { return }
        let o = RigParams.scaleBase + slot * RigParams.scaleStride
        p[o + 1] = Float(center.x); p[o + 2] = Float(center.y); p[o + 3] = Float(kx); p[o + 4] = Float(ky)
    }

    private func setBody(_ p: inout [Float], rotateAbout pivot: CGPoint, degrees: Double, scaleAbout ground: CGPoint, _ sx: Double, _ sy: Double, lift: Double = 0) {
        p[RigParams.rotatePivotX] = Float(pivot.x); p[RigParams.rotatePivotY] = Float(pivot.y)
        p[RigParams.angle] = Float(degrees * .pi / 180)
        p[RigParams.scalePivotX] = Float(ground.x); p[RigParams.scalePivotY] = Float(ground.y)
        p[RigParams.scaleX] = Float(sx); p[RigParams.scaleY] = Float(sy)
        p[RigParams.shiftY] = Float(-lift)
    }

    private func setLids(_ p: inout [Float], closure c: Double, strength: Double = 0.45, swap: Bool = true) {
        guard c > 0.001 else { return }
        p[RigParams.lidGrow] = Float(1 / (1 - strength * min(1, c / 0.6)) - 1)
        if swap { p[RigParams.blinkSwap] = Float(ease((c - 0.6) / 0.35)) }
    }

    private func breath(_ phase: Double) -> Double {
        let q = phase.truncatingRemainder(dividingBy: 1)
        return q < 0.38 ? ease(q / 0.38) : 1 - ease((q - 0.38) / 0.5)
    }

    func params(for layer: String, opacity: Double) -> [Float] {
        guard let rig = rigs[layer], var p = rest[layer] else { return [] }
        p[RigParams.opacity] = Float(opacity)
        switch layer {
        case "walk": walking(&p, rig)
        case _ where layer.hasPrefix("walk."): walkingLeg(&p, rig, String(layer.dropFirst(5)))
        case "sleep": sleeping(&p, rig)
        case "wave": waving(&p, rig)
        default: sitting(&p, rig)
        }
        return p
    }

    private func sitting(_ p: inout [Float], _ rig: PoseRig) {
        let t = time, pad = Double(rigPad)
        let k = interest.value, pet = petting.value, held = heldness.value
        let meow = window(t, meowAt, 0.08, meowAt + 0.4, 0.14)
        // Yawn: head tips back, eyes screw up, the mouth opens wide, holds, closes, then a blink.
        let y = t - yawnAt
        let yawning = y >= 0 && y < 2.8
        let yawnOpen = yawning ? keys(y, [(0, 0), (0.55, 0.3), (1.35, 1), (1.85, 0.95), (2.35, 0), (2.8, 0)]) : 0
        let yawnHead = yawning ? keys(y, [(0, 0), (0.7, 1), (1.9, 1), (2.5, 0), (2.8, 0)]) : 0
        let yawnEyes = yawning ? keys(y, [(0, 0), (0.5, 0.45), (1.3, 0.62), (1.95, 0.62), (2.3, 0.2), (2.45, 1), (2.6, 0), (2.8, 0)]) : 0
        let sigh = window(t, sighAt, 0.7, sighAt + 0.3, 0.9)
        let slow = window(t, slowBlinkAt, 0.4, slowBlinkAt + 0.9, 0.45)

        let b = breath(breathPhase)
        let lift = 0.014 * b + 0.035 * sigh + 0.02 * yawnHead
        let ground = CGPoint(x: 280 + pad, y: 463 + pad)
        setBody(&p, rotateAbout: ground, degrees: 0.5 * sin(2 * .pi * t / 7.3), scaleAbout: ground, 1 + 0.36 * lift, 1 + lift)

        let swish = swishAt, tips = tipFlicks
        setBend(&p, rig, "tail", lag: 0.32) { u in
            (4 - 2.5 * k + 4 * pet + 3 * held) * sin(2 * .pi * u / 3.7) + 1.5 * sin(2 * .pi * u / 1.7 + 1)
                + 14 * sin(.pi * min(1, max(0, (u - swish) / 0.7)))
        }
        setBend(&p, rig, "tip", lag: 0.08) { u in tips.reduce(0) { $0 + flick(u, at: $1, amp: 16, freq: 5, decay: 0.12) } }
        setBend(&p, rig, "head") { _ in self.headTilt.value - 2.5 * yawnHead }
        move(&p, rig, "head", headX.value, headY.value - 5 * meow - 7 * yawnHead - 3 * sigh + 0.6 * yawnHead * sin(2 * .pi * 9 * t))
        let ears = earFlicks
        let back = 5 * meow + 10 * yawnHead + 6 * pet + 8 * held
        setBend(&p, rig, "earRight") { u in -7 * k + back + ears.filter { $0.ear == 0 }.reduce(0) { $0 + flick(u, at: $1.at, amp: -abs($1.amp)) } }
        setBend(&p, rig, "earLeft") { u in 7 * k - back + ears.filter { $0.ear == 1 }.reduce(0) { $0 + flick(u, at: $1.at, amp: abs($1.amp)) } }
        let ex = eyeX.value + jitter.x, ey = eyeY.value + jitter.y
        move(&p, rig, "irises", ex, ey)
        let sniff = 1.7 * window(t, sniffAt, 0.1, sniffAt + 0.65, 0.15) * pow(max(0, sin(2 * .pi * 6.5 * (t - sniffAt))), 2)
        move(&p, rig, "muzzle", 0, -sniff)
        move(&p, rig, "chin", 0, 3 * meow + 7 * yawnOpen)
        let dilate = 1 + 0.24 * k + 0.12 * held - 0.06 * pet
        setScale(&p, rig, "pupilLeft", center: CGPoint(x: 236 + pad + ex, y: 171 + pad + ey), dilate, dilate)
        setScale(&p, rig, "pupilRight", center: CGPoint(x: 344 + pad + ex, y: 193 + pad + ey), dilate, dilate)

        let closure = max(blinkAmount(t), squint.value, 0.6 * slow, yawnEyes)
        setLids(&p, closure: closure)
        // The closed-eye frame is left-aligned with the sitting one (checked on a zoomed grid).
        p[RigParams.overlayW] = Float(blinkSize.width); p[RigParams.overlayH] = Float(blinkSize.height)
        if yawnOpen > 0.001 {
            p[RigParams.mouthOpen] = Float(yawnOpen); p[RigParams.mouthMask] = Float(RigParams.yawnMouthChannel); p[RigParams.mouthSource] = 1
            p[RigParams.mouthOffsetX] = Float(CatRigs.yawnMouthOffset.x); p[RigParams.mouthOffsetY] = Float(CatRigs.yawnMouthOffset.y)
            p[RigParams.mouthW] = Float(mouthSizes.yawn.width); p[RigParams.mouthH] = Float(mouthSizes.yawn.height)
        } else if meow > 0.001 {
            p[RigParams.mouthOpen] = Float(meow); p[RigParams.mouthMask] = Float(RigParams.meowMouthChannel); p[RigParams.mouthSource] = 0
            p[RigParams.mouthOffsetX] = Float(CatRigs.waveMouthOffset.x); p[RigParams.mouthOffsetY] = Float(CatRigs.waveMouthOffset.y)
            p[RigParams.mouthW] = Float(mouthSizes.wave.width); p[RigParams.mouthH] = Float(mouthSizes.wave.height)
        }
    }

    /// Swing angle (degrees, positive = paw forward) and lift (canvas pixels) for one leg.
    /// A planted paw sweeps back at a steady rate while the body passes over it; a lifted paw arcs forward.
    func leg(_ name: String) -> (degrees: Double, lift: Double) {
        guard let leg = CatRigs.legs.first(where: { $0.name == name }), let phase = CatMotion.legPhase[name] else { return (0, 0) }
        let length = Double(leg.length), v = speed.value
        let reach = asin(min(0.9, stepLength / (2 * length)))
        let u = (gait - phase) - floor(gait - phase), s = CatMotion.stance
        let angle: Double, lift: Double
        if u < s {
            angle = reach * (1 - 2 * u / s); lift = 0
        } else {
            let k = (u - s) / (1 - s)
            angle = -reach + 2 * reach * ease(k); lift = 11 * pow(sin(.pi * k), 1.2) * length / 110
        }
        return (angle * 180 / .pi * v, lift * v)
    }

    private func walkBody(_ p: inout [Float]) {
        let pad = Double(rigPad)
        setBody(&p, rotateAbout: CGPoint(x: 290 + pad, y: 260 + pad), degrees: walkPitch,
                scaleAbout: CGPoint(x: 290 + pad, y: 400 + pad), 1, 1 + walkBreath, lift: walkRise)
    }

    private func walkingLeg(_ p: inout [Float], _ rig: PoseRig, _ name: String) {
        let motion = leg(name)
        setBend(&p, rig, "leg") { _ in motion.degrees }
        move(&p, rig, "lift", 0, -motion.lift)
        walkBody(&p)
    }

    private func walking(_ p: inout [Float], _ rig: PoseRig) {
        let t = time, v = speed.value, g = gait, look = walkLook
        let nod = 0.8 * v * sin(4 * .pi * (g - 0.2)) - 3 * look
        let pitch = walkPitch
        setBend(&p, rig, "head") { _ in nod - 0.6 * pitch }
        move(&p, rig, "head", 2.5 * look, 0.5 * walkRise - 3 * look)
        let calm = 1 - v, c = cycle
        setBend(&p, rig, "tail", lag: 0.28) { u in
            (6 * v + 3) * sin(.pi * u / 0.9 + 0.4) * (0.6 + 0.4 * v) + 2 * v * sin(4 * .pi * (u / c - 0.1) - 1.3)
        }
        let tips = tipFlicks + (calm > 0.5 ? [pauseStart + 1.2] : [])
        setBend(&p, rig, "tip", lag: 0.06) { u in tips.reduce(0) { $0 + flick(u, at: $1, amp: 16, freq: 5) } }
        let ears = earFlicks
        setBend(&p, rig, "ear") { u in ears.reduce(0) { $0 + flick(u, at: $1.at, amp: $1.amp) } }
        var glanceX = 5.5 * look + 1.2 * sin(2 * .pi * t / 2.9) * v
        glanceX += (eyeX.value - glanceX) * interest.value * 0.8
        move(&p, rig, "irises", glanceX, -0.3 * look)
        walkBody(&p)
        // No closed-eye art from the side, so a blink is a quick squint.
        setLids(&p, closure: blinkAmount(t) * 0.8, strength: 0.5, swap: false)
    }

    private func sleeping(_ p: inout [Float], _ rig: PoseRig) {
        let t = time, pad = Double(rigPad)
        let b = breath(sleepPhase)
        setScale(&p, rig, "breath", center: CGPoint(x: 400 + pad, y: 325 + pad), 1 + 0.006 * b, 1 + 0.032 * b)
        let dream = dreamAt
        setBend(&p, rig, "head") { _ in 1.2 * sin(2 * .pi * t / 9) + flick(t, at: dream + 0.1, amp: 2, freq: 4, decay: 0.2) }
        move(&p, rig, "head", 0, -1.3 * b)
        let ears = earFlicks
        setBend(&p, rig, "earUp") { u in ears.filter { $0.ear == 0 }.reduce(0) { $0 + flick(u, at: $1.at, amp: $1.amp) } }
        setBend(&p, rig, "earSide") { u in ears.filter { $0.ear == 1 }.reduce(0) { $0 + flick(u, at: $1.at, amp: $1.amp * 0.8) } }
        let twitch = window(t, dream, 0.05, dream + 0.5, 0.2)
        move(&p, rig, "muzzle", 0, -1.4 * twitch * pow(max(0, sin(2 * .pi * 7 * (t - dream))), 2))
        move(&p, rig, "paws", 2.0 * twitch * sin(2 * .pi * 5 * (t - dream)), 0)
        let ground = CGPoint(x: 276 + pad, y: 325 + pad)
        setBody(&p, rotateAbout: ground, degrees: 0, scaleAbout: ground, 1, 1)
    }

    private func waving(_ p: inout [Float], _ rig: PoseRig) {
        let t = time, pad = Double(rigPad), s = t - poseSince
        let raise = ease(s / 0.18), swat = t - batAt
        if swat >= 0 && swat < 0.8 {
            // Cock the paw back, strike down and out, then let it drift back.
            setBend(&p, rig, "paw") { _ in keys(swat, [(0, 0), (0.12, 12), (0.24, -34), (0.4, -18), (0.8, 0)]) }
            setBend(&p, rig, "head") { _ in keys(swat, [(0, 0), (0.2, -3), (0.5, -2), (0.8, 0)]) }
        } else {
            setBend(&p, rig, "paw") { _ in raise * (13 * sin(2 * .pi * 2.1 * s) - 3) }
            setBend(&p, rig, "head") { _ in 3.5 * sin(2 * .pi * 1.05 * s + 0.5) }
        }
        move(&p, rig, "head", 0, -1.4 * abs(sin(2 * .pi * 1.05 * s)))
        setBend(&p, rig, "tail", lag: 0.3) { u in 7 * sin(2 * .pi * u / 1.5) }
        setBend(&p, rig, "earLeft") { _ in 4 * sin(2 * .pi * 2.1 * s + 1) }
        setBend(&p, rig, "earRight") { _ in -4 * sin(2 * .pi * 2.1 * s + 1.4) }
        let b = breath(breathPhase)
        let ground = CGPoint(x: 280 + pad, y: 465 + pad)
        setBody(&p, rotateAbout: ground, degrees: 0.8 * sin(2 * .pi * 1.05 * s), scaleAbout: ground, 1 + 0.005 * b, 1 + 0.014 * b)
    }
}
