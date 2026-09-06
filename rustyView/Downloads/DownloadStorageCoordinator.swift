import Foundation
import ImageIO

enum DownloadStorageBoundary: String, Sendable {
    case receiptWritten, mediaStaged, transactionWritten, packageMoved, indexCommitted, deleteMoved, deleteCommitted
}

enum DownloadStorageFailure: LocalizedError {
    case staleAttempt, invalidComponent, missingComponent, interrupted, recoveryNotNeeded
    var errorDescription: String? {
        switch self {
        case .staleAttempt: "This download attempt has been replaced."
        case .invalidComponent: "A downloaded subtitle or artwork file could not be verified."
        case .missingComponent: "The saved movie package is missing a required file. Retry the download to finish saving it."
        case .interrupted: "Storage processing was interrupted."
        case .recoveryNotNeeded: "The saved library index is readable. Retry loading your downloads instead of rebuilding it."
        }
    }
}

struct OfflineStorageInventoryItem: Identifiable, Sendable {
    let id: String
    let byteCount: Int64
    let recoverable: Bool
}

/// The product's file and queue owner. No file I/O or media inspection here is
/// main-actor isolated. Reentrant media inspection always rechecks ownership.
actor DownloadStorageCoordinator {
    nonisolated let store: DownloadManifestStore
    private let disk: DownloadStateStore
    private let files: FileManager
    private nonisolated let ingress: DownloadReceiptIngress
    private let checkpoint: (@Sendable (DownloadStorageBoundary) throws -> Void)?

    init(store: DownloadManifestStore, checkpoint: (@Sendable (DownloadStorageBoundary) throws -> Void)? = nil) {
        self.store = store
        disk = store.stateStore
        files = disk.fileManager
        self.checkpoint = checkpoint
        ingress = DownloadReceiptIngress(root: store.rootDirectory, files: disk.fileManager, checkpoint: checkpoint)
    }

    nonisolated func stageTemporaryFile(
        temporaryURL: URL, metadata: DownloadTaskMetadata, resourceID: String = "video",
        transferID: UUID? = nil, expectedByteCount: Int64? = nil
    ) throws -> DownloadReceipt {
        try ingress.stage(temporaryURL: temporaryURL, metadata: metadata, resourceID: resourceID,
                          transferID: transferID, expectedByteCount: expectedByteCount)
    }

    func snapshot() throws -> DownloadStorageSnapshot { try disk.load() }

    func restore() async throws -> DownloadStorageSnapshot {
        _ = try disk.load()
        try recoverTransactions()
        for receipt in try ingress.pending() {
            do { _ = try await receive(receipt) }
            catch {
                _ = try disk.update { snapshot in
                    guard let index = snapshot.queue.firstIndex(where: { $0.id == receipt.metadata.recordID }),
                          !snapshot.queue[index].state.isTerminal,
                          snapshot.queue[index].metadata.attemptID == receipt.metadata.attemptID else { return }
                    if let component = snapshot.queue[index].resources?.firstIndex(where: { $0.id == receipt.resourceID }) {
                        guard receipt.transferID == nil || snapshot.queue[index].resources?[component].transferID == receipt.transferID else { return }
                        snapshot.queue[index].resources?[component].state = .failed
                        snapshot.queue[index].resources?[component].reason = error.localizedDescription
                        snapshot.queue[index].resources?[component].failure = UserFacingError(error)
                        if snapshot.queue[index].resources?[component].resource.required == true {
                            snapshot.queue[index].state = .failed
                            snapshot.queue[index].reason = error.localizedDescription
                            snapshot.queue[index].failure = UserFacingError(error)
                        }
                    }
                }
                _ = try await finishAvailablePackage(recordID: receipt.metadata.recordID)
            }
        }
        let liveStages = Set(try disk.load().transactions.map(\.sourceName))
        for url in try children(store.rootDirectory) where url.lastPathComponent.hasPrefix("assembling-")
            && url.pathExtension == "package" && !liveStages.contains(url.lastPathComponent) {
            let identifier = url.deletingPathExtension().lastPathComponent.dropFirst("assembling-".count)
            if UUID(uuidString: String(identifier)) != nil,
               (try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory {
                try files.removeItem(at: url)
            }
        }
        _ = try store.loadValidated()
        return try disk.load()
    }

    func enqueue(_ entry: DownloadQueueEntry) throws -> DownloadStorageSnapshot {
        try disk.update { snapshot in
            guard !snapshot.queue.contains(where: { $0.id == entry.id }) else { return }
            snapshot.queue.append(entry)
        }
    }

    func update(_ entry: DownloadQueueEntry, expectedAttemptID: UUID?) throws -> DownloadStorageSnapshot {
        try disk.update { snapshot in
            guard let index = snapshot.queue.firstIndex(where: { $0.id == entry.id }),
                  snapshot.queue[index].metadata.attemptID == expectedAttemptID,
                  !snapshot.queue[index].state.isTerminal else { return }
            var replacement = entry
            let existingResources = snapshot.queue[index].resources ?? []
            if var resources = replacement.resources {
                for resourceIndex in resources.indices {
                    if let delivered = existingResources.first(where: {
                        $0.id == resources[resourceIndex].id && $0.transferID == resources[resourceIndex].transferID && $0.state == .delivered
                    }) {
                        resources[resourceIndex] = delivered
                    }
                }
                replacement.resources = resources
            }
            snapshot.queue[index] = replacement
        }
    }

    func receive(_ original: DownloadReceipt) async throws -> DownloadStorageSnapshot {
        guard let payload = ingress.payloadURL(original), disk.isRegularFile(payload) else { throw DownloadStorageFailure.missingComponent }
        var receipt = original
        var current = try disk.load()
        if !current.queue.contains(where: { $0.id == receipt.metadata.recordID }) {
            let movie = receipt.metadata.movie ?? MovieMetadata(mediaID: receipt.metadata.mediaID, title: receipt.metadata.title,
                                                               durationSeconds: receipt.metadata.durationSeconds.map(Double.init), resolution: receipt.metadata.resolution)
            let plan = OfflinePackagePlan(metadata: receipt.metadata, movie: movie)
            var entry = DownloadQueueEntry(metadata: receipt.metadata)
            entry.packagePlan = plan
            entry.resources = plan.resources.map { resource in
                DownloadResourceDescriptor(resource: resource, transferID: resource.runtimeID == receipt.resourceID
                                           ? receipt.transferID ?? receipt.metadata.attemptID ?? receipt.metadata.recordID : UUID())
            }
            current = try enqueue(entry)
        }
        guard let entry = matchingEntry(receipt, in: current),
              let resource = resource(receipt.resourceID, in: entry) else {
            try ingress.remove(receipt)
            return current
        }
        guard validResources(entry.resources ?? []) else { throw DownloadStorageFailure.invalidComponent }
        let attributes = try files.attributesOfItem(atPath: payload.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw DownloadStoreError.emptyDownload }
        if let expected = receipt.expectedByteCount, expected > 0, expected != size { throw DownloadStoreError.incompleteDownload }
        if let limit = resource.sizeLimit, size > limit { throw DownloadStorageFailure.invalidComponent }
        switch resource.resource.kind {
        case .media:
            if receipt.assetInspection == nil {
                receipt.assetInspection = try await Task.detached(priority: .utility) { [store] in
                    try store.inspectDownload(temporaryURL: payload, metadata: original.metadata, expectedByteCount: original.expectedByteCount)
                }.value
            }
        case .caption:
            _ = try WebVTTParser.parse(Data(contentsOf: payload))
        case .artwork:
            guard let source = CGImageSourceCreateWithURL(payload as CFURL, nil), CGImageSourceGetCount(source) > 0,
                  CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary) != nil else {
                throw DownloadStorageFailure.invalidComponent
            }
        }
        current = try disk.load()
        guard matchingEntry(receipt, in: current) != nil else { try ingress.remove(receipt); return current }
        let savedReceipt = receipt
        _ = try disk.update { snapshot in
            guard let index = snapshot.queue.firstIndex(where: { $0.id == savedReceipt.metadata.recordID }) else { return }
            snapshot.receipts.removeAll { $0.id == savedReceipt.id }
            snapshot.receipts.append(savedReceipt)
            if let componentIndex = snapshot.queue[index].resources?.firstIndex(where: { $0.id == savedReceipt.resourceID }) {
                snapshot.queue[index].resources?[componentIndex].state = .delivered
                snapshot.queue[index].resources?[componentIndex].failure = nil
                snapshot.queue[index].resources?[componentIndex].reason = nil
                snapshot.queue[index].resources?[componentIndex].receivedBytes = size
                snapshot.queue[index].resources?[componentIndex].expectedBytes = size
                snapshot.queue[index].resources?[componentIndex].resumeReference = nil
            }
        }
        return try await finishAvailablePackage(recordID: receipt.metadata.recordID)
    }

    func finishAvailablePackage(recordID: UUID) async throws -> DownloadStorageSnapshot {
        try recoverTransactions()
        let snapshot = try disk.load()
        guard let entry = snapshot.queue.first(where: { $0.id == recordID }), !entry.state.isTerminal,
              entry.state != .paused, entry.state != .pausing, entry.state != .failed,
              let plan = entry.packagePlan, let resources = entry.resources,
              resources.allSatisfy({ $0.state == .delivered || (!$0.resource.required && $0.state == .failed) }),
              let video = resources.first(where: { $0.resource.kind == .media }),
              let videoReceipt = receipt(for: video, entry: entry, snapshot: snapshot),
              let videoURL = ingress.payloadURL(videoReceipt), disk.isRegularFile(videoURL),
              let inspection = videoReceipt.assetInspection else { return snapshot }
        guard validResources(resources) else { throw DownloadStorageFailure.invalidComponent }
        if let existing = snapshot.records.first(where: { $0.id == recordID }) {
            return try disk.update { state in
                if let index = state.queue.firstIndex(where: { $0.id == existing.id }) { state.queue[index].state = .completed }
            }
        }
        let transactionID = UUID()
        let stageName = "assembling-\(transactionID.uuidString.lowercased()).package"
        let destinationName = "offline-\(recordID.uuidString.lowercased())-\(transactionID.uuidString.lowercased()).package"
        let stage = store.rootDirectory.appendingPathComponent(stageName, isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: true)
        var captions: [OfflineCaption] = []
        var artwork: String?
        var artworkFailure: String?
        for component in resources where component.resource.kind != .media {
            if component.state == .failed, !component.resource.required {
                artworkFailure = component.reason ?? "Artwork could not be saved."
                continue
            }
            guard let delivered = receipt(for: component, entry: entry, snapshot: snapshot),
                  let source = ingress.payloadURL(delivered), disk.isRegularFile(source),
                  OfflinePackagePath.isSafeLeaf(component.resource.fileName) else { throw DownloadStorageFailure.missingComponent }
            try files.copyItem(at: source, to: stage.appendingPathComponent(component.resource.fileName))
            if let caption = component.resource.caption { captions.append(caption) }
            if component.resource.kind == .artwork { artwork = component.resource.fileName }
        }
        try JSONEncoder().encode(plan.movie).write(to: stage.appendingPathComponent("movie.json"), options: .atomic)
        let byteCount = (try files.attributesOfItem(atPath: videoURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        var record = DownloadRecord(
            id: recordID, serverOrigin: ServerIdentity.canonical(entry.metadata.serverOrigin), mediaID: entry.metadata.mediaID,
            title: entry.metadata.title, kind: entry.metadata.kind, fileName: video.resource.fileName,
            byteCount: byteCount, completedAt: Date(), durationSeconds: entry.metadata.durationSeconds,
            resolution: entry.metadata.resolution, artworkPath: artwork, qualityID: entry.metadata.qualityID,
            qualityLabel: entry.metadata.qualityLabel, audioTrackIndex: entry.metadata.audioTrackIndex,
            audioTrackLabel: entry.metadata.audioTrackLabel, accountUsername: entry.metadata.accountUsername,
            assetInspection: inspection, movie: plan.movie, packageDirectoryName: destinationName,
            localCaptions: captions, packageStorageBytes: nil, installedAttemptID: entry.metadata.attemptID,
            artworkFailure: artworkFailure
        )
        for _ in 0..<3 {
            try JSONEncoder().encode(record).write(to: stage.appendingPathComponent("record.json"), options: .atomic)
            record.packageStorageBytes = byteCount + (try directoryBytes(stage))
        }
        try JSONEncoder().encode(record).write(to: stage.appendingPathComponent("record.json"), options: .atomic)
        let transaction = DownloadFileTransaction(id: transactionID, operation: .install, record: record,
                                                 sourceName: stageName, destinationName: destinationName,
                                                 mediaReceiptDirectory: videoReceipt.directoryName)
        _ = try disk.update { $0.transactions.append(transaction) }
        try checkpoint?(.transactionWritten)
        try files.moveItem(at: videoURL, to: stage.appendingPathComponent(record.fileName))
        try files.moveItem(at: stage, to: store.rootDirectory.appendingPathComponent(destinationName))
        try checkpoint?(.packageMoved)
        let committed = try commit(transaction)
        try checkpoint?(.indexCommitted)
        try cleanCommitted(transaction, snapshot: committed)
        return try disk.load()
    }

    func cancel(recordID: UUID) throws -> DownloadStorageSnapshot {
        let before = try disk.load()
        guard before.queue.first(where: { $0.id == recordID })?.state != .completed else { return before }
        _ = try disk.update { snapshot in
            if let index = snapshot.queue.firstIndex(where: { $0.id == recordID }) { snapshot.queue[index].state = .cancelled }
        }
        try recoverTransactions()
        // Validation can fail before a receipt reaches the atomic index, and
        // the delegate can stage bytes before its actor operation starts.
        // The owned receipt files, not only the index, define cancellation's
        // cleanup set. The ingress lock also orders this scan with staging.
        try ingress.remove(recordID: recordID)
        return try disk.update { $0.receipts.removeAll { $0.metadata.recordID == recordID } }
    }

    func delete(recordID: UUID) throws -> DownloadStorageSnapshot {
        let current = try disk.load()
        guard let record = current.records.first(where: { $0.id == recordID }) else { return try cancel(recordID: recordID) }
        let sourceName = record.packageDirectoryName ?? record.fileName
        guard OfflinePackagePath.isSafeLeaf(sourceName) else { throw DownloadStoreError.invalidDownloadedFile }
        if current.records.contains(where: { $0.id != recordID && ($0.packageDirectoryName ?? $0.fileName) == sourceName }) {
            // Legacy indexes can contain overlapping references. Removing this
            // user's record must not remove bytes still owned by another copy.
            return try disk.update { snapshot in
                snapshot.records.removeAll { $0.id == recordID }
                if let index = snapshot.queue.firstIndex(where: { $0.id == recordID }) { snapshot.queue[index].state = .deleted }
                else { snapshot.queue.append(DownloadQueueEntry(metadata: metadata(for: record), state: .deleted)) }
            }
        }
        let transaction = DownloadFileTransaction(id: UUID(), operation: .delete, record: record,
                                                 sourceName: sourceName, destinationName: "deleting-\(UUID().uuidString.lowercased())")
        _ = try disk.update { $0.transactions.append(transaction) }
        try checkpoint?(.transactionWritten)
        let source = store.rootDirectory.appendingPathComponent(sourceName)
        let trash = store.rootDirectory.appendingPathComponent(transaction.destinationName)
        if files.fileExists(atPath: source.path) { try files.moveItem(at: source, to: trash) }
        try checkpoint?(.deleteMoved)
        do {
            _ = try disk.update { snapshot in
                snapshot.records.removeAll { $0.id == recordID }
                if let index = snapshot.queue.firstIndex(where: { $0.id == recordID }) { snapshot.queue[index].state = .deleted }
                else { snapshot.queue.append(DownloadQueueEntry(metadata: metadata(for: record), state: .deleted)) }
            }
        } catch {
            if files.fileExists(atPath: trash.path) { try? files.moveItem(at: trash, to: source) }
            throw error
        }
        try checkpoint?(.deleteCommitted)
        try recoverTransactions()
        return try disk.load()
    }

    func revalidatePendingAssets() async throws -> DownloadStorageSnapshot {
        _ = try await Task.detached(priority: .utility) { [store] in try store.revalidatePendingAssets() }.value
        return try disk.load()
    }

    func inventory() throws -> [OfflineStorageInventoryItem] {
        let snapshot = try? disk.load()
        let referenced = Set(snapshot?.records.map { $0.packageDirectoryName ?? $0.fileName } ?? [])
        var result: [OfflineStorageInventoryItem] = try children(store.rootDirectory).compactMap { url in
            let name = url.lastPathComponent
            guard referenced.contains(name) || name.hasPrefix("offline-") || name.hasPrefix("assembling-")
                || name.hasPrefix("deleting-") else { return nil }
            let type = try files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory else { return nil }
            let size = type == .typeDirectory ? try directoryBytes(url) : (try files.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return OfflineStorageInventoryItem(id: name, byteCount: size, recoverable: !referenced.contains(name))
        }
        for receiptDirectory in try children(store.rootDirectory.appendingPathComponent("incoming")) {
            guard (try? files.attributesOfItem(atPath: receiptDirectory.path)[.type] as? FileAttributeType) == .typeDirectory else { continue }
            result.append(OfflineStorageInventoryItem(id: "incoming/\(receiptDirectory.lastPathComponent)",
                                                     byteCount: try directoryBytes(receiptDirectory), recoverable: false))
        }
        return result
    }

    func recoverDamagedIndex() async throws -> DownloadStorageSnapshot {
        try requireDamagedIndex()
        var rebuilt = DownloadStorageSnapshot()
        let candidates = try children(store.rootDirectory)
        // Per-package metadata is newer and more complete than the untouched
        // legacy migration input. Preserve its account and component ownership.
        for url in candidates where url.lastPathComponent.hasPrefix("offline-") {
            let type = try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            guard type == .typeDirectory, disk.isRegularFile(url.appendingPathComponent("record.json")),
                  let data = try? Data(contentsOf: url.appendingPathComponent("record.json")),
                  let record = try? JSONDecoder().decode(DownloadRecord.self, from: data),
                  record.packageDirectoryName == url.lastPathComponent,
                  OfflinePackagePath.isSafeLeaf(record.fileName), disk.isRegularFile(url.appendingPathComponent(record.fileName)),
                  !rebuilt.records.contains(where: { $0.id == record.id }) else { continue }
            rebuilt.records.append(record)
        }
        let legacyURL = store.rootDirectory.appendingPathComponent("manifest.json")
        if disk.isRegularFile(legacyURL), let data = try? Data(contentsOf: legacyURL),
           let manifest = try? JSONDecoder().decode(DownloadManifest.self, from: data), manifest.schemaVersion == 1 {
            for var record in manifest.records {
                guard OfflinePackagePath.isSafeLeaf(record.fileName),
                      record.packageDirectoryName.map(OfflinePackagePath.isSafeLeaf) != false,
                      record.packageDirectoryName == nil || store.packageURL(for: record) != nil,
                      disk.isRegularFile(store.localURL(for: record)),
                      !rebuilt.records.contains(where: { store.localURL(for: $0) == store.localURL(for: record) }) else { continue }
                // A later package keeps its stable identity. An older, distinct
                // physical file keeps its own record and original ownership,
                // rather than being overwritten or assigned to that account.
                if rebuilt.records.contains(where: { $0.id == record.id }) { record.id = UUID() }
                record.serverOrigin = ServerIdentity.canonical(record.serverOrigin)
                rebuilt.records.append(record)
            }
        }
        for url in candidates where url.lastPathComponent.hasPrefix("offline-") {
            let type = try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            if type == .typeRegular, !rebuilt.records.contains(where: { store.localURL(for: $0) == url }) {
                let byteCount = (try files.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard byteCount > 0 else { continue }
                let inspection = await Task.detached(priority: .utility) {
                    DownloadAssetInspector.inspect(url, fileExtension: url.pathExtension)
                }.value
                let candidate = String(url.deletingPathExtension().lastPathComponent.dropFirst("offline-".count).prefix(36))
                let id = UUID(uuidString: candidate) ?? UUID()
                let recoveredID = rebuilt.records.contains(where: { $0.id == id }) ? UUID() : id
                let record = DownloadRecord(id: recoveredID, serverOrigin: "urn:rustyview:unassigned", mediaID: recoveredID.uuidString,
                                            title: "Recovered movie", kind: .original, fileName: url.lastPathComponent,
                                            byteCount: byteCount, completedAt: Date(), durationSeconds: inspection.durationSeconds.flatMap {
                                                $0 < Double(Int.max) ? Int($0) : nil
                                            },
                                            resolution: nil, artworkPath: nil, assetInspection: inspection)
                rebuilt.records.append(record)
            }
        }
        rebuilt.queue = rebuilt.records.map { DownloadQueueEntry(metadata: metadata(for: $0), state: .completed) }
        _ = try disk.replaceDamagedIndex(with: rebuilt)
        return try await revalidatePendingAssets()
    }

    private func requireDamagedIndex() throws {
        do { _ = try disk.load() }
        catch DownloadStoreError.invalidManifest { return }
        catch DownloadQueueError.invalidJournal { return }
        // Permission, protected-data, and storage errors propagate unchanged.
        // A stale recovery action never replaces readable queued user intent.
        throw DownloadStorageFailure.recoveryNotNeeded
    }

    private func matchingEntry(_ receipt: DownloadReceipt, in snapshot: DownloadStorageSnapshot) -> DownloadQueueEntry? {
        guard let entry = snapshot.queue.first(where: { $0.id == receipt.metadata.recordID }),
              !entry.state.isTerminal, entry.metadata.attemptID == receipt.metadata.attemptID,
              DownloadOwnership.sameRendition(entry.metadata, receipt.metadata),
              let resource = resource(receipt.resourceID, in: entry),
              receipt.transferID == nil || resource.transferID == receipt.transferID else { return nil }
        return entry
    }

    private func resource(_ id: String, in entry: DownloadQueueEntry) -> DownloadResourceDescriptor? {
        entry.resources?.first { $0.id == id }
    }

    private func validResources(_ resources: [DownloadResourceDescriptor]) -> Bool {
        resources.filter { $0.resource.kind == .media }.count == 1
            && Set(resources.map(\.id)).count == resources.count
            && Set(resources.map { $0.resource.fileName }).count == resources.count
            && resources.allSatisfy {
                OfflinePackagePath.isSafeLeaf($0.resource.fileName)
                    && !["movie.json", "record.json"].contains($0.resource.fileName)
                    && ($0.resource.caption == nil || $0.resource.caption?.fileName == $0.resource.fileName)
            }
    }

    private func receipt(for resource: DownloadResourceDescriptor, entry: DownloadQueueEntry, snapshot: DownloadStorageSnapshot) -> DownloadReceipt? {
        snapshot.receipts.last {
            $0.metadata.recordID == entry.id && $0.metadata.attemptID == entry.metadata.attemptID
                && $0.resourceID == resource.id && ($0.transferID == nil || $0.transferID == resource.transferID)
        }
    }

    private func commit(_ transaction: DownloadFileTransaction) throws -> DownloadStorageSnapshot {
        try disk.update { snapshot in
            guard let index = snapshot.queue.firstIndex(where: { $0.id == transaction.record.id }),
                  !snapshot.queue[index].state.isTerminal,
                  snapshot.queue[index].metadata.attemptID == transaction.record.installedAttemptID else { throw DownloadStorageFailure.staleAttempt }
            snapshot.records.removeAll { $0.id == transaction.record.id }
            snapshot.records.append(transaction.record)
            snapshot.queue[index].state = .completed
            snapshot.queue[index].failure = nil
            snapshot.queue[index].reason = nil
        }
    }

    private func recoverTransactions() throws {
        for transaction in try disk.load().transactions {
            guard OfflinePackagePath.isSafeLeaf(transaction.sourceName), OfflinePackagePath.isSafeLeaf(transaction.destinationName) else {
                throw DownloadStoreError.invalidManifest
            }
            guard OfflinePackagePath.isSafeLeaf(transaction.record.fileName) else { throw DownloadStoreError.invalidManifest }
            let source = store.rootDirectory.appendingPathComponent(transaction.sourceName)
            let destination = store.rootDirectory.appendingPathComponent(transaction.destinationName)
            let snapshot = try disk.load()
            let committed = snapshot.records.contains {
                $0.id == transaction.record.id && $0.packageDirectoryName == transaction.record.packageDirectoryName
                    && $0.fileName == transaction.record.fileName
            }
            do { switch transaction.operation {
            case .delete:
                if committed {
                    if !files.fileExists(atPath: source.path), files.fileExists(atPath: destination.path) {
                        try files.moveItem(at: destination, to: source)
                    }
                } else {
                    if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
                }
            case .install:
                let entry = snapshot.queue.first { $0.id == transaction.record.id }
                let cancelled = entry?.state == .cancelled || entry?.state == .deleted || entry?.state == .removed
                    || entry?.metadata.attemptID != transaction.record.installedAttemptID
                if cancelled {
                    for url in [source, destination] where files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
                } else if !committed {
                    // A recorded permanent failure remains actionable until the
                    // user retries. Process death alone does not reset it.
                    if entry?.state == .failed || entry?.state == .paused || entry?.state == .pausing { continue }
                    if files.fileExists(atPath: source.path) {
                        guard (try files.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType) == .typeDirectory else {
                            throw DownloadStoreError.invalidDownloadedFile
                        }
                        let media = source.appendingPathComponent(transaction.record.fileName)
                        if !disk.isRegularFile(media), let receiptName = transaction.mediaReceiptDirectory,
                           let incoming = ingress.payloadURL(directoryName: receiptName), disk.isRegularFile(incoming) {
                            try files.moveItem(at: incoming, to: media)
                        }
                        guard disk.isRegularFile(media) else { throw DownloadStorageFailure.missingComponent }
                        if !files.fileExists(atPath: destination.path) { try files.moveItem(at: source, to: destination) }
                    }
                    guard (try? files.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType) == .typeDirectory,
                          disk.isRegularFile(destination.appendingPathComponent(transaction.record.fileName)) else {
                        throw DownloadStorageFailure.missingComponent
                    }
                    _ = try commit(transaction)
                }
                try cleanCommitted(transaction, snapshot: try disk.load())
            } } catch DownloadStorageFailure.missingComponent {
                try markDamagedTransaction(transaction)
                continue
            } catch DownloadStoreError.invalidDownloadedFile {
                try markDamagedTransaction(transaction)
                continue
            }
            _ = try disk.update { $0.transactions.removeAll { $0.id == transaction.id } }
        }
    }

    private func markDamagedTransaction(_ transaction: DownloadFileTransaction) throws {
        let snapshot = try disk.load()
        guard let entry = snapshot.queue.first(where: { $0.id == transaction.record.id }), !entry.state.isTerminal,
              entry.metadata.attemptID == transaction.record.installedAttemptID else { return }
        let locations = [transaction.sourceName, transaction.destinationName].map { store.rootDirectory.appendingPathComponent($0) }
        let assemblyHasMedia = locations.contains { location in
            (try? files.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType) == .typeDirectory
                && disk.isRegularFile(location.appendingPathComponent(transaction.record.fileName))
        }
        let videoReceipts = snapshot.receipts.filter { $0.metadata.recordID == entry.id && $0.metadata.attemptID == entry.metadata.attemptID && $0.resourceID == "video" }
        let ingressHasMedia = videoReceipts.contains { receipt in ingress.payloadURL(receipt).map(disk.isRegularFile) == true }
        let missingMedia = !assemblyHasMedia && !ingressHasMedia
        if !assemblyHasMedia {
            // The promised movie bytes are gone. Keep delivered caption/art
            // receipts, retire this unusable assembly, and expose video retry.
            for location in locations where files.fileExists(atPath: location.path) { try files.removeItem(at: location) }
            if missingMedia { for receipt in videoReceipts { try ingress.remove(receipt) } }
        }
        _ = try disk.update { snapshot in
            guard let index = snapshot.queue.firstIndex(where: { $0.id == transaction.record.id }),
                  !snapshot.queue[index].state.isTerminal,
                  snapshot.queue[index].metadata.attemptID == transaction.record.installedAttemptID else { return }
            snapshot.queue[index].state = .failed
            snapshot.queue[index].reason = DownloadStorageFailure.missingComponent.localizedDescription
            snapshot.queue[index].failure = UserFacingError(DownloadStorageFailure.missingComponent)
            if missingMedia, let mediaIndex = snapshot.queue[index].resources?.firstIndex(where: { $0.resource.kind == .media }) {
                snapshot.queue[index].resources?[mediaIndex].state = .failed
                snapshot.queue[index].resources?[mediaIndex].reason = DownloadStorageFailure.missingComponent.localizedDescription
                snapshot.queue[index].resources?[mediaIndex].failure = UserFacingError(DownloadStorageFailure.missingComponent)
                snapshot.queue[index].resources?[mediaIndex].receivedBytes = 0
                snapshot.receipts.removeAll { receipt in videoReceipts.contains(where: { $0.id == receipt.id }) }
            }
            if !assemblyHasMedia { snapshot.transactions.removeAll { $0.id == transaction.id } }
        }
    }

    private func cleanCommitted(_ transaction: DownloadFileTransaction, snapshot: DownloadStorageSnapshot) throws {
        for receipt in snapshot.receipts where receipt.metadata.recordID == transaction.record.id
            && receipt.metadata.attemptID == transaction.record.installedAttemptID { try ingress.remove(receipt) }
        _ = try disk.update { snapshot in
            snapshot.receipts.removeAll {
                $0.metadata.recordID == transaction.record.id && $0.metadata.attemptID == transaction.record.installedAttemptID
            }
            snapshot.transactions.removeAll { $0.id == transaction.id }
        }
    }

    private func metadata(for record: DownloadRecord) -> DownloadTaskMetadata {
        DownloadTaskMetadata(recordID: record.id, serverOrigin: record.serverOrigin, mediaID: record.mediaID,
                             title: record.title, kind: record.kind, fileExtension: (record.fileName as NSString).pathExtension,
                             durationSeconds: record.durationSeconds, resolution: record.resolution,
                             attemptID: record.installedAttemptID, qualityID: record.qualityID,
                             audioTrackIndex: record.audioTrackIndex, accountUsername: record.accountUsername, movie: record.movie)
    }

    private func children(_ url: URL) throws -> [URL] {
        guard (try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory else { return [] }
        return try files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    private func directoryBytes(_ directory: URL) throws -> Int64 {
        try children(directory).reduce(0) { total, url in
            let values = try files.attributesOfItem(atPath: url.path)
            guard values[.type] as? FileAttributeType == .typeRegular else { return total }
            return total + ((values[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}

private final class DownloadReceiptIngress: @unchecked Sendable {
    private let root: URL
    private let files: FileManager
    private let lock = NSLock()
    private let checkpoint: (@Sendable (DownloadStorageBoundary) throws -> Void)?
    private var directory: URL { root.appendingPathComponent("incoming", isDirectory: true) }

    init(root: URL, files: FileManager, checkpoint: (@Sendable (DownloadStorageBoundary) throws -> Void)?) {
        self.root = root; self.files = files; self.checkpoint = checkpoint
    }

    func stage(temporaryURL: URL, metadata: DownloadTaskMetadata, resourceID: String,
               transferID: UUID?, expectedByteCount: Int64?) throws -> DownloadReceipt {
        lock.lock()
        defer { lock.unlock() }
        guard (try files.attributesOfItem(atPath: temporaryURL.path)[.type] as? FileAttributeType) == .typeRegular else {
            throw DownloadStoreError.invalidDownloadedFile
        }
        for parent in [root, directory] {
            if let type = try? files.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType,
               type != .typeDirectory { throw DownloadStoreError.invalidDownloadedFile }
        }
        let id = UUID()
        let receipt = DownloadReceipt(id: id, metadata: metadata, resourceID: resourceID, transferID: transferID,
                                      directoryName: id.uuidString.lowercased(), expectedByteCount: expectedByteCount)
        let target = directory.appendingPathComponent(receipt.directoryName, isDirectory: true)
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        var rootURL = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? rootURL.setResourceValues(values)
        try JSONEncoder().encode(receipt).write(to: target.appendingPathComponent("receipt.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
        try checkpoint?(.receiptWritten)
        try files.moveItem(at: temporaryURL, to: target.appendingPathComponent("payload"))
        try checkpoint?(.mediaStaged)
        return receipt
    }

    func pending() throws -> [DownloadReceipt] {
        lock.lock()
        defer { lock.unlock() }
        guard (try? files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType) == .typeDirectory else { return [] }
        return try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { url in
            guard (try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory,
                  (try? files.attributesOfItem(atPath: url.appendingPathComponent("receipt.json").path)[.type] as? FileAttributeType) == .typeRegular,
                  let data = try? Data(contentsOf: url.appendingPathComponent("receipt.json")),
                  let receipt = try? JSONDecoder().decode(DownloadReceipt.self, from: data),
                  receipt.directoryName == url.lastPathComponent,
                  (try? files.attributesOfItem(atPath: url.appendingPathComponent("payload").path)[.type] as? FileAttributeType) == .typeRegular else { return nil }
            return receipt
        }
    }

    func payloadURL(_ receipt: DownloadReceipt) -> URL? { payloadURL(directoryName: receipt.directoryName) }

    func payloadURL(directoryName: String) -> URL? {
        guard UUID(uuidString: directoryName) != nil, OfflinePackagePath.isSafeLeaf(directoryName),
              (try? files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType) == .typeDirectory else { return nil }
        let target = directory.appendingPathComponent(directoryName, isDirectory: true)
        guard (try? files.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType) == .typeDirectory else { return nil }
        return target.appendingPathComponent("payload")
    }

    func remove(_ receipt: DownloadReceipt) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let payload = payloadURL(receipt) else { return }
        try files.removeItem(at: payload.deletingLastPathComponent())
    }

    func remove(recordID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard (try? files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType) == .typeDirectory else { return }
        for target in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = target.lastPathComponent
            guard UUID(uuidString: name) != nil, OfflinePackagePath.isSafeLeaf(name),
                  (try? files.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType) == .typeDirectory,
                  (try? files.attributesOfItem(atPath: target.appendingPathComponent("receipt.json").path)[.type] as? FileAttributeType) == .typeRegular,
                  let data = try? Data(contentsOf: target.appendingPathComponent("receipt.json")),
                  let receipt = try? JSONDecoder().decode(DownloadReceipt.self, from: data),
                  receipt.directoryName == name, receipt.metadata.recordID == recordID else { continue }
            try files.removeItem(at: target)
        }
    }
}
