import Foundation

struct MovieLibraryKey: Codable, Hashable, Sendable {
    let serverIdentity: String
    let accountUsername: String?
    let mediaID: String

    init(serverIdentity: String, accountUsername: String?, mediaID: String) {
        self.serverIdentity = ServerIdentity.canonical(serverIdentity)
        self.accountUsername = accountUsername
        self.mediaID = mediaID
    }

    init(connection: ServerConnection, mediaID: String) {
        self.init(serverIdentity: connection.serverIdentity,
                  accountUsername: connection.username, mediaID: mediaID)
    }
}

private struct CachedMovie: Codable, Sendable {
    var key: MovieLibraryKey
    let movie: MovieMetadata
    let savedAt: Date
}

private struct MovieCacheIndex: Codable {
    var schemaVersion = 1
    var movies: [CachedMovie]
}

private actor MovieCacheFiles {
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    func load() -> [CachedMovie] {
        let url = directory.appendingPathComponent("movies.json")
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(MovieCacheIndex.self, from: data),
              index.schemaVersion == 1 else { return [] }
        return index.movies.map { entry in
            var entry = entry
            entry.key = MovieLibraryKey(serverIdentity: entry.key.serverIdentity,
                                        accountUsername: entry.key.accountUsername,
                                        mediaID: entry.key.mediaID)
            return entry
        }
    }

    func save(_ entries: [CachedMovie]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let data = try JSONEncoder().encode(MovieCacheIndex(movies: entries))
        try data.write(to: directory.appendingPathComponent("movies.json"),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Cached presentation is available without querying the server. It never
/// substitutes for a source-aware playback or download request.
@MainActor
final class MovieMetadataCache: ObservableObject {
    @Published private(set) var isRestoring = true
    @Published private var entries: [MovieLibraryKey: CachedMovie] = [:]
    private let files: MovieCacheFiles
    private var restoreTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private let maximumEntries: Int

    init(directory: URL, maximumEntries: Int = 500) {
        files = MovieCacheFiles(directory: directory)
        self.maximumEntries = max(1, maximumEntries)
        restoreTask = Task { [weak self, files] in
            let stored = await files.load()
            guard let self else { return }
            // New metadata obtained while disk loading was in progress wins.
            for value in stored.sorted(by: { $0.savedAt < $1.savedAt }) {
                guard entries[value.key].map({ $0.savedAt > value.savedAt }) != true else { continue }
                entries[value.key] = value
            }
            trim()
            isRestoring = false
        }
    }

    func movie(for key: MovieLibraryKey) -> MovieMetadata? { entries[key]?.movie }

    func store(_ movie: MovieMetadata, connection: ServerConnection) {
        let key = MovieLibraryKey(connection: connection, mediaID: movie.mediaID)
        entries[key] = CachedMovie(key: key, movie: movie, savedAt: Date())
        trim()
        let previousSave = saveTask
        let restoration = restoreTask
        saveTask = Task { [weak self, files] in
            await previousSave?.value
            await restoration?.value
            guard let self else { return }
            // A metadata cache is replaceable; failed writes leave the prior
            // atomic cache and never affect completed offline packages.
            try? await files.save(Array(entries.values))
        }
    }

    func waitUntilRestored() async { await restoreTask?.value }
    func waitForPendingWrites() async { await saveTask?.value }

    private func trim() {
        guard entries.count > maximumEntries else { return }
        let keep = entries.values.sorted {
            if $0.savedAt != $1.savedAt { return $0.savedAt > $1.savedAt }
            if $0.key.serverIdentity != $1.key.serverIdentity { return $0.key.serverIdentity < $1.key.serverIdentity }
            if $0.key.accountUsername != $1.key.accountUsername { return ($0.key.accountUsername ?? "") < ($1.key.accountUsername ?? "") }
            return $0.key.mediaID < $1.key.mediaID
        }.prefix(maximumEntries)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0) })
    }
}
