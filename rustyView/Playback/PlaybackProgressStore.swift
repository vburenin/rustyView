import Foundation

struct PlaybackProgress: Codable, Equatable, Sendable {
    var serverOrigin: String
    let mediaID: String
    var position: Double
    var duration: Double
    var updatedAt: Date
    var accountUsername: String? = nil
}

final class PlaybackProgressStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "playbackProgress.v1"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func resumePosition(serverOrigin: String, mediaID: String, accountUsername: String? = nil) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let progress = load().first(where: {
            $0.serverOrigin == ServerIdentity.canonical(serverOrigin) && $0.mediaID == mediaID
                && $0.accountUsername == accountUsername
        }) else {
            return nil
        }
        return ResumePolicy.resumePosition(position: progress.position, duration: progress.duration)
    }

    func update(serverOrigin: String, mediaID: String, position: Double, duration: Double, accountUsername: String? = nil) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        var values = load()
        let identity = ServerIdentity.canonical(serverOrigin)
        values.removeAll { $0.serverOrigin == identity && $0.mediaID == mediaID && $0.accountUsername == accountUsername }
        if ResumePolicy.resumePosition(position: position, duration: duration) != nil {
            values.append(PlaybackProgress(
                serverOrigin: identity,
                mediaID: mediaID,
                position: position,
                duration: duration,
                updatedAt: Date(),
                accountUsername: accountUsername
            ))
        }
        values.sort { $0.updatedAt > $1.updatedAt }
        if values.count > 500 { values.removeLast(values.count - 500) }
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: key) }
    }

    func clear(serverOrigin: String, mediaID: String, accountUsername: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var values = load()
        values.removeAll {
            $0.serverOrigin == ServerIdentity.canonical(serverOrigin) && $0.mediaID == mediaID
                && $0.accountUsername == accountUsername
        }
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: key) }
    }

    func progressForMigration() throws -> [PlaybackProgress] {
        lock.lock()
        defer { lock.unlock() }
        if let data = defaults.data(forKey: key),
           (try? JSONDecoder().decode([PlaybackProgress].self, from: data)) == nil {
            throw UserLibraryFailure.unreadableLegacyProgress
        }
        return load(persistCanonicalization: false)
    }

    private func load(persistCanonicalization: Bool = true) -> [PlaybackProgress] {
        guard let data = defaults.data(forKey: key) else { return [] }
        guard let original = try? JSONDecoder().decode([PlaybackProgress].self, from: data) else { return [] }
        // Newest update wins equivalent legacy keys. Never assign an unknown account
        // or let another account's progress shadow an explicitly unassigned record.
        let normalized = original.map { value in
            var value = value
            value.serverOrigin = ServerIdentity.canonical(value.serverOrigin)
            return value
        }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            if $0.position != $1.position { return $0.position > $1.position }
            return $0.duration > $1.duration
        }
        var seen = Set<ProgressIdentity>()
        let migrated = normalized.filter {
            seen.insert(ProgressIdentity(server: $0.serverOrigin, account: $0.accountUsername, media: $0.mediaID)).inserted
        }
        if persistCanonicalization, migrated != original, let encoded = try? JSONEncoder().encode(migrated) {
            defaults.set(encoded, forKey: key)
        }
        return migrated
    }
}

private struct ProgressIdentity: Hashable {
    let server: String
    let account: String?
    let media: String
}
