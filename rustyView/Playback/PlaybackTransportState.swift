import Foundation

struct PlaybackTransportState: Equatable {
    enum Intent: Equatable { case playing, paused }
    enum Phase: Equatable {
        case idle, preparing, playing, buffering, paused, seeking, ended
        case failed(String)
    }
    var intent = Intent.paused
    var phase = Phase.idle
    var attempt = PlaybackAttempt.original
    var recoveryAttempt = 0
    var progressed = false

    var actionLabel: String {
        if case .failed = phase { return "Retry Current Playback" }
        if phase == .ended { return "Replay" }
        return intent == .playing ? "Pause" : "Play"
    }

    var actionSymbol: String {
        if case .failed = phase { return "arrow.clockwise" }
        return intent == .playing && phase != .ended ? "pause.fill" : "play.fill"
    }
}

/// Readiness and rate are insufficient: a ready item can wait forever for its
/// first segment. Only advancing media time resets this deadline. Pausing and
/// seeking begin a fresh observation interval without counting the time jump
/// as decoded playback.
struct PlaybackProgressWatchdog {
    let timeout: TimeInterval
    private var lastTime: Double?
    private var lastProgressAt: TimeInterval?
    private(set) var hasProgressed = false

    init(timeout: TimeInterval = 15) { self.timeout = timeout }

    mutating func reset() {
        lastTime = nil
        lastProgressAt = nil
        hasProgressed = false
    }

    mutating func sample(time: Double, now: TimeInterval, shouldAdvance: Bool) -> Bool {
        guard shouldAdvance else {
            lastTime = nil
            lastProgressAt = nil
            return false
        }
        if lastProgressAt == nil { lastProgressAt = now }
        if time.isFinite {
            if let previous = lastTime, time > previous + 0.05 {
                hasProgressed = true
                lastTime = time
                lastProgressAt = now
                return false
            }
            if lastTime == nil { lastTime = time }
        }
        // AVPlayer may report an indefinite/invalid time during preparation.
        // It still consumes the deadline: only deliberate pause/seek suspends it.
        return now - (lastProgressAt ?? now) >= timeout
    }
}
