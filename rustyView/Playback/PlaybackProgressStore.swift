import Foundation

struct PlaybackProgress: Codable, Equatable, Sendable {
    let serverOrigin: String
    let mediaID: String
    var position: Double
    var duration: Double
    var updatedAt: Date
}

final class PlaybackProgressStore {
    private let defaults: UserDefaults
    private let key = "playbackProgress.v1"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func resumePosition(serverOrigin: String, mediaID: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let progress = load().first(where: {
            $0.serverOrigin == serverOrigin && $0.mediaID == mediaID
        }), progress.position >= 30, progress.duration > 0,
           progress.position < progress.duration - 90 else {
            return nil
        }
        return progress.position
    }

    func update(serverOrigin: String, mediaID: String, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        var values = load()
        values.removeAll { $0.serverOrigin == serverOrigin && $0.mediaID == mediaID }
        if position >= 30, position < duration - 90 {
            values.append(PlaybackProgress(
                serverOrigin: serverOrigin,
                mediaID: mediaID,
                position: position,
                duration: duration,
                updatedAt: Date()
            ))
        }
        values.sort { $0.updatedAt > $1.updatedAt }
        if values.count > 500 { values.removeLast(values.count - 500) }
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: key) }
    }

    func clear(serverOrigin: String, mediaID: String) {
        lock.lock()
        defer { lock.unlock() }
        var values = load()
        values.removeAll { $0.serverOrigin == serverOrigin && $0.mediaID == mediaID }
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: key) }
    }

    private func load() -> [PlaybackProgress] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PlaybackProgress].self, from: data)) ?? []
    }
}
