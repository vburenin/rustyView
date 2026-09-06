import Foundation

/// A collection row represents a movie. Renditions and their transfer identities
/// remain intact for playback, recovery, and deletion inside that row's actions.
struct DownloadMovieGroup: Identifiable, Equatable {
    let key: MovieLibraryKey
    var records: [DownloadRecord]
    var transfers: [ActiveDownload]

    var id: MovieLibraryKey { key }
    var copyCount: Int { records.count + transfers.count }
    var readyRecord: DownloadRecord? { records.first(where: \.isReadyToWatch) }
    var representativeRecord: DownloadRecord? { readyRecord ?? records.first }
    var representativeTransfer: ActiveDownload? { transfers.first }
    var title: String { representativeRecord?.displayTitle ?? representativeTransfer?.displayTitle ?? "Downloaded movie" }
    var completedAt: Date { records.map(\.completedAt).max() ?? .distantPast }
    var needsAttention: Bool {
        readyRecord == nil && (transfers.isEmpty || transfers.allSatisfy(Self.needsAttention))
    }

    static func collect(records: [DownloadRecord], transfers: [ActiveDownload]) -> [DownloadMovieGroup] {
        var groups: [MovieLibraryKey: DownloadMovieGroup] = [:]
        for record in records {
            let key = MovieLibraryKey(serverIdentity: record.serverOrigin, accountUsername: record.accountUsername, mediaID: record.mediaID)
            groups[key, default: DownloadMovieGroup(key: key, records: [], transfers: [])].records.append(record)
        }
        for transfer in transfers {
            let key = MovieLibraryKey(serverIdentity: transfer.serverOrigin, accountUsername: transfer.metadata.accountUsername, mediaID: transfer.mediaID)
            // A completed snapshot can reach the UI before its old active row
            // disappears. It is still the same copy, not a second rendition.
            if groups[key]?.records.contains(where: { $0.id == transfer.id }) == true { continue }
            groups[key, default: DownloadMovieGroup(key: key, records: [], transfers: [])].transfers.append(transfer)
        }
        return groups.values.map { group in
            var group = group
            group.records.sort {
                if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            group.transfers.sort {
                if needsAttention($0) != needsAttention($1) { return !needsAttention($0) }
                return $0.id.uuidString < $1.id.uuidString
            }
            return group
        }.sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
            if $0.key.serverIdentity != $1.key.serverIdentity { return $0.key.serverIdentity < $1.key.serverIdentity }
            if $0.key.accountUsername != $1.key.accountUsername {
                return ($0.key.accountUsername.map { "1" + $0 } ?? "0") < ($1.key.accountUsername.map { "1" + $0 } ?? "0")
            }
            return $0.key.mediaID < $1.key.mediaID
        }
    }

    private static func needsAttention(_ download: ActiveDownload) -> Bool {
        switch download.phase { case .failed, .paused, .waiting(.credentials): true; default: false }
    }
}
