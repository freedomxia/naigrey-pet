import AppKit
import CoreAudio

/// Notices that music is playing, without hearing any of it: CoreAudio will say whether the machine's
/// output device is in use by some app, which needs no permission and carries no audio at all.
/// Short system beeps are ignored - it takes a while of continuous sound before the cat believes it.
final class AudioWatch {
    private var device = AudioObjectID(0)
    private var playingSince: TimeInterval?
    private var quietSince: TimeInterval = 0
    private(set) var isPlaying = false

    /// How long sound has to run before it counts as music, and how long silence has to last before it stops.
    static let starts = 8.0, ends = 4.0

    init() { refreshDevice() }

    func refreshDevice() {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr {
            device = id
        }
    }

    private var outputIsRunning: Bool {
        guard device != 0 else { return false }
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// Call a few times a second. Returns true while there is music worth listening to.
    @discardableResult
    func update(_ now: TimeInterval) -> Bool {
        if outputIsRunning {
            quietSince = now
            if playingSince == nil { playingSince = now }
            if !isPlaying, now - (playingSince ?? now) >= AudioWatch.starts { isPlaying = true }
        } else {
            playingSince = nil
            if isPlaying, now - quietSince >= AudioWatch.ends { isPlaying = false }
        }
        return isPlaying
    }
}

/// Follows how hard you are typing, from the one thing the system will tell anyone: how long ago the last
/// key went down. Nothing about *which* keys, and no permission is needed for it.
final class TypingWatch {
    private var lastKeyAge: TimeInterval = .greatestFiniteMagnitude
    private var beats: [TimeInterval] = []      // 最近几次敲击的时刻
    private(set) var isTyping = false

    /// How long you have to keep typing before the cat joins in, and how long a pause ends it.
    static let starts = 2.5, ends = 2.0

    /// Call a few times a second.
    @discardableResult
    func update(_ now: TimeInterval) -> Bool {
        let age = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        // 距离上次按键的时间「变小了」，说明这中间又敲了一下
        if age < lastKeyAge { beats.append(now - age) }
        lastKeyAge = age
        beats.removeAll { now - $0 > 6 }
        if age < 1.2, let first = beats.first, now - first >= TypingWatch.starts, beats.count >= 6 { isTyping = true }
        if age > TypingWatch.ends { isTyping = false }
        return isTyping
    }

    /// Keys per second over the last few seconds, 0 when nothing is happening.
    var pace: Double {
        guard let first = beats.first, let last = beats.last, last > first else { return 0 }
        return Double(beats.count - 1) / (last - first)
    }

    /// How fast to play the typing clip: a busy burst speeds it up, thinking slows it down, within reason.
    var playbackRate: Double { isTyping ? TypingWatch.rate(forPace: pace) : 1 }

    /// 约 3.5 键/秒（中等速度）时正常速度播放，快了最多 1.4 倍，慢了最少 0.7 倍。
    static func rate(forPace pace: Double) -> Double { min(1.4, max(0.7, 0.55 + pace * 0.13)) }
}
