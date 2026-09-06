import MediaPlayer

enum PlaybackCommandKind: CaseIterable {
    case play, pause, toggle, skipForward, skipBackward, seek
}

@MainActor
protocol PlaybackRemoteCommandRegistering {
    func addTarget(for kind: PlaybackCommandKind, handler: @escaping (PlaybackSystemCommand) -> MPRemoteCommandHandlerStatus) -> Any
    func removeTarget(_ target: Any, for kind: PlaybackCommandKind)
    func setEnabled(_ enabled: Bool, for kind: PlaybackCommandKind)
}

@MainActor
final class SystemPlaybackRemoteCommands: PlaybackRemoteCommandRegistering {
    private let center: MPRemoteCommandCenter
    init(center: MPRemoteCommandCenter = .shared()) { self.center = center }
    func addTarget(for kind: PlaybackCommandKind, handler: @escaping (PlaybackSystemCommand) -> MPRemoteCommandHandlerStatus) -> Any {
        if kind == .skipForward { center.skipForwardCommand.preferredIntervals = [10] }
        if kind == .skipBackward { center.skipBackwardCommand.preferredIntervals = [10] }
        return command(kind).addTarget { event in
            let action: PlaybackSystemCommand
            switch kind {
            case .play: action = .play
            case .pause: action = .pause
            case .toggle: action = .toggle
            case .skipForward: action = .skip((event as? MPSkipIntervalCommandEvent)?.interval ?? 10)
            case .skipBackward: action = .skip(-((event as? MPSkipIntervalCommandEvent)?.interval ?? 10))
            case .seek:
                guard let event = event as? MPChangePlaybackPositionCommandEvent, event.positionTime.isFinite else { return .commandFailed }
                action = .seek(event.positionTime)
            }
            return handler(action)
        }
    }
    func removeTarget(_ target: Any, for kind: PlaybackCommandKind) { command(kind).removeTarget(target) }
    func setEnabled(_ enabled: Bool, for kind: PlaybackCommandKind) { command(kind).isEnabled = enabled }
    private func command(_ kind: PlaybackCommandKind) -> MPRemoteCommand {
        switch kind {
        case .play: center.playCommand
        case .pause: center.pauseCommand
        case .toggle: center.togglePlayPauseCommand
        case .skipForward: center.skipForwardCommand
        case .skipBackward: center.skipBackwardCommand
        case .seek: center.changePlaybackPositionCommand
        }
    }
}
