import Foundation

struct DownloadReceipt: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let metadata: DownloadTaskMetadata
    let resourceID: String
    let transferID: UUID?
    let directoryName: String
    let expectedByteCount: Int64?
    var assetInspection: DownloadAssetInspection? = nil
}

struct DownloadFileTransaction: Codable, Equatable, Sendable, Identifiable {
    enum Operation: String, Codable, Sendable { case install, delete }
    let id: UUID
    let operation: Operation
    let record: DownloadRecord
    let sourceName: String
    let destinationName: String
    var mediaReceiptDirectory: String? = nil
}

struct DownloadStorageSnapshot: Codable, Equatable, Sendable {
    var schemaVersion = 2
    var revision: UInt64 = 0
    var records: [DownloadRecord] = []
    var queue: [DownloadQueueEntry] = []
    var receipts: [DownloadReceipt] = []
    var transactions: [DownloadFileTransaction] = []
}

/// Small synchronous persistence boundary shared by the legacy facades and the
/// actor. Production callers use DownloadStorageCoordinator off the main actor.
final class DownloadStateStore: @unchecked Sendable {
    let rootDirectory: URL
    let fileManager: FileManager
    private let lock: NSRecursiveLock
    var stateURL: URL { rootDirectory.appendingPathComponent("state.json") }

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        lock = DownloadDiskLocks.forDirectory(rootDirectory)
    }

    func load() throws -> DownloadStorageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        try validateRoot()
        if fileManager.fileExists(atPath: stateURL.path) {
            guard try fileManager.attributesOfItem(atPath: stateURL.path)[.type] as? FileAttributeType == .typeRegular else {
                throw DownloadStoreError.invalidManifest
            }
            let data = try Data(contentsOf: stateURL)
            guard let snapshot = try? JSONDecoder().decode(DownloadStorageSnapshot.self, from: data),
                  snapshot.schemaVersion == 2,
                  Set(snapshot.queue.map(\.id)).count == snapshot.queue.count else {
                throw DownloadStoreError.invalidManifest
            }
            return snapshot
        }
        var snapshot = DownloadStorageSnapshot()
        let manifestURL = rootDirectory.appendingPathComponent("manifest.json")
        let queueURL = rootDirectory.appendingPathComponent("queue.json")
        let hasManifest = fileManager.fileExists(atPath: manifestURL.path)
        let hasQueue = fileManager.fileExists(atPath: queueURL.path)
        if hasManifest {
            guard try fileManager.attributesOfItem(atPath: manifestURL.path)[.type] as? FileAttributeType == .typeRegular else {
                throw DownloadStoreError.invalidManifest
            }
            let data = try Data(contentsOf: manifestURL)
            guard let manifest = try? JSONDecoder().decode(DownloadManifest.self, from: data),
                  manifest.schemaVersion == 1 else { throw DownloadStoreError.invalidManifest }
            snapshot.records = manifest.records.map { record in
                var canonical = record
                canonical.serverOrigin = ServerIdentity.canonical(record.serverOrigin)
                return canonical
            }
        }
        if hasQueue {
            guard try fileManager.attributesOfItem(atPath: queueURL.path)[.type] as? FileAttributeType == .typeRegular else {
                throw DownloadQueueError.invalidJournal
            }
            let data = try Data(contentsOf: queueURL)
            guard let journal = try? JSONDecoder().decode(DownloadQueueJournal.self, from: data),
                  journal.schemaVersion == 1,
                  Set(journal.entries.map(\.id)).count == journal.entries.count else { throw DownloadQueueError.invalidJournal }
            snapshot.queue = journal.entries.map { entry in
                var canonical = entry
                canonical.metadata.serverOrigin = ServerIdentity.canonical(entry.metadata.serverOrigin)
                // Old removed could mean success OR cancellation. Never infer
                // destructive intent from that ambiguous historical state.
                if canonical.state == .removed, snapshot.records.contains(where: { $0.id == entry.id }) {
                    canonical.state = .completed
                }
                return canonical
            }
        }
        if hasManifest || hasQueue {
            // Leave both old files intact as migration evidence and recovery
            // input. Only the new atomic snapshot is authoritative afterward.
            try write(snapshot)
        }
        return snapshot
    }

    @discardableResult
    func update(_ mutation: (inout DownloadStorageSnapshot) throws -> Void) throws -> DownloadStorageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = try load()
        try mutation(&snapshot)
        snapshot.revision &+= 1
        try write(snapshot)
        return snapshot
    }

    /// Explicit damaged-index recovery preserves the unreadable source for
    /// inspection and rebuilds only from app-owned, independently checked files.
    func replaceDamagedIndex(with snapshot: DownloadStorageSnapshot) throws -> DownloadStorageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        for name in ["state.json", "manifest.json", "queue.json"] {
            let source = rootDirectory.appendingPathComponent(name)
            if isRegularFile(source) {
                let backup = rootDirectory.appendingPathComponent("recovered-index-\(UUID().uuidString)-\(name)")
                try fileManager.copyItem(at: source, to: backup)
            }
        }
        try write(snapshot)
        return snapshot
    }

    func isRegularFile(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    private func write(_ snapshot: DownloadStorageSnapshot) throws {
        try validateRoot()
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        var root = rootDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: stateURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func validateRoot() throws {
        if let type = try? fileManager.attributesOfItem(atPath: rootDirectory.path)[.type] as? FileAttributeType,
           type != .typeDirectory { throw DownloadStoreError.invalidManifest }
    }
}

private enum DownloadDiskLocks {
    static let registryLock = NSLock()
    static var locks: [String: NSRecursiveLock] = [:]

    static func forDirectory(_ url: URL) -> NSRecursiveLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        let key = url.standardizedFileURL.path
        if let existing = locks[key] { return existing }
        let created = NSRecursiveLock()
        locks[key] = created
        return created
    }
}
