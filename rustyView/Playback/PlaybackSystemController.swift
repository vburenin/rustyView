import AVFoundation
import MediaPlayer

enum PlaybackSystemEvent: Equatable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeDisconnected
    case mediaServicesLost
    case mediaServicesReset
}

enum PlaybackSystemCommand: Equatable {
    case play, pause, toggle
    case skip(Double), seek(Double)
}

struct PlaybackNowPlayingSnapshot: Equatable {
    let title: String
    let elapsed: Double
    let duration: Double?
    let rate: Double
    let defaultRate: Double
    let canPlay: Bool
    let canPause: Bool
    let canSeek: Bool
}

@MainActor
protocol PlaybackAudioSessionControlling {
    func activate() throws
    func deactivate() throws
}

@MainActor
final class SystemPlaybackAudioSession: PlaybackAudioSessionControlling {
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
    }
    func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Remote handlers can arrive off the main actor after removeTarget. This
/// small lease rejects retired callbacks before scheduling their actor hop.
private final class PlaybackCommandLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func invalidate() { lock.lock(); active = false; lock.unlock() }
}

/// Owns the system-facing registrations independently of AV item generations.
/// Notifications remain installed while the model lives, including a held
/// Start Over/Resume; remote command targets exist only while this owner plays.
@MainActor
final class PlaybackSystemController {
    var onEvent: ((PlaybackSystemEvent) -> Void)?
    var onCommand: ((PlaybackSystemCommand) -> Void)?
    private(set) var lastSnapshot: PlaybackNowPlayingSnapshot?
    private static var owner: UUID?
    private let id = UUID()
    private let audioSession: any PlaybackAudioSessionControlling
    private let notifications: NotificationCenter
    private let remoteCommands: any PlaybackRemoteCommandRegistering
    private let nowPlayingCenter: MPNowPlayingInfoCenter
    private var notificationTokens: [NSObjectProtocol] = []
    private var commandTargets: [(PlaybackCommandKind, Any)] = []
    private var lease: PlaybackCommandLease?
    private var isOwner: Bool { Self.owner == id }

    init(audioSession: (any PlaybackAudioSessionControlling)? = nil,
         notifications: NotificationCenter = .default,
         commandCenter: MPRemoteCommandCenter = .shared(),
         remoteCommands: (any PlaybackRemoteCommandRegistering)? = nil,
         nowPlayingCenter: MPNowPlayingInfoCenter = .default()) {
        self.audioSession = audioSession ?? SystemPlaybackAudioSession()
        self.notifications = notifications
        self.remoteCommands = remoteCommands ?? SystemPlaybackRemoteCommands(center: commandCenter)
        self.nowPlayingCenter = nowPlayingCenter
        observe(AVAudioSession.interruptionNotification) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
            if type == .began { return .interruptionBegan }
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            return .interruptionEnded(shouldResume: AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume))
        }
        observe(AVAudioSession.routeChangeNotification) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return nil }
            return .routeDisconnected
        }
        observe(AVAudioSession.mediaServicesWereLostNotification) { _ in .mediaServicesLost }
        observe(AVAudioSession.mediaServicesWereResetNotification) { _ in .mediaServicesReset }
    }

    func claim() {
        if isOwner, lease != nil { return }
        retireCommands()
        Self.owner = id
        let lease = PlaybackCommandLease()
        self.lease = lease
        PlaybackCommandKind.allCases.forEach { register($0, lease: lease) }
    }

    func activate() throws { claim(); try audioSession.activate() }

    func publish(_ snapshot: PlaybackNowPlayingSnapshot) {
        guard isOwner else { return }
        lastSnapshot = snapshot
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.defaultRate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let duration = snapshot.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        nowPlayingCenter.nowPlayingInfo = info
        remoteCommands.setEnabled(snapshot.canPlay, for: .play)
        remoteCommands.setEnabled(snapshot.canPause, for: .pause)
        remoteCommands.setEnabled(snapshot.canPlay || snapshot.canPause, for: .toggle)
        for kind in [PlaybackCommandKind.skipForward, .skipBackward, .seek] { remoteCommands.setEnabled(snapshot.canSeek, for: kind) }
    }

    /// Safe to call more than once, including after a newer controller claims
    /// ownership. Old cleanup removes only this controller's targets.
    func release() {
        retireCommands()
        lastSnapshot = nil
        guard isOwner else { return }
        Self.owner = nil
        nowPlayingCenter.nowPlayingInfo = nil
        PlaybackCommandKind.allCases.forEach { remoteCommands.setEnabled(false, for: $0) }
        try? audioSession.deactivate()
    }

    private func observe(_ name: Notification.Name, transform: @escaping (Notification) -> PlaybackSystemEvent?) {
        let token = notifications.addObserver(forName: name, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            guard let event = transform(notification) else { return }
            Task { @MainActor [weak self] in self?.onEvent?(event) }
        }
        notificationTokens.append(token)
    }

    private func register(_ command: PlaybackCommandKind, lease: PlaybackCommandLease) {
        let target = remoteCommands.addTarget(for: command) { [weak self, lease] action in
            guard lease.isActive else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self, self.isOwner, self.lease === lease, lease.isActive else { return }
                self.onCommand?(action)
            }
            return .success
        }
        commandTargets.append((command, target))
    }

    private func retireCommands() {
        lease?.invalidate(); lease = nil
        commandTargets.forEach { remoteCommands.removeTarget($0.1, for: $0.0) }
        commandTargets.removeAll()
    }

    deinit {
        lease?.invalidate()
        notificationTokens.forEach { notifications.removeObserver($0) }
        let remoteCommands = remoteCommands, targets = commandTargets
        Task { @MainActor in targets.forEach { remoteCommands.removeTarget($0.1, for: $0.0) } }
    }
}
