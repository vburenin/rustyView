import Foundation

enum SavedCollection: String, CaseIterable, Identifiable {
    case continueWatching = "continue", favorites, history
    var id: String { rawValue }
    var title: String {
        switch self { case .continueWatching: "Continue Watching"; case .favorites: "Favorites"; case .history: "History" }
    }
    var icon: String {
        switch self { case .continueWatching: "play.circle"; case .favorites: "heart"; case .history: "clock" }
    }
}

extension AppModel {
    func savedHistory(offlineOnly: Bool = false) -> [ViewingHistoryEntry] {
        var seen = Set<MovieLibraryKey>()
        return userLibrary.history.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString > $1.id.uuidString
        }.filter { viewing in
            let key = MovieLibraryKey(serverIdentity: viewing.key.serverIdentity,
                                      accountUsername: viewing.key.accountUsername,
                                      mediaID: viewing.key.mediaID)
            guard !offlineOnly || bestReadyRecord(for: key) != nil else { return false }
            return seen.insert(key).inserted
        }
    }

    func savedEntries(_ collection: SavedCollection, offlineOnly: Bool = false) -> [UserLibraryEntry] {
        userLibrary.entries.values.filter { entry in
            if offlineOnly && bestReadyRecord(for: entry.key) == nil { return false }
            switch collection {
            case .continueWatching:
                return !entry.hiddenFromContinueWatching && savedResumePosition(for: entry.key) != nil
                    && (owns(entry.key) || bestReadyRecord(for: entry.key) != nil)
            case .favorites: return entry.isFavorite
            case .history: return entry.lastStartedAt != nil
            }
        }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.key.mediaID < $1.key.mediaID
        }
    }

    func savedResumePosition(for key: MovieLibraryKey) -> Double? {
        if let record = bestReadyRecord(for: key) { return player.resumePosition(for: record) }
        return userLibrary.resumePosition(for: key)
    }

    func savedDuration(for key: MovieLibraryKey, fallback: Double?) -> Double? {
        bestReadyRecord(for: key)?.assetInspection?.durationSeconds ?? fallback ?? userLibrary.entry(for: key)?.progress?.duration
    }

    func timeRemaining(for key: MovieLibraryKey, duration: Double?) -> String? {
        guard let position = savedResumePosition(for: key),
              let duration = savedDuration(for: key, fallback: duration),
              duration.isFinite, duration > position else { return nil }
        return "\(max(1, Int(ceil((duration - position) / 60)))) min left"
    }

    func timeRemaining(for record: DownloadRecord) -> String? {
        guard let position = player.resumePosition(for: record),
              let duration = record.assetInspection?.durationSeconds ?? record.movieMetadata.durationSeconds,
              duration > position else { return nil }
        return "\(max(1, Int(ceil((duration - position) / 60)))) min left"
    }
}
