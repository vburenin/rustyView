import Foundation

enum DownloadStoreError: LocalizedError {
    case invalidManifest
    case missingTemporaryFile
    case emptyDownload

    var errorDescription: String? {
        switch self {
        case .invalidManifest: "The offline library index is damaged."
        case .missingTemporaryFile: "The downloaded file disappeared before it could be saved."
        case .emptyDownload: "The server returned an empty video file."
        }
    }
}

final class DownloadManifestStore {
    let rootDirectory: URL
    private let fileManager: FileManager
    private var manifestURL: URL { rootDirectory.appendingPathComponent("manifest.json") }

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
        guard fileManager.fileExists(atPath: manifestURL.path) else { return DownloadManifest() }
        let data = try Data(contentsOf: manifestURL)
        guard let manifest = try? JSONDecoder().decode(DownloadManifest.self, from: data),
              manifest.schemaVersion == 1 else {
            throw DownloadStoreError.invalidManifest
        }
        return manifest
    }

    func loadValidated() throws -> DownloadManifest {
        var manifest = try load()
        var validated: [DownloadRecord] = []
        var retainedFiles: [DownloadRecordIdentity: String] = [:]
        for record in manifest.records.sorted(by: { $0.completedAt > $1.completedAt }) {
            guard record.fileName == safeFileName(record.fileName), record.byteCount > 0 else {
                continue
            }
            let url = localURL(for: record)
            let identity = DownloadRecordIdentity(serverOrigin: record.serverOrigin, mediaID: record.mediaID)
            if let retainedFile = retainedFiles[identity] {
                if retainedFile != record.fileName { try? fileManager.removeItem(at: url) }
                continue
            }
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value else {
                continue
            }
            if size == record.byteCount {
                retainedFiles[identity] = record.fileName
                validated.append(record)
            } else {
                try? fileManager.removeItem(at: url)
            }
        }
        guard validated.count != manifest.records.count else { return manifest }
        manifest.records = validated
        try save(manifest)
        return manifest
    }

    func install(temporaryURL: URL, metadata: DownloadTaskMetadata) throws -> DownloadRecord {
        guard fileManager.fileExists(atPath: temporaryURL.path) else {
            throw DownloadStoreError.missingTemporaryFile
        }
        try prepareRoot()
        let safeExtension = metadata.fileExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        let fileName = "offline-\(metadata.recordID.uuidString.lowercased()).\(safeExtension.isEmpty ? "media" : safeExtension)"
        let destination = rootDirectory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
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
        let record = DownloadRecord(
            id: metadata.recordID,
            serverOrigin: metadata.serverOrigin,
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
            audioTrackLabel: metadata.audioTrackLabel
        )
        do {
            var manifest = try load()
            let replacedRecords = manifest.records.filter {
                $0.serverOrigin == record.serverOrigin && $0.mediaID == record.mediaID
            }
            manifest.records.removeAll {
                $0.serverOrigin == record.serverOrigin && $0.mediaID == record.mediaID
            }
            manifest.records.append(record)
            try save(manifest)
            for replaced in replacedRecords where replaced.fileName != record.fileName {
                try? fileManager.removeItem(at: localURL(for: replaced))
            }
            return record
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func delete(_ record: DownloadRecord) throws {
        var manifest = try load()
        let fileURL = localURL(for: record)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        manifest.records.removeAll { $0.id == record.id }
        try save(manifest)
    }

    func localURL(for record: DownloadRecord) -> URL {
        rootDirectory.appendingPathComponent(safeFileName(record.fileName))
    }

    private func safeFileName(_ value: String) -> String {
        let candidate = (value as NSString).lastPathComponent
        guard !candidate.isEmpty, candidate != ".", candidate != ".." else {
            return "invalid-download-name"
        }
        return candidate
    }

    private func prepareRoot() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = rootDirectory
        try? mutableRoot.setResourceValues(values)
    }

    private func save(_ manifest: DownloadManifest) throws {
        try prepareRoot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

private struct DownloadRecordIdentity: Hashable {
    let serverOrigin: String
    let mediaID: String
}
