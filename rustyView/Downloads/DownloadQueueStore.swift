import Foundation

/// Intent is independent of a system task, which can disappear after failure.
/// Credentials are deliberately absent. A nil account belongs to a legacy copy;
/// it must never be adopted by whichever account happens to connect next.
struct DownloadQueueEntry: Codable, Equatable, Identifiable, Sendable {
    var metadata: DownloadTaskMetadata
    var state: DownloadQueueState = .queued
    var taskIdentifier: Int?
    var scheduledAt: Date?
    var reason: String?
    var failure: UserFacingError? = nil
    var packagePlan: OfflinePackagePlan? = nil
    var resources: [DownloadResourceDescriptor]? = nil
    var enqueuedAt: Date? = nil
    var waitingReason: DownloadWaitingReason? = nil
    var id: UUID { metadata.recordID }

    var activeDownload: ActiveDownload? {
        guard !state.isTerminal else { return nil }
        let phase: DownloadPhase
        switch state {
        case .failed:
            phase = .failed(message: reason ?? "Connect to this download's account to continue.")
        case .pausing:
            phase = .pausing
        case .paused:
            phase = .paused(canResume: resources?.contains(where: { $0.resumeReference != nil }) == true)
        case .waiting:
            phase = .waiting(reason: waitingReason ?? .credentials)
        case .installing:
            phase = .finishing
        case .queued, .running:
            if let scheduledAt, (metadata.retryAttempt ?? 0) > 0 {
                phase = .retrying(attempt: metadata.retryAttempt ?? 0, scheduledAt: scheduledAt,
                                  reason: reason ?? "The previous attempt was interrupted.")
            } else {
                phase = .queued
            }
        case .removed, .completed, .cancelled, .deleted:
            return nil
        }
        return ActiveDownload(id: id, serverOrigin: metadata.serverOrigin, mediaID: metadata.mediaID,
                              title: metadata.title, kind: metadata.kind, phase: phase,
                              taskIdentifier: taskIdentifier ?? -1, metadata: metadata, failure: failure)
    }
}

enum DownloadQueueState: String, Codable, Sendable {
    case queued, waiting, running, pausing, paused, installing, failed, removed, completed, cancelled, deleted

    var isTerminal: Bool { self == .removed || self == .completed || self == .cancelled || self == .deleted }
}

struct DownloadQueueJournal: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var entries: [DownloadQueueEntry] = []
}

enum DownloadQueueError: LocalizedError {
    case invalidJournal
    case missingOwnership

    var errorDescription: String? {
        switch self {
        case .invalidJournal:
            "The download queue could not be read. Your downloaded movies are still preserved."
        case .missingOwnership:
            "Connect to the account that requested this download to retry. Older downloads without account information must be started again from the movie page."
        }
    }
}

final class DownloadQueueStore: @unchecked Sendable {
    private let rootDirectory: URL
    private let lock = NSRecursiveLock()
    private var stateStore: DownloadStateStore { DownloadStateStore(rootDirectory: rootDirectory) }

    init(rootDirectory: URL) { self.rootDirectory = rootDirectory }

    func load() throws -> DownloadQueueJournal {
        lock.lock()
        defer { lock.unlock() }
        return DownloadQueueJournal(entries: try stateStore.load().queue)
    }

    func save(_ journal: DownloadQueueJournal) throws {
        lock.lock()
        defer { lock.unlock() }
        try stateStore.update { $0.queue = journal.entries }
    }

    func update(_ entry: DownloadQueueEntry) throws {
        lock.lock()
        defer { lock.unlock() }
        try stateStore.update { snapshot in
            snapshot.queue.removeAll { $0.id == entry.id }
            snapshot.queue.append(entry)
        }
    }

    func permitsInstallation(metadata: DownloadTaskMetadata) throws -> Bool {
        // A missing entry is a pre-journal system task awaiting migration.
        guard let entry = try load().entries.first(where: { $0.id == metadata.recordID }) else { return true }
        return !entry.state.isTerminal && entry.state != .failed && entry.state != .paused && entry.state != .pausing
            && DownloadOwnership.sameRendition(entry.metadata, metadata)
            && entry.metadata.attemptID == metadata.attemptID
            && (entry.metadata.serverPath == nil || entry.metadata.serverPath == metadata.serverPath)
            && (entry.metadata.retryAttempt ?? 0) == (metadata.retryAttempt ?? 0)
    }
}

enum DownloadOwnership {
    static func canonicalServer(_ value: String) -> String {
        ServerIdentity.canonical(value)
    }

    static func matches(_ metadata: DownloadTaskMetadata, connection: ServerConnection?) -> Bool {
        guard let connection, let account = metadata.accountUsername else { return false }
        return canonicalServer(metadata.serverOrigin) == connection.serverIdentity && account == connection.username
    }

    static func sameRendition(_ left: DownloadTaskMetadata, _ right: DownloadTaskMetadata) -> Bool {
        canonicalServer(left.serverOrigin) == canonicalServer(right.serverOrigin)
            && left.accountUsername == right.accountUsername
            && left.mediaID == right.mediaID
            && left.kind == right.kind
            && left.qualityID == right.qualityID
            && left.audioTrackIndex == right.audioTrackIndex
            && left.videoOutput == right.videoOutput
            && left.downloadAudio == right.downloadAudio
    }
}

enum DownloadPreparedRequest {
    /// A manual retry is a replacement source, not a reconnect to an expired
    /// producer. Keep every selected output parameter and advance ownership.
    static func replacementPath(_ path: String) throws -> String {
        guard var components = URLComponents(string: path) else { throw RustyDLNAError.invalidResponse }
        var items = components.queryItems ?? []
        let oldGeneration = items.first(where: { $0.name == "request" })?.value.flatMap(UInt64.init)
        let oldSession = items.first(where: { $0.name == "session" })?.value.flatMap(UInt64.init)
        let session: UInt64
        let generation: UInt64
        if let oldGeneration, oldGeneration < UInt64.max, let oldSession, oldSession > 0 {
            session = oldSession
            generation = oldGeneration + 1
        } else {
            // Legacy requests without ownership and exhausted integer ranges
            // require a fresh session instead of wrapping a generation backward.
            session = UInt64.random(in: 1...UInt64.max)
            generation = 1
        }
        items.removeAll { $0.name == "request" || $0.name == "session" }
        items.append(URLQueryItem(name: "request", value: String(generation)))
        items.append(URLQueryItem(name: "session", value: String(session)))
        components.queryItems = items
        guard let value = components.string else { throw RustyDLNAError.invalidResponse }
        return value
    }
}

struct DownloadAttemptIdentity: Hashable, Sendable {
    let recordID: UUID
    let attemptID: UUID?

    init(_ metadata: DownloadTaskMetadata) {
        recordID = metadata.recordID
        attemptID = metadata.attemptID
    }
}
