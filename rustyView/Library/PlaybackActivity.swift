import Foundation

enum ResumePolicy {
    static func resumePosition(position: Double, duration: Double) -> Double? {
        guard position.isFinite, duration.isFinite, duration > 0 else { return nil }
        let beginning = min(30, duration * 0.05)
        let ending = min(90, duration * 0.05)
        guard position >= beginning, position < duration - ending else { return nil }
        return position
    }
}

struct PlaybackActivity: Sendable {
    enum Source: Codable, Hashable, Sendable {
        case online
        case offline(recordID: UUID)
    }

    enum Event: Sendable {
        case started(position: Double, duration: Double)
        case progress(position: Double, duration: Double)
        case startedOver
        case completed(position: Double, duration: Double)
    }

    let viewingID: UUID
    let key: MovieLibraryKey
    let movie: MovieMetadata
    let source: Source
    let event: Event
    let occurredAt: Date

    init(viewingID: UUID, key: MovieLibraryKey, movie: MovieMetadata, source: Source,
         event: Event, occurredAt: Date = Date()) {
        self.viewingID = viewingID
        self.key = key
        self.movie = movie
        self.source = source
        self.event = event
        self.occurredAt = occurredAt
    }
}

@MainActor
protocol PlaybackActivityStore: AnyObject {
    var isRestoring: Bool { get }
    func waitUntilRestored() async
    func resumePosition(for key: MovieLibraryKey) -> Double?
    func record(_ activity: PlaybackActivity)
    func commit(_ activity: PlaybackActivity) async throws
    func flush() async throws
}

extension PlaybackActivityStore {
    var isRestoring: Bool { false }
    func waitUntilRestored() async { }
}

/// Standalone player tests can keep their existing progress store boundary.
/// The application injects UserLibraryStore and never writes both stores.
@MainActor
final class LegacyPlaybackActivityAdapter: PlaybackActivityStore {
    private let progressStore: PlaybackProgressStore

    init(progressStore: PlaybackProgressStore) { self.progressStore = progressStore }

    func resumePosition(for key: MovieLibraryKey) -> Double? {
        progressStore.resumePosition(serverOrigin: key.serverIdentity, mediaID: key.mediaID,
                                     accountUsername: key.accountUsername)
    }

    func record(_ activity: PlaybackActivity) {
        switch activity.event {
        case .started(let position, let duration), .progress(let position, let duration):
            progressStore.update(serverOrigin: activity.key.serverIdentity, mediaID: activity.key.mediaID,
                                 position: position, duration: duration, accountUsername: activity.key.accountUsername)
        case .startedOver, .completed:
            progressStore.clear(serverOrigin: activity.key.serverIdentity, mediaID: activity.key.mediaID,
                                accountUsername: activity.key.accountUsername)
        }
    }

    func commit(_ activity: PlaybackActivity) async throws { record(activity) }
    func flush() async throws { }
}
