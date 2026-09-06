import Foundation

struct UserLibraryEntry: Codable, Equatable, Sendable {
    var key: MovieLibraryKey
    var movie: MovieMetadata?
    var progress: PlaybackProgress?
    var isFavorite = false
    var hiddenFromContinueWatching = false
    var lastStartedAt: Date?
    var lastCompletedAt: Date?
    var updatedAt: Date
}

struct ViewingHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var key: MovieLibraryKey
    var movie: MovieMetadata
    let source: PlaybackActivity.Source
    let startedAt: Date
    var lastPosition: Double
    var duration: Double
    var completedAt: Date?
}

enum UserLibraryFailure: LocalizedError {
    case unreadableIndex
    case unreadableLegacyProgress

    var errorDescription: String? {
        switch self {
        case .unreadableIndex:
            "Your saved library could not be read. Its file has been preserved. Try again after restoring storage access."
        case .unreadableLegacyProgress:
            "Your previous viewing progress could not be read. It has been preserved so it can be recovered."
        }
    }
}

private struct ViewingOwnership: Codable, Equatable, Sendable {
    var key: MovieLibraryKey
    var viewingID: UUID
    var retired: [UUID] = []
}

private struct UserLibraryState: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var revision: UInt64 = 0
    var entries: [UserLibraryEntry] = []
    var history: [ViewingHistoryEntry] = []
    var owners: [ViewingOwnership] = []

    mutating func apply(_ mutation: LibraryMutation, maximumHistory: Int, maximumEntries: Int) {
        switch mutation {
        case .favorite(let favorite, let movie, let key, let date):
            var entry = entry(for: key, date: date)
            entry.movie = movie ?? entry.movie
            entry.isFavorite = favorite
            entry.updatedAt = date
            replace(entry)
        case .hide(let key, let date):
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return }
            entries[index].hiddenFromContinueWatching = true
            entries[index].updatedAt = date
        case .metadata(let movie, let key, let date):
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return }
            entries[index].movie = movie
            entries[index].updatedAt = date
            for index in history.indices where history[index].key == key { history[index].movie = movie }
        case .activity(let activity):
            apply(activity)
        }
        history.sort { $0.startedAt > $1.startedAt }
        if history.count > maximumHistory { history.removeLast(history.count - maximumHistory) }
        // Favorites are deliberate user data. Only the replaceable/non-favorite
        // portion is bounded; one heavily used account cannot erase favorites.
        let keep = Set(entries.filter { !$0.isFavorite }.sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maximumEntries).map(\.key))
        entries.removeAll { !$0.isFavorite && !keep.contains($0.key) }
        let keys = Set(entries.map(\.key))
        owners.removeAll { !keys.contains($0.key) }
    }

    private mutating func apply(_ activity: PlaybackActivity) {
        guard activity.movie.mediaID == activity.key.mediaID else { return }
        var owner = owners.first(where: { $0.key == activity.key })
            ?? ViewingOwnership(key: activity.key, viewingID: activity.viewingID)
        var entry = entry(for: activity.key, date: activity.occurredAt)

        switch activity.event {
        case .startedOver, .started:
            guard !owner.retired.contains(activity.viewingID) else { return }
            if owner.viewingID != activity.viewingID {
                owner.retired.append(owner.viewingID)
                if owner.retired.count > 64 { owner.retired.removeFirst(owner.retired.count - 64) }
                owner.viewingID = activity.viewingID
            }
        case .progress, .completed:
            guard owner.viewingID == activity.viewingID,
                  history.contains(where: { $0.id == activity.viewingID && $0.key == activity.key }) else { return }
        }

        switch activity.event {
        case .startedOver:
            entry.progress = nil
            entry.hiddenFromContinueWatching = false
        case .started(let position, let duration):
            guard valid(position: position, duration: duration) else { return }
            guard !history.contains(where: { $0.id == activity.viewingID && $0.completedAt != nil }) else { return }
            if !history.contains(where: { $0.id == activity.viewingID }) {
                history.append(ViewingHistoryEntry(id: activity.viewingID, key: activity.key,
                    movie: activity.movie, source: activity.source, startedAt: activity.occurredAt,
                    lastPosition: position, duration: duration))
                entry.lastStartedAt = activity.occurredAt
                entry.hiddenFromContinueWatching = false
            }
            updateProgress(&entry, activity: activity, position: position, duration: duration)
        case .progress(let position, let duration):
            guard valid(position: position, duration: duration) else { return }
            guard let index = history.firstIndex(where: { $0.id == activity.viewingID }),
                  history[index].completedAt == nil else { return }
            updateProgress(&entry, activity: activity, position: position, duration: duration)
        case .completed(let position, let duration):
            guard valid(position: position, duration: duration) else { return }
            updateProgress(&entry, activity: activity, position: position, duration: duration)
            // Reaching the real end is distinct from merely entering the
            // near-end resume exclusion window.
            entry.progress = nil
            entry.lastCompletedAt = activity.occurredAt
            if let index = history.firstIndex(where: { $0.id == activity.viewingID }) {
                history[index].completedAt = activity.occurredAt
            }
        }
        entry.movie = activity.movie
        entry.updatedAt = activity.occurredAt
        replace(entry)
        owners.removeAll { $0.key == activity.key }
        owners.append(owner)
    }

    private func valid(position: Double, duration: Double) -> Bool {
        position.isFinite && position >= 0 && duration.isFinite && duration >= 0
    }

    private mutating func updateProgress(_ entry: inout UserLibraryEntry, activity: PlaybackActivity,
                                         position: Double, duration: Double) {
        if duration > 0 {
            entry.progress = PlaybackProgress(serverOrigin: activity.key.serverIdentity,
                mediaID: activity.key.mediaID, position: min(position, duration), duration: duration,
                updatedAt: activity.occurredAt, accountUsername: activity.key.accountUsername)
        }
        if let index = history.firstIndex(where: { $0.id == activity.viewingID }) {
            history[index].lastPosition = duration > 0 ? min(position, duration) : position
            history[index].duration = duration
        }
    }

    private func entry(for key: MovieLibraryKey, date: Date) -> UserLibraryEntry {
        entries.first(where: { $0.key == key }) ?? UserLibraryEntry(key: key, updatedAt: date)
    }

    private mutating func replace(_ entry: UserLibraryEntry) {
        entries.removeAll { $0.key == entry.key }
        entries.append(entry)
    }
}

private enum LibraryMutation: Sendable {
    case favorite(Bool, MovieMetadata?, MovieLibraryKey, Date)
    case hide(MovieLibraryKey, Date)
    case metadata(MovieMetadata, MovieLibraryKey, Date)
    case activity(PlaybackActivity)
}

/// All decoding, migration and disk writes run on this actor. A mutation is
/// applied to the last successfully written state, never a stale UI snapshot.
private actor UserLibraryFiles {
    private let directory: URL
    private let fileManager: FileManager
    private let legacy: PlaybackProgressStore
    private let maximumHistory: Int
    private let maximumEntries: Int
    private var state: UserLibraryState?

    init(directory: URL, fileManager: FileManager, legacy: PlaybackProgressStore,
         maximumHistory: Int, maximumEntries: Int) {
        self.directory = directory
        self.fileManager = fileManager
        self.legacy = legacy
        self.maximumHistory = maximumHistory
        self.maximumEntries = maximumEntries
    }

    func load() throws -> UserLibraryState {
        if let state { return state }
        let url = directory.appendingPathComponent("library.json")
        let loaded: UserLibraryState
        if fileManager.fileExists(atPath: url.path) {
            // Read errors remain storage errors. An unreadable existing file is
            // never mistaken for an absent index eligible for legacy import.
            let data = try Data(contentsOf: url)
            guard var decoded = try? JSONDecoder().decode(UserLibraryState.self, from: data),
                  decoded.schemaVersion == 1 else { throw UserLibraryFailure.unreadableIndex }
            decoded.entries = canonicalEntries(decoded.entries)
            for index in decoded.history.indices { decoded.history[index].key = canonical(decoded.history[index].key) }
            for index in decoded.owners.indices { decoded.owners[index].key = canonical(decoded.owners[index].key) }
            loaded = decoded
        } else {
            var migrated = UserLibraryState()
            migrated.entries = try legacy.progressForMigration().map { progress in
                let key = MovieLibraryKey(serverIdentity: progress.serverOrigin,
                    accountUsername: progress.accountUsername, mediaID: progress.mediaID)
                return UserLibraryEntry(key: key, progress: progress, updatedAt: progress.updatedAt)
            }
            migrated.entries = canonicalEntries(migrated.entries)
            // Even an empty import is recorded once. Start Over in the new
            // store must not be undone by reimporting untouched old defaults.
            try save(migrated)
            loaded = migrated
        }
        state = loaded
        return loaded
    }

    func apply(_ mutations: [LibraryMutation]) throws -> UserLibraryState {
        var next = try load()
        for mutation in mutations {
            next.apply(mutation, maximumHistory: maximumHistory, maximumEntries: maximumEntries)
        }
        next.revision += 1
        try save(next)
        state = next
        return next
    }

    private func save(_ state: UserLibraryState) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let bytes = try JSONEncoder().encode(state)
        try bytes.write(to: directory.appendingPathComponent("library.json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func canonical(_ key: MovieLibraryKey) -> MovieLibraryKey {
        MovieLibraryKey(serverIdentity: key.serverIdentity, accountUsername: key.accountUsername, mediaID: key.mediaID)
    }

    private func canonicalEntries(_ entries: [UserLibraryEntry]) -> [UserLibraryEntry] {
        var result: [MovieLibraryKey: UserLibraryEntry] = [:]
        for var entry in entries.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            entry.key = canonical(entry.key)
            entry.progress?.serverOrigin = entry.key.serverIdentity
            if let previous = result[entry.key] {
                entry.isFavorite = entry.isFavorite || previous.isFavorite
                entry.movie = entry.movie ?? previous.movie
            }
            result[entry.key] = entry
        }
        return Array(result.values)
    }
}

@MainActor
final class UserLibraryStore: ObservableObject, PlaybackActivityStore {
    @Published private(set) var entries: [MovieLibraryKey: UserLibraryEntry] = [:]
    @Published private(set) var history: [ViewingHistoryEntry] = []
    @Published private(set) var isRestoring = true
    @Published private(set) var persistenceError: Error?

    private struct PendingMutation {
        let id = UUID()
        let mutation: LibraryMutation
        var completion: CheckedContinuation<Void, Error>?
    }
    private let files: UserLibraryFiles
    private let maximumHistory: Int
    private let maximumEntries: Int
    private var durable = UserLibraryState()
    private var projected = UserLibraryState()
    private var pending: [PendingMutation] = []
    private var restoreTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(directory: URL, legacyProgressStore: PlaybackProgressStore = PlaybackProgressStore(),
         fileManager: FileManager = .default, maximumHistory: Int = 500, maximumEntries: Int = 500) {
        self.maximumHistory = max(1, maximumHistory)
        self.maximumEntries = max(1, maximumEntries)
        files = UserLibraryFiles(directory: directory, fileManager: fileManager, legacy: legacyProgressStore,
            maximumHistory: max(1, maximumHistory), maximumEntries: max(1, maximumEntries))
        restoreTask = Task { [weak self, files] in
            do {
                let state = try await files.load()
                guard let self else { return }
                durable = state
                persistenceError = nil
            } catch {
                self?.persistenceError = error
            }
            guard let self else { return }
            isRestoring = false
            project()
        }
    }

    func entry(for key: MovieLibraryKey) -> UserLibraryEntry? { entries[key] }
    func isFavorite(for key: MovieLibraryKey) -> Bool { entries[key]?.isFavorite == true }

    func resumePosition(for key: MovieLibraryKey) -> Double? {
        guard let progress = entries[key]?.progress else { return nil }
        return ResumePolicy.resumePosition(position: progress.position, duration: progress.duration)
    }

    func setFavorite(_ favorite: Bool, movie: MovieMetadata?, for key: MovieLibraryKey) {
        guard movie == nil || movie?.mediaID == key.mediaID else { return }
        if !isRestoring, !favorite, entries[key] == nil { return }
        if !isRestoring, let entry = entries[key], entry.isFavorite == favorite,
           movie == nil || entry.movie == movie { return }
        enqueue(.favorite(favorite, movie, key, Date()))
    }

    func toggleFavorite(key: MovieLibraryKey, movie: MovieMetadata) {
        setFavorite(!isFavorite(for: key), movie: movie, for: key)
    }

    func removeFromContinueWatching(for key: MovieLibraryKey) { enqueue(.hide(key, Date())) }
    func upsertMetadata(_ movie: MovieMetadata, for key: MovieLibraryKey) {
        guard movie.mediaID == key.mediaID else { return }
        guard isRestoring || (entries[key] != nil && entries[key]?.movie != movie) else { return }
        enqueue(.metadata(movie, key, Date()))
    }
    func record(_ activity: PlaybackActivity) { enqueue(.activity(activity)) }

    func commit(_ activity: PlaybackActivity) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(PendingMutation(mutation: .activity(activity), completion: continuation))
            project()
            scheduleSave()
        }
    }

    func waitUntilRestored() async { await restoreTask?.value }

    func flush() async throws {
        await waitUntilRestored()
        if pending.isEmpty, persistenceError != nil {
            do {
                let reloaded = try await files.load()
                if reloaded.revision >= durable.revision { durable = reloaded }
                persistenceError = nil
                project()
            } catch {
                persistenceError = error
                throw error
            }
        }
        scheduleSave()
        await saveTask?.value
        if let persistenceError { throw persistenceError }
    }

    private func enqueue(_ mutation: LibraryMutation) {
        if !isRestoring {
            var candidate = projected
            candidate.apply(mutation, maximumHistory: maximumHistory, maximumEntries: maximumEntries)
            guard candidate != projected else { return }
        }
        pending.append(PendingMutation(mutation: mutation))
        project()
        scheduleSave()
    }

    private func project() {
        var projected = durable
        for operation in pending {
            projected.apply(operation.mutation, maximumHistory: maximumHistory, maximumEntries: maximumEntries)
        }
        entries = Dictionary(uniqueKeysWithValues: projected.entries.map { ($0.key, $0) })
        history = projected.history
        self.projected = projected
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            guard let self else { return }
            await waitUntilRestored()
            await savePending()
            saveTask = nil
        }
    }

    private func savePending() async {
        while !pending.isEmpty {
            // A required transition forms its own boundary. Later actions are
            // replayed against its committed result or against the prior state
            // if it fails; no precomputed snapshot can leak tentative progress.
            let count = pending.firstIndex(where: { $0.completion != nil }).map { $0 + 1 } ?? pending.count
            let batch = Array(pending.prefix(count))
            let ids = Set(batch.map(\.id))
            do {
                durable = try await files.apply(batch.map(\.mutation))
                pending.removeAll { ids.contains($0.id) }
                persistenceError = nil
                project()
                for operation in batch { operation.completion?.resume() }
            } catch {
                persistenceError = error
                // Roll back only required intents. Ordinary edits remain
                // visibly dirty for a later flush; every awaiting caller ends.
                let required = pending.filter { $0.completion != nil }
                pending.removeAll { $0.completion != nil }
                project()
                for operation in required { operation.completion?.resume(throwing: error) }
                return
            }
        }
    }
}
