import AppKit
import AVFoundation

/// Which pose the cat is in between clips. The take the clips come from is continuous, so every action
/// starts from one of these and leaves the cat in one of them; the links below are the moves in between.
enum Posture { case sitting, standing, crouched, lying }

extension ClipInfo {
    /// The pose each clip starts from and leaves the cat in.
    static let posture: [String: (from: Posture, to: Posture)] = [
        "wave": (.sitting, .sitting), "yawn": (.sitting, .sitting), "play": (.sitting, .crouched),
        "walk": (.standing, .standing), "stretch": (.standing, .sitting),
        "lieDown": (.sitting, .lying), "sleep": (.lying, .lying), "wake": (.lying, .sitting),
        "standUp": (.sitting, .standing), "sitDown": (.standing, .sitting), "getUp": (.crouched, .standing),
    ]

    /// The move that gets the cat from one pose to another, or nil when it is already there. From a crouch it
    /// always gets up on its feet first; sitting down from there is a second step.
    static func link(_ from: Posture, _ to: Posture) -> String? {
        switch (from, to) {
        case (.sitting, .standing): return "standUp"
        case (.standing, .sitting): return "sitDown"
        case (.crouched, _): return "getUp"
        case (.lying, _): return "wake"
        default: return nil
        }
    }
}


/// One cut from the green-screen video, keyed to transparent HEVC and cropped around the cat.
/// Points are in the clip's pixels with y down; anchors mark the middle of the paws on the floor.
struct ClipInfo: Decodable {
    let name: String
    let file: String
    let duration: Double
    let size: [Double]
    let start: [Double]
    let end: [Double]
    /// Loops until stopped (walking, sleeping).
    let loop: Bool?
    /// Clip pixels per second the window travels while this clip plays, so the paws stay planted.
    let speed: Double?
    /// Where the video's own ball leaves the last frame, and its velocity (pixels/second), for handing over to the real ball.
    let ballEnd: [Double]?
    let ballVelocity: [Double]?
    /// Where the video's ball is in the first frame (the play clip), so the cat lines up with the real ball first.
    let ballStart: [Double]?
    /// Loop by playing forwards then backwards; breathing joins up perfectly that way.
    let pingPong: Bool?
}

struct ClipLibrary: Decodable {
    /// Height of the sitting cat in clip pixels; maps the video cat onto the chosen cat size.
    let sitHeight: Double
    let clips: [ClipInfo]

    static func load(from directory: URL) -> ClipLibrary? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("clips.json")),
              let library = try? JSONDecoder().decode(ClipLibrary.self, from: data) else { return nil }
        let missing = library.clips.filter { !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.file).path) }
        return missing.isEmpty ? library : nil
    }

    subscript(_ name: String) -> ClipInfo? { clips.first { $0.name == name } }
}

/// Plays clips in a transparent window placed so the video cat's paws land where the drawn cat's paws are.
/// Two video layers take turns, so a clip that follows another only replaces it once its first frame is ready.
final class ClipStage: NSObject {
    /// A looping clip decoded into frames, so the loop joins exactly instead of relying on the system's
    /// looping player, which blanks for a moment each time it starts the clip over.
    final class Film {
        let frames: [CGImage]
        let fps: Double
        let pingPong: Bool
        var bytes: Int { frames.count * (frames.first.map { $0.width * $0.height * 4 } ?? 0) }

        init(frames: [CGImage], fps: Double, pingPong: Bool) {
            self.frames = frames; self.fps = fps; self.pingPong = pingPong
        }

        func image(at seconds: Double) -> CGImage {
            let count = frames.count
            guard count > 1 else { return frames[0] }
            let step = Int(max(0, seconds) * fps)
            if pingPong {
                let cycle = (count - 1) * 2
                let k = step % cycle
                return frames[k < count ? k : cycle - k]
            }
            return frames[step % count]
        }

        /// Decodes every frame at the size it will be drawn.
        static func decode(url: URL, width: Int, height: Int, pingPong: Bool) -> Film? {
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
            let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                           kCVPixelBufferWidthKey as String: max(2, width),
                                           kCVPixelBufferHeightKey as String: max(2, height)]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            reader.startReading()
            var frames: [CGImage] = []
            while let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                if let image = ctx?.makeImage() { frames.append(image) }
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            }
            guard !frames.isEmpty else { return nil }
            let fps = Double(track.nominalFrameRate) > 1 ? Double(track.nominalFrameRate) : 24
            return Film(frames: frames, fps: fps, pingPong: pingPong)
        }
    }

    private final class Slot {
        let layer = CALayer()
        let video = AVPlayerLayer()
        var player: AVQueuePlayer?
        var readyWatch: NSKeyValueObservation?
        var boundary: Any?
        var film: Film?
        var filmStart = 0.0
        var shownFrame: CGImage?

        func clear() {
            readyWatch = nil
            if let boundary, let player { player.removeTimeObserver(boundary) }
            boundary = nil
            player?.pause()
            player?.removeAllItems()
            video.player = nil
            player = nil
            film = nil
            shownFrame = nil
            layer.contents = nil
        }
    }

    let panel: PetPanel
    let directory: URL
    private let host = NSView()
    private let slots = [Slot(), Slot()]
    private var active = 0
    private var token = 0
    private(set) var clip: ClipInfo?
    private(set) var mirrored = false
    private(set) var scale: CGFloat = 1

    init(directory: URL) {
        self.directory = directory
        panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        host.wantsLayer = true
        host.layer!.backgroundColor = NSColor.clear.cgColor
        host.layer!.masksToBounds = false
        for slot in slots {
            // An alpha pixel format is what lets the keyed video composite over the desktop.
            slot.video.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            slot.video.videoGravity = .resize
            slot.layer.opacity = 0
            slot.layer.contentsGravity = .resize
            for layer in [slot.layer, slot.video] {
                layer.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull(), "opacity": NSNull(), "contents": NSNull()]
            }
            slot.layer.addSublayer(slot.video)
            host.layer!.addSublayer(slot.layer)
        }
        panel.contentView = host
    }

    var isPlaying: Bool { clip != nil }

    /// Gets the clips ready before they are first needed: looping clips are decoded into frames, the others
    /// have their first frame decoded by a paused player. Without this the first use of each clip appears a
    /// fifth of a second late, which reads as a stutter when the cat switches.
    func prewarm(_ library: ClipLibrary, scale: CGFloat) {
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        var wanted: Set<String> = []
        for clip in library.clips {
            let url = directory.appendingPathComponent(clip.file)
            if clip.loop == true {
                let pixels = (Int((CGFloat(clip.size[0]) * scale * backing).rounded()), Int((CGFloat(clip.size[1]) * scale * backing).rounded()))
                let key = "\(clip.name)@\(pixels.0)"
                wanted.insert(key)
                guard films[key] == nil, decoding != key else { continue }
                decoding = key
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let film = Film.decode(url: url, width: pixels.0, height: pixels.1, pingPong: clip.pingPong == true)
                    DispatchQueue.main.async {
                        self?.decoding = nil
                        if let film { self?.films[key] = film }
                    }
                }
            } else if warm[clip.name] == nil {
                warmPlayer(url: url, name: clip.name)
            }
        }
        // Frames are decoded for one pixel size; after a resize the old ones are only wasted memory.
        for key in films.keys where !wanted.contains(key) { films.removeValue(forKey: key) }
    }

    /// Keeps a paused player sitting on a clip's first frame. AVFoundation only accepts `preroll` once the
    /// player reports itself ready - asking any earlier raises - so the warm-up waits for that moment.
    private func warmPlayer(url: URL, name: String) {
        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.insert(AVPlayerItem(url: url), after: nil)
        warm[name] = player
        warmWatch[name] = player.observe(\.status, options: [.initial, .new]) { [weak self] player, _ in
            guard player.status == .readyToPlay, player.currentItem != nil else { return }
            DispatchQueue.main.async {
                guard let self, self.warm[name] === player else { return }
                self.warmWatch[name] = nil
                player.preroll(atRate: 1) { _ in }
            }
        }
    }
    private var films: [String: Film] = [:]
    private var decoding: String?
    /// Players kept paused on their first frame, one per non-looping clip.
    private var warm: [String: AVQueuePlayer] = [:]
    private var warmWatch: [String: NSKeyValueObservation] = [:]
    private var clock: AnyObject?

    /// The clip window runs its own frame clock: the cat's window may be covered by other windows, and macOS
    /// pauses a hidden window's display link, which would freeze the clip.
    private func startClock() {
        guard clock == nil else { return }
        if #available(macOS 14.0, *) {
            let link = host.displayLink(target: self, selector: #selector(clockFired(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 30)
            link.add(to: .main, forMode: .common)
            clock = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(clockFired(_:)), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
        }
    }

    private func stopClock() {
        if #available(macOS 14.0, *) { (clock as? CADisplayLink)?.invalidate() }
        (clock as? Timer)?.invalidate()
        clock = nil
    }

    @objc private func clockFired(_ sender: Any?) { tick(CACurrentMediaTime()) }

    /// Diagnostics: how many decoded frames were put on screen since the last check.
    private(set) var framesShown = 0
    func takeFrameCount() -> Int { defer { framesShown = 0 }; return framesShown }

    /// Advances a decoded looping clip; call once per displayed frame.
    func tick(_ now: CFTimeInterval) {
        let slot = slots[active]
        guard let film = slot.film else { return }
        let image = film.image(at: now - slot.filmStart)
        guard image !== slot.shownFrame else { return }
        slot.shownFrame = image
        framesShown += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        slot.layer.contents = image
        CATransaction.commit()
    }

    /// Starts `clip` with its first anchor at `anchor` (screen points). `ready` runs once the first frame is on
    /// screen (hide the drawn cat then); `ending` runs a moment before a non-looping clip ends.
    func play(_ clip: ClipInfo, anchor: CGPoint, scale: CGFloat, mirrored: Bool, above window: NSWindow,
              fadeIn: Double = 0.2, ready: @escaping () -> Void, ending: @escaping () -> Void) {
        let entered = CACurrentMediaTime()
        defer { if ProcessInfo.processInfo.environment["NAIGREY_CPULOG"] != nil {
            NSLog("奶灰: start %@ took %.0f ms on the main thread", clip.name, (CACurrentMediaTime() - entered) * 1000) } }
        token += 1
        let current = token
        let previous = slots[active], next = slots[1 - active]
        active = 1 - active
        next.clear()

        let oldFrame = panel.frame
        let frame = ClipStage.frame(for: clip, anchor: anchor, scale: scale, mirrored: mirrored)
        let w = frame.width, h = frame.height
        let hadClip = self.clip != nil
        self.clip = clip
        self.mirrored = mirrored
        self.scale = scale

        CATransaction.begin(); CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: false)
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        // Keep the outgoing clip exactly where it was on screen while the window changes size.
        if hadClip { previous.layer.frame = previous.layer.frame.offsetBy(dx: oldFrame.minX - frame.minX, dy: oldFrame.minY - frame.minY) }
        next.layer.transform = CATransform3DIdentity
        next.layer.frame = host.bounds
        next.video.frame = next.layer.bounds
        next.layer.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        next.layer.opacity = 0
        next.layer.zPosition = 1
        previous.layer.zPosition = 0
        CATransaction.commit()

        panel.order(.above, relativeTo: window.windowNumber)
        startClock()
        var shown = false
        let reveal = { [weak self] in
            guard let self, self.token == current, !shown else { return }
            shown = true
            if ProcessInfo.processInfo.environment["NAIGREY_CPULOG"] != nil {
                NSLog("奶灰: %@ first frame %.0f ms after start", clip.name, (CACurrentMediaTime() - entered) * 1000)
            }
            // Never cross-dissolve: two half-transparent cats let the desktop through both of them, which
            // reads as a flash. The new clip comes up over a picture that stays solid underneath, and what
            // was there before is only taken away once the new one covers it.
            self.fade(next.layer, to: 1, duration: ClipStage.coverIn, curve: .easeOut)
            if hadClip {
                DispatchQueue.main.asyncAfter(deadline: .now() + ClipStage.coverIn + 0.03) {
                    guard self.token == current, self.slots[self.active] !== previous else { return }
                    previous.clear()
                }
            }
            ready()
        }

        let url = directory.appendingPathComponent(clip.file)
        if clip.loop == true {
            // Looping clips play from decoded frames: the loop joins exactly and never blanks.
            let backing = panel.backingScaleFactor > 0 ? panel.backingScaleFactor : (NSScreen.main?.backingScaleFactor ?? 2)
            let pixels = (Int((w * backing).rounded()), Int((h * backing).rounded()))
            let key = "\(clip.name)@\(pixels.0)"
            let start = { [weak self] (film: Film) in
                guard let self, self.token == current else { return }
                next.film = film
                next.filmStart = CACurrentMediaTime()
                next.shownFrame = film.frames[0]
                CATransaction.begin(); CATransaction.setDisableActions(true)
                next.layer.contents = film.frames[0]
                CATransaction.commit()
                reveal()
            }
            if let film = films[key] {
                start(film)
            } else if decoding != key {
                decoding = key
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let began = CACurrentMediaTime()
                    let film = Film.decode(url: url, width: pixels.0, height: pixels.1, pingPong: clip.pingPong == true)
                    if ProcessInfo.processInfo.environment["NAIGREY_CPULOG"] != nil {
                        NSLog("奶灰: decoded %@ (%d frames) in %.0f ms", clip.name, film?.frames.count ?? 0, (CACurrentMediaTime() - began) * 1000)
                    }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.decoding = nil
                        guard let film else { NSLog("奶灰: could not decode %@", clip.file); return }
                        // Keep only the clips that loop; two of them fit comfortably.
                        if self.films.count >= 2, let oldest = self.films.keys.first { self.films.removeValue(forKey: oldest) }
                        self.films[key] = film
                        start(film)
                    }
                }
            }
        } else {
            let queue: AVQueuePlayer
            warmWatch[clip.name] = nil
            if let ready = warm.removeValue(forKey: clip.name), ready.currentItem != nil {
                queue = ready
                queue.seek(to: .zero)
            } else {
                queue = AVQueuePlayer()
                queue.isMuted = true
                queue.actionAtItemEnd = .pause
                queue.insert(AVPlayerItem(url: url), after: nil)
            }
            let at = CMTime(seconds: max(0.05, clip.duration - 0.2), preferredTimescale: 600)
            next.boundary = queue.addBoundaryTimeObserver(forTimes: [NSValue(time: at)], queue: .main) { [weak self] in
                guard let self, self.token == current else { return }
                ending()
            }
            next.player = queue
            next.video.player = queue
            // Have a fresh player ready for the next time this clip is used.
            let refill = { [weak self] in
                guard let self, self.warm[clip.name] == nil else { return }
                self.warmPlayer(url: url, name: clip.name)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: refill)
            next.readyWatch = next.video.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                if layer.isReadyForDisplay { DispatchQueue.main.async(execute: reveal) }
            }
            // Never leave the cat invisible if the decoder is slow to report readiness.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: reveal)
            queue.play()
        }
    }

    /// Hand-off timing. The rule these encode: the drawn cat and the clip must never both be part
    /// transparent at the same moment, because then the desktop shows through both and the cat appears to
    /// flash. So the incoming picture is brought up to solid first, and only then is the old one taken away.
    static let coverIn = 0.12     // the incoming clip fades up over this, ease-out
    static let catHold = 0.08     // the drawn cat underneath stays solid at least this long
    static let catOut = 0.06      // then it leaves, by which time the clip covers it
    static let uncoverDelay = 0.06  // coming back, the cat is up this long before the clip starts leaving

    /// Fades the clip away; the window is cleared once it's invisible.
    func stop(fadeOut: Double = 0.2) {
        guard clip != nil else { return }
        token += 1
        let current = token
        clip = nil
        for slot in slots { fade(slot.layer, to: 0, duration: fadeOut, curve: fadeOut > 0 ? .easeIn : nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeOut + 0.05) { [weak self] in
            guard let self, self.token == current else { return }
            self.slots.forEach { $0.clear() }
            self.panel.orderOut(nil)
            self.stopClock()
        }
    }

    /// Moves the clip together with the walking cat.
    func shift(dx: CGFloat) {
        guard clip != nil else { return }
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + dx, y: panel.frame.minY))
    }

    /// Window frame (screen points) that puts the clip's first anchor on `anchor`.
    static func frame(for clip: ClipInfo, anchor: CGPoint, scale: CGFloat, mirrored: Bool) -> NSRect {
        let w = CGFloat(clip.size[0]) * scale, h = CGFloat(clip.size[1]) * scale
        let ax = CGFloat(mirrored ? clip.size[0] - clip.start[0] : clip.start[0]) * scale
        let ay = CGFloat(clip.size[1] - clip.start[1]) * scale
        return NSRect(x: anchor.x - ax, y: anchor.y - ay, width: w, height: h)
    }

    /// Screen point of a clip pixel (y down) inside a window placed at `frame`.
    static func point(_ p: [Double], in clip: ClipInfo, frame: NSRect, scale: CGFloat, mirrored: Bool) -> CGPoint {
        let x = CGFloat(mirrored ? clip.size[0] - p[0] : p[0]) * scale
        return CGPoint(x: frame.minX + x, y: frame.minY + CGFloat(clip.size[1] - p[1]) * scale)
    }

    /// Screen point of the clip's last anchor, where the drawn cat should reappear.
    var endAnchor: CGPoint? {
        guard let clip else { return nil }
        return ClipStage.point(clip.end, in: clip, frame: panel.frame, scale: scale, mirrored: mirrored)
    }

    /// Screen point and velocity (points/second) of the video's ball as it leaves the last frame.
    var ballHandOff: (point: CGPoint, velocity: CGVector)? {
        guard let clip, let p = clip.ballEnd, let v = clip.ballVelocity else { return nil }
        return (ClipStage.point(p, in: clip, frame: panel.frame, scale: scale, mirrored: mirrored),
                CGVector(dx: CGFloat(mirrored ? -v[0] : v[0]) * scale, dy: CGFloat(-v[1]) * scale))
    }

    private func fade(_ layer: CALayer, to opacity: Float, duration: Double, curve: CAMediaTimingFunctionName? = nil) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = opacity
        CATransaction.commit()
        guard duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = opacity
        animation.duration = duration
        if let curve { animation.timingFunction = CAMediaTimingFunction(name: curve) }
        layer.add(animation, forKey: "fade")
    }
}
