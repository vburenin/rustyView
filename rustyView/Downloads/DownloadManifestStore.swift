import Foundation

enum DownloadStoreError: LocalizedError {
    case invalidManifest
    case missingTemporaryFile
    case emptyDownload
    case incompleteDownload
    case incompatibleDownload
    case invalidDownloadedFile
    case conflictingDownload

    var errorDescription: String? {
        switch self {
        case .invalidManifest: "The offline library index is damaged."
        case .missingTemporaryFile: "The downloaded file disappeared before it could be saved."
        case .emptyDownload: "The server returned an empty video file."
        case .incompleteDownload: "The downloaded file is incomplete. Please download it again."
        case .incompatibleDownload: "The downloaded copy could not be verified for offline playback. Please try downloading a compatible copy again."
        case .invalidDownloadedFile: "The download did not contain a regular media file."
        case .conflictingDownload: "A different stored file already owns this download. Remove that queue entry and start a new download."
        }
    }
}

final class DownloadManifestStore: @unchecked Sendable {
    let rootDirectory: URL
    private let fileManager: FileManager
    private let lock = NSRecursiveLock()
    var stateStore: DownloadStateStore { DownloadStateStore(rootDirectory: rootDirectory, fileManager: fileManager) }

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootDirectory = applicationSupport.appendingPathComponent("OfflineMedia", isDirectory: true)
        }
    }

    func load() throws -> DownloadManifest {
        lock.lock()
        defer { lock.unlock() }
        return DownloadManifest(records: try stateStore.load().records)
    }

    func loadValidated() throws -> DownloadManifest {
        lock.lock()
        defer { lock.unlock() }
        var manifest = try load()
        let originals = Set(manifest.records)
        var replacements: [DownloadRecord: DownloadRecord] = [:]
        var validated: [DownloadRecord] = []
        for var record in manifest.records.sorted(by: { $0.completedAt > $1.completedAt }) {
            let original = record
            guard record.fileName == safeFileName(record.fileName), record.byteCount > 0,
                  record.packageDirectoryName.map(OfflinePackagePath.isSafeLeaf) != false,
                  record.packageDirectoryName == nil || packageURL(for: record) != nil else {
                continue
            }
            let url = localURL(for: record)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value else {
                continue
            }
            if size == record.byteCount {
                record.packageIssue = nil
                if let inspection = record.assetInspection,
                   inspection.fileModificationDate != attributes[.modificationDate] as? Date {
                    record.assetInspection = nil
                }
                if record.localCaptions?.contains(where: { captionURL(for: record, caption: $0) == nil }) == true {
                    record.packageIssue = "A saved subtitle file is missing. Download a new compatible copy to restore its subtitles."
                }
                if record.artworkPath != nil, artworkURL(for: record) == nil {
                    record.artworkPath = nil
                    record.artworkFailure = "Saved artwork is unavailable."
                }
                if let package = packageURL(for: record) {
                    record.packageStorageBytes = try filesSize(in: package)
                }
                validated.append(record)
                replacements[original] = record
            } else {
                record.packageIssue = "The saved media file has changed or is incomplete. Download a new copy to watch reliably."
                record.assetInspection = nil
                record.packageStorageBytes = size
                validated.append(record)
                replacements[original] = record
            }
        }
        guard validated != manifest.records else { return manifest }
        // File validation runs outside the shared index lock. Merge only records
        // still equal to the inspected inputs; an actor deletion or replacement
        // that committed meanwhile owns the newer state.
        let committed = try stateStore.update { snapshot in
            snapshot.records = snapshot.records.compactMap { current in
                originals.contains(current) ? replacements[current] : current
            }.sorted { $0.completedAt > $1.completedAt }
        }
        manifest.records = committed.records
        return manifest
    }

    /// Reinspect legacy records off the main actor. Commit only if the same record
    /// still exists, so deletion or replacement during inspection cannot restore it.
    func revalidatePendingAssets() throws -> DownloadManifest {
        let pending = try loadValidated().records.filter { $0.assetInspection == nil }
        for record in pending {
            let inspection = DownloadAssetInspector.inspect(localURL(for: record))
            try updateInspection(inspection, for: record)
        }
        return try loadValidated()
    }

    private func updateInspection(_ inspection: DownloadAssetInspection, for record: DownloadRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try stateStore.update { snapshot in
            guard let index = snapshot.records.firstIndex(of: record) else { return }
            snapshot.records[index].assetInspection = inspection
        }
    }

    func install(
        temporaryURL: URL,
        metadata: DownloadTaskMetadata,
        expectedByteCount: Int64? = nil,
        inspection suppliedInspection: DownloadAssetInspection? = nil
    ) throws -> DownloadRecord {
        let inspection = try suppliedInspection ?? inspectDownload(
            temporaryURL: temporaryURL, metadata: metadata, expectedByteCount: expectedByteCount
        )
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: temporaryURL.path) else {
            throw DownloadStoreError.missingTemporaryFile
        }
        let sourceAttributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
        guard sourceAttributes[.type] as? FileAttributeType == .typeRegular else {
            throw DownloadStoreError.invalidDownloadedFile
        }
        if let existing = try loadValidated().records.first(where: { $0.id == metadata.recordID }) {
            guard ServerIdentity.canonical(existing.serverOrigin) == ServerIdentity.canonical(metadata.serverOrigin),
                  existing.accountUsername == metadata.accountUsername,
                  existing.mediaID == metadata.mediaID, existing.kind == metadata.kind,
                  existing.qualityID == metadata.qualityID,
                  existing.audioTrackIndex == metadata.audioTrackIndex else {
                throw DownloadStoreError.conflictingDownload
            }
            // A duplicate background completion belongs to the already committed
            // logical download. Keep its first installed bytes and stable identity.
            if temporaryURL.standardizedFileURL != localURL(for: existing).standardizedFileURL {
                try? fileManager.removeItem(at: temporaryURL)
            }
            return existing
        }
        try prepareRoot()
        let safeExtension = String(metadata.fileExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(16))
        var fileName = "offline-\(metadata.recordID.uuidString.lowercased()).\(safeExtension.isEmpty ? "media" : safeExtension)"
        if fileManager.fileExists(atPath: rootDirectory.appendingPathComponent(fileName).path) {
            fileName = "offline-\(UUID().uuidString.lowercased()).\(safeExtension.isEmpty ? "media" : safeExtension)"
        }
        let destination = rootDirectory.appendingPathComponent(fileName)
        try fileManager.moveItem(at: temporaryURL, to: destination)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDestination = destination
        try? mutableDestination.setResourceValues(values)
        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0 else {
            try? fileManager.removeItem(at: destination)
            throw DownloadStoreError.emptyDownload
        }
        if let expectedByteCount, expectedByteCount > 0, byteCount != expectedByteCount {
            try? fileManager.removeItem(at: destination)
            throw DownloadStoreError.incompleteDownload
        }
        if metadata.kind == .compatible,
           inspection.integrity != .verified || inspection.playability != .playable {
            try? fileManager.removeItem(at: destination)
            throw DownloadStoreError.incompatibleDownload
        }
        let record = DownloadRecord(
            id: metadata.recordID,
            serverOrigin: ServerIdentity.canonical(metadata.serverOrigin),
            mediaID: metadata.mediaID,
            title: metadata.title,
            kind: metadata.kind,
            fileName: fileName,
            byteCount: byteCount,
            completedAt: Date(),
            durationSeconds: metadata.durationSeconds,
            resolution: metadata.resolution,
            artworkPath: nil,
            qualityID: metadata.qualityID,
            qualityLabel: metadata.qualityLabel,
            audioTrackIndex: metadata.audioTrackIndex,
            audioTrackLabel: metadata.audioTrackLabel,
            accountUsername: metadata.accountUsername,
            assetInspection: inspection
        )
        do {
            // A compatible copy must not destroy an intentionally retained original,
            // another account's copy, or a legacy unassigned copy. Keeping distinct
            // stored records also makes an interrupted replacement recoverable.
            _ = try stateStore.update { snapshot in
                guard !snapshot.records.contains(where: { $0.id == record.id }) else { throw DownloadStoreError.conflictingDownload }
                snapshot.records.append(record)
            }
            return record
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    /// Run before acquiring an installation/cancellation lock. The URLSession
    /// callback keeps its temporary URL alive throughout this inspection.
    func inspectDownload(
        temporaryURL: URL,
        metadata: DownloadTaskMetadata,
        expectedByteCount: Int64? = nil
    ) throws -> DownloadAssetInspection {
        guard fileManager.fileExists(atPath: temporaryURL.path) else {
            throw DownloadStoreError.missingTemporaryFile
        }
        let attributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw DownloadStoreError.invalidDownloadedFile
        }
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0 else { throw DownloadStoreError.emptyDownload }
        if let expectedByteCount, expectedByteCount > 0, byteCount != expectedByteCount {
            throw DownloadStoreError.incompleteDownload
        }
        let inspection = DownloadAssetInspector.inspect(
            temporaryURL,
            fileExtension: metadata.kind == .compatible ? "mp4" : metadata.fileExtension
        )
        guard metadata.kind == .original || (inspection.integrity == .verified && inspection.playability == .playable) else {
            throw DownloadStoreError.incompatibleDownload
        }
        return inspection
    }

    func delete(_ record: DownloadRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        let manifest = try load()
        guard let current = manifest.records.first(where: { $0.id == record.id }) else { return }
        let fileURL = current.packageDirectoryName == nil ? localURL(for: current) : resolvedPackageDirectory(for: current)
        let pendingURL = rootDirectory.appendingPathComponent("deleting-\(UUID().uuidString)")
        let sharedFile = manifest.records.contains {
            $0.id != current.id && ($0.packageDirectoryName ?? $0.fileName) == (current.packageDirectoryName ?? current.fileName)
        }
        let hasFile = current.fileName == safeFileName(current.fileName)
            && current.packageDirectoryName.map(OfflinePackagePath.isSafeLeaf) != false
            && !sharedFile && fileManager.fileExists(atPath: fileURL.path)
        if hasFile {
            try fileManager.moveItem(at: fileURL, to: pendingURL)
        }
        do {
            _ = try stateStore.update { $0.records.removeAll { $0.id == record.id } }
        } catch {
            if hasFile { try? fileManager.moveItem(at: pendingURL, to: fileURL) }
            throw error
        }
        if hasFile { try? fileManager.removeItem(at: pendingURL) }
    }

    func localURL(for record: DownloadRecord) -> URL {
        let directory = resolvedPackageDirectory(for: record)
        return directory.appendingPathComponent(safeFileName(record.fileName))
    }

    /// UI snapshots have already passed store validation. These constructors
    /// keep file-system work off SwiftUI's main-actor rendering path.
    func cachedArtworkURL(for record: DownloadRecord) -> URL? {
        guard let name = record.artworkPath, OfflinePackagePath.isSafeLeaf(name) else { return nil }
        return resolvedPackageDirectory(for: record).appendingPathComponent(name)
    }

    func cachedCaptionURL(for record: DownloadRecord, caption: OfflineCaption) -> URL? {
        guard record.packageIssue == nil, record.localCaptions?.contains(caption) == true,
              OfflinePackagePath.isSafeLeaf(caption.fileName) else { return nil }
        return resolvedPackageDirectory(for: record).appendingPathComponent(caption.fileName)
    }

    private func resolvedPackageDirectory(for record: DownloadRecord) -> URL {
        guard let name = record.packageDirectoryName else { return rootDirectory }
        guard OfflinePackagePath.isSafeLeaf(name) else { return rootDirectory.appendingPathComponent("invalid-package") }
        return rootDirectory.appendingPathComponent(name, isDirectory: true)
    }

    func artworkURL(for record: DownloadRecord) -> URL? {
        guard let name = record.artworkPath else { return nil }
        return supplementalURL(for: record, fileName: name)
    }

    func captionURL(for record: DownloadRecord, caption: OfflineCaption) -> URL? {
        guard record.localCaptions?.contains(caption) == true else { return nil }
        return supplementalURL(for: record, fileName: caption.fileName)
    }

    func packageURL(for record: DownloadRecord) -> URL? {
        guard let name = record.packageDirectoryName, OfflinePackagePath.isSafeLeaf(name) else { return nil }
        let url = rootDirectory.appendingPathComponent(name, isDirectory: true)
        guard (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory else { return nil }
        return url
    }

    private func supplementalURL(for record: DownloadRecord, fileName: String) -> URL? {
        guard OfflinePackagePath.isSafeLeaf(fileName) else { return nil }
        guard record.packageDirectoryName == nil || packageURL(for: record) != nil else { return nil }
        let directory = packageURL(for: record) ?? rootDirectory
        let url = directory.appendingPathComponent(fileName)
        guard stateStore.isRegularFile(url) else { return nil }
        return url
    }

    private func filesSize(in directory: URL) throws -> Int64 {
        try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).reduce(0) { total, file in
            let attributes = try fileManager.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { return total }
            return total + ((attributes[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    private func safeFileName(_ value: String) -> String {
        OfflinePackagePath.isSafeLeaf(value) ? value : "invalid-download-name"
    }

    private func prepareRoot() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = rootDirectory
        try? mutableRoot.setResourceValues(values)
    }

}
