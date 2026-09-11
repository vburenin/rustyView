import CoreGraphics
import ImageIO
import XCTest
@testable import rustyView

final class DownloadStorageTransactionTests: XCTestCase {
    func testStoredLegacyTimeoutCanRecheckItsOwnedBytesWithoutConnection() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileName = "synthetic-legacy-recheck.mp4"
        let bytes = try OfflineMediaFixture.validData()
        try bytes.write(to: root.appendingPathComponent(fileName))
        let record = DownloadRecord(id: UUID(), serverOrigin: "https://media.example.test", mediaID: "42048",
            title: "The Synthetic Observatory", kind: .original, fileName: fileName,
            byteCount: Int64(bytes.count), completedAt: Date(), durationSeconds: 2,
            resolution: "96x64", artworkPath: nil)
        try JSONEncoder().encode(DownloadManifest(records: [record])).write(to: root.appendingPathComponent("manifest.json"))
        let stalled = DownloadStorageCoordinator(store: DownloadManifestStore(rootDirectory: root, inspectionProgressTimeout: 0))
        _ = try await stalled.restore()
        let pending = try await stalled.revalidatePendingAssets()
        XCTAssertEqual(pending.records.first?.assetInspection?.issue, .timedOut)
        XCTAssertFalse(try XCTUnwrap(pending.records.first).isReadyToWatch)
        let reopened = DownloadStorageCoordinator(store: DownloadManifestStore(rootDirectory: root))
        let checked = try await reopened.revalidatePendingAssets(recordID: record.id)
        XCTAssertTrue(try XCTUnwrap(checked.records.first).isReadyToWatch)
        XCTAssertNil(checked.records.first?.accountUsername)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(fileName)), bytes)
        XCTAssertTrue(checked.receipts.isEmpty)
    }

    func testVerificationTimeoutRetainsBytesAndReopenedStoreVerifiesWithoutAnotherTransfer() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = entry()
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"), inspectionProgressTimeout: 0)
        let coordinator = DownloadStorageCoordinator(store: store)
        _ = try await coordinator.enqueue(entry)
        do {
            _ = try await deliver(.media, entry: entry, coordinator: coordinator, root: root)
            XCTFail("An exhausted inspection budget must leave a retryable verification, not mark a file unsupported")
        } catch DownloadStoreError.verificationTimedOut { }
        let failed = try await coordinator.snapshot()
        XCTAssertTrue(failed.records.isEmpty)
        XCTAssertEqual(failed.queue.first?.resources?.first?.verificationPending, true)
        XCTAssertEqual(failed.queue.first?.state, .failed)
        let reopenedStore = DownloadManifestStore(rootDirectory: store.rootDirectory)
        let reopened = DownloadStorageCoordinator(store: reopenedStore)
        let recovered = try await reopened.retryVerification(recordID: entry.id)
        let record = try XCTUnwrap(recovered.records.first)
        XCTAssertTrue(record.isReadyToWatch)
        XCTAssertEqual(recovered.queue.first?.state, .completed)
        XCTAssertEqual(recovered.queue.first?.metadata.attemptID, entry.metadata.attemptID)
        XCTAssertEqual(try Data(contentsOf: reopenedStore.localURL(for: record)), try OfflineMediaFixture.validData())
        XCTAssertTrue(recovered.receipts.isEmpty)
    }

    func testCancelledVerificationCannotRestoreRetainedBytesAfterRelaunch() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = entry()
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"), inspectionProgressTimeout: 0)
        let coordinator = DownloadStorageCoordinator(store: store)
        _ = try await coordinator.enqueue(entry)
        do {
            _ = try await deliver(.media, entry: entry, coordinator: coordinator, root: root)
            XCTFail("Expected a stalled verification")
        } catch DownloadStoreError.verificationTimedOut { }
        _ = try await coordinator.cancel(recordID: entry.id)
        let reopened = DownloadStorageCoordinator(store: DownloadManifestStore(rootDirectory: store.rootDirectory))
        _ = try await reopened.retryVerification(recordID: entry.id)
        let restored = try await reopened.restore()
        XCTAssertTrue(restored.records.isEmpty)
        XCTAssertTrue(restored.receipts.isEmpty)
        XCTAssertEqual(restored.queue.first?.state, .cancelled)
    }

    func testInstallRollsForwardAfterAbandoningEveryDurableMoveAndCommitBoundary() async throws {
        for boundary in [DownloadStorageBoundary.transactionWritten, .packageMoved, .indexCommitted] {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let entry = entry()
            let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
            let interrupted = DownloadStorageCoordinator(store: store) { reached in
                if reached == boundary { throw DownloadStorageFailure.interrupted }
            }
            _ = try await interrupted.enqueue(entry)
            do {
                _ = try await deliver(.media, entry: entry, coordinator: interrupted, root: root)
                XCTFail("The storage boundary was not reached: \(boundary)")
            } catch DownloadStorageFailure.interrupted { }
            // Drop the old operation without invoking an exception rollback.
            // A new store sees precisely the durable files left by termination.
            let reopenedStore = DownloadManifestStore(rootDirectory: store.rootDirectory)
            let reopened = DownloadStorageCoordinator(store: reopenedStore)
            let recovered = try await reopened.restore()
            let record = try XCTUnwrap(recovered.records.first)
            XCTAssertEqual(recovered.records.count, 1)
            XCTAssertEqual(recovered.queue.first?.state, .completed)
            XCTAssertTrue(record.isReadyToWatch)
            XCTAssertEqual(try Data(contentsOf: reopenedStore.localURL(for: record)), try OfflineMediaFixture.validData())
            XCTAssertTrue(recovered.transactions.isEmpty)
            XCTAssertTrue(recovered.receipts.isEmpty)
            let repeated = try await reopened.restore()
            XCTAssertEqual(repeated.records, recovered.records, "Recovery must be idempotent")
            let inventory = try await reopened.inventory()
            XCTAssertFalse(inventory.contains(where: \.recoverable), "No media is left outside the committed package")
        }
    }

    func testReceiptSurvivesTerminationBeforeDelegateReturns() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = entry()
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let interrupted = DownloadStorageCoordinator(store: store) { boundary in
            if boundary == .mediaStaged { throw DownloadStorageFailure.interrupted }
        }
        _ = try await interrupted.enqueue(entry)
        do {
            _ = try await deliver(.media, entry: entry, coordinator: interrupted, root: root)
            XCTFail("The delegate staging boundary must interrupt")
        } catch DownloadStorageFailure.interrupted { }
        let reopened = DownloadStorageCoordinator(store: DownloadManifestStore(rootDirectory: store.rootDirectory))
        let recovered = try await reopened.restore()
        XCTAssertEqual(recovered.records.count, 1)
        XCTAssertTrue(try XCTUnwrap(recovered.records.first).isReadyToWatch)
        XCTAssertEqual(recovered.queue.first?.state, .completed)
    }

    func testReceiptIntentWithoutItsMoveDoesNotPublishOrForgetQueueWork() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = entry()
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let interrupted = DownloadStorageCoordinator(store: store) { boundary in
            if boundary == .receiptWritten { throw DownloadStorageFailure.interrupted }
        }
        _ = try await interrupted.enqueue(entry)
        do {
            _ = try await deliver(.media, entry: entry, coordinator: interrupted, root: root)
            XCTFail("The receipt intent must be durable before the file move")
        } catch DownloadStorageFailure.interrupted { }
        let recovered = try await DownloadStorageCoordinator(store: DownloadManifestStore(rootDirectory: store.rootDirectory)).restore()
        XCTAssertTrue(recovered.records.isEmpty)
        XCTAssertEqual(recovered.queue.first?.id, entry.id)
        XCTAssertFalse(try XCTUnwrap(recovered.queue.first).state.isTerminal)
    }

    func testDeleteRecoveryRestoresPrecommitMovieAndFinishesCommittedDeletion() async throws {
        for boundary in [DownloadStorageBoundary.transactionWritten, .deleteMoved, .deleteCommitted] {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
            let coordinator = DownloadStorageCoordinator(store: store)
            let entry = entry()
            _ = try await coordinator.enqueue(entry)
            let installed = try await deliver(.media, entry: entry, coordinator: coordinator, root: root)
            let record = try XCTUnwrap(installed.records.first)
            let interrupted = DownloadStorageCoordinator(store: store) { reached in
                if reached == boundary { throw DownloadStorageFailure.interrupted }
            }
            do {
                _ = try await interrupted.delete(recordID: record.id)
                XCTFail("The delete boundary must interrupt: \(boundary)")
            } catch DownloadStorageFailure.interrupted { }
            let reopenedStore = DownloadManifestStore(rootDirectory: store.rootDirectory)
            let reopened = DownloadStorageCoordinator(store: reopenedStore)
            let recovered = try await reopened.restore()
            if boundary == .deleteCommitted {
                XCTAssertTrue(recovered.records.isEmpty)
                XCTAssertEqual(recovered.queue.first?.state, .deleted)
                XCTAssertFalse(FileManager.default.fileExists(atPath: reopenedStore.localURL(for: record).path))
            } else {
                XCTAssertEqual(recovered.records, [record])
                XCTAssertEqual(try Data(contentsOf: reopenedStore.localURL(for: record)), try OfflineMediaFixture.validData())
            }
            XCTAssertTrue(recovered.transactions.isEmpty)
            let repeated = try await reopened.restore()
            XCTAssertEqual(repeated.records, recovered.records)
        }
    }

    func testActualManifestWriteFailureAfterDeleteMoveRestoresThePackage() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = DeleteCommitFailureFileManager()
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"), fileManager: files)
        let coordinator = DownloadStorageCoordinator(store: store)
        let entry = entry()
        _ = try await coordinator.enqueue(entry)
        let saved = try await deliver(.media, entry: entry, coordinator: coordinator, root: root)
        let record = try XCTUnwrap(saved.records.first)
        files.failAfterDeleteMove = true
        do {
            _ = try await coordinator.delete(recordID: record.id)
            XCTFail("The state commit must observe the injected full-disk write failure")
        } catch {
            XCTAssertEqual((error as NSError).code, NSFileWriteOutOfSpaceError)
        }
        XCTAssertEqual(try Data(contentsOf: store.localURL(for: record)), try OfflineMediaFixture.validData())
        files.rejectDirectoryPreparation = false
        files.failAfterDeleteMove = false
        let recovered = try await DownloadStorageCoordinator(store: store).restore()
        XCTAssertEqual(recovered.records, [record])
        XCTAssertTrue(recovered.transactions.isEmpty)
    }

    func testRecordedInstallationFailureSurvivesRelaunchUntilExplicitRetry() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let interrupted = DownloadStorageCoordinator(store: store) { boundary in
            if boundary == .packageMoved { throw DownloadStorageFailure.interrupted }
        }
        let entry = entry()
        _ = try await interrupted.enqueue(entry)
        do { _ = try await deliver(.media, entry: entry, coordinator: interrupted, root: root) }
        catch DownloadStorageFailure.interrupted { }
        try store.stateStore.update { snapshot in
            snapshot.queue[0].state = .failed
            snapshot.queue[0].reason = "There is not enough storage to finish saving this movie."
        }
        let reopened = DownloadStorageCoordinator(store: DownloadManifestStore(rootDirectory: store.rootDirectory))
        let restored = try await reopened.restore()
        XCTAssertTrue(restored.records.isEmpty)
        XCTAssertEqual(restored.queue.first?.state, .failed)
        XCTAssertEqual(restored.transactions.count, 1, "The downloaded package remains available for retry")
        var retried = try XCTUnwrap(restored.queue.first)
        retried.state = .queued
        _ = try await reopened.update(retried, expectedAttemptID: retried.metadata.attemptID)
        let completed = try await reopened.finishAvailablePackage(recordID: entry.id)
        XCTAssertTrue(try XCTUnwrap(completed.records.first).isReadyToWatch)
        XCTAssertEqual(completed.queue.first?.state, .completed)
        XCTAssertTrue(completed.transactions.isEmpty)
    }

    func testLegacyValidationCannotResurrectARecordDeletedByTheStorageActor() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ValidationRaceFileManager()
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"), fileManager: files)
        let coordinator = DownloadStorageCoordinator(store: store)
        let entry = entry()
        _ = try await coordinator.enqueue(entry)
        let installed = try await deliver(.media, entry: entry, coordinator: coordinator, root: root)
        let record = try XCTUnwrap(installed.records.first)
        let video = store.localURL(for: record)
        try Data("changed synthetic bytes".utf8).write(to: video)
        let read = expectation(description: "Validation read the former record and its file attributes")
        files.arm(path: video.path) { read.fulfill() }
        let validation = Task.detached { try store.loadValidated() }
        await fulfillment(of: [read], timeout: 5)
        // The actor bypasses the old facade lock. Its commit must remain the
        // owner even though validation already holds the former record in RAM.
        _ = try await coordinator.delete(recordID: record.id)
        files.releaseRead()
        let validated = try await validation.value
        XCTAssertTrue(validated.records.isEmpty)
        let snapshot = try await coordinator.snapshot()
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertEqual(snapshot.queue.first?.state, .deleted)
    }

    func testMediaCaptionsChaptersAndArtworkPublishAsOneCompleteOfflinePackage() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let coordinator = DownloadStorageCoordinator(store: store)
        let entry = entry(caption: true, artwork: true)
        _ = try await coordinator.enqueue(entry)
        let afterVideo = try await deliver(.media, entry: entry, coordinator: coordinator, root: root)
        XCTAssertTrue(afterVideo.records.isEmpty, "A video cannot publish while its promised captions are missing")
        let afterCaption = try await deliver(.caption, entry: entry, coordinator: coordinator, root: root)
        XCTAssertTrue(afterCaption.records.isEmpty, "The optional artwork attempt must finish or report its failure")
        _ = try await deliver(.artwork, entry: entry, coordinator: coordinator, root: root)

        let reopened = DownloadStorageCoordinator(store: DownloadManifestStore(rootDirectory: store.rootDirectory))
        let saved = try await reopened.restore()
        let record = try XCTUnwrap(saved.records.first)
        XCTAssertTrue(record.isReadyToWatch)
        XCTAssertEqual(record.movieMetadata.chapters.map(\.startSeconds), [0, 1])
        let caption = try XCTUnwrap(record.localCaptions?.first)
        let captionURL = try XCTUnwrap(store.captionURL(for: record, caption: caption))
        let cues = try WebVTTParser.parse(Data(contentsOf: captionURL))
        XCTAssertEqual(cues.first?.text, "A synthetic offline subtitle")
        let artwork = try XCTUnwrap(store.artworkURL(for: record))
        XCTAssertNotNil(CGImageSourceCreateWithURL(artwork as CFURL, nil))
        XCTAssertGreaterThan(try XCTUnwrap(record.packageStorageBytes), record.byteCount)
        XCTAssertEqual(saved.queue.first?.state, .completed)
        XCTAssertTrue(saved.receipts.isEmpty)
    }

    func testCancelAfterVideoArrivalCannotPublishAPartialPackageOnRelaunch() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let coordinator = DownloadStorageCoordinator(store: store)
        let entry = entry(caption: true)
        _ = try await coordinator.enqueue(entry)
        _ = try await deliver(.media, entry: entry, coordinator: coordinator, root: root)
        _ = try await coordinator.cancel(recordID: entry.id)
        _ = try await deliver(.caption, entry: entry, coordinator: coordinator, root: root)
        let reopened = DownloadStorageCoordinator(store: DownloadManifestStore(rootDirectory: store.rootDirectory))
        let saved = try await reopened.restore()
        XCTAssertTrue(saved.records.isEmpty)
        XCTAssertTrue(saved.receipts.isEmpty)
        XCTAssertEqual(saved.queue.first?.state, .cancelled)
    }

    func testRemovingRejectedPayloadImmediatelyFreesItsBytesAndPreservesOtherJobsAndLinks() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let coordinator = DownloadStorageCoordinator(store: store)
        var rejected = entry()
        let other = entry()
        _ = try await coordinator.enqueue(rejected)
        _ = try await coordinator.enqueue(other)
        let invalidFile = root.appendingPathComponent("invalid-system.tmp")
        try Data("This synthetic response is not a movie".utf8).write(to: invalidFile)
        let badResource = try XCTUnwrap(rejected.resources?.first)
        let rejectedReceipt = try coordinator.stageTemporaryFile(temporaryURL: invalidFile, metadata: rejected.metadata,
                                                                  resourceID: badResource.id, transferID: badResource.transferID)
        do { _ = try await coordinator.receive(rejectedReceipt); XCTFail("Real invalid media must fail inspection") }
        catch DownloadStoreError.incompatibleDownload { }
        let afterFailure = try await coordinator.snapshot()
        XCTAssertTrue(afterFailure.receipts.isEmpty, "The regression concerns bytes not indexed after failed validation")
        rejected.state = .failed
        _ = try await coordinator.update(rejected, expectedAttemptID: rejected.metadata.attemptID)

        let otherFile = root.appendingPathComponent("other-system.tmp")
        let validBytes = try OfflineMediaFixture.validData()
        try validBytes.write(to: otherFile)
        let otherResource = try XCTUnwrap(other.resources?.first)
        let otherReceipt = try coordinator.stageTemporaryFile(temporaryURL: otherFile, metadata: other.metadata,
                                                               resourceID: otherResource.id, transferID: otherResource.transferID)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideBytes = Data("Synthetic outside bytes stay private".utf8)
        try outsideBytes.write(to: outside.appendingPathComponent("payload"))
        let incoming = store.rootDirectory.appendingPathComponent("incoming")
        let linked = incoming.appendingPathComponent(UUID().uuidString.lowercased())
        try JSONEncoder().encode(rejectedReceipt).write(to: outside.appendingPathComponent("receipt.json"))
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)

        _ = try await coordinator.cancel(recordID: rejected.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.appendingPathComponent(rejectedReceipt.directoryName).path))
        XCTAssertEqual(try Data(contentsOf: incoming.appendingPathComponent(otherReceipt.directoryName).appendingPathComponent("payload")), validBytes)
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("payload")), outsideBytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linked.path), outside.path)
        let inventory = try await coordinator.inventory()
        XCTAssertEqual(inventory.map(\.id), ["incoming/\(otherReceipt.directoryName)"])
        let cancelled = try await coordinator.snapshot()
        XCTAssertEqual(cancelled.queue.first(where: { $0.id == rejected.id })?.state, .cancelled)
        XCTAssertTrue(cancelled.records.isEmpty)
    }

    func testCancellationBetweenDelegateStagingAndActorReceiptProcessingFreesBytesImmediately() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let coordinator = DownloadStorageCoordinator(store: store)
        let entry = entry()
        _ = try await coordinator.enqueue(entry)
        let temporary = root.appendingPathComponent("system.tmp")
        try OfflineMediaFixture.validData().write(to: temporary)
        let resource = try XCTUnwrap(entry.resources?.first)
        let receipt = try coordinator.stageTemporaryFile(temporaryURL: temporary, metadata: entry.metadata,
                                                         resourceID: resource.id, transferID: resource.transferID)
        _ = try await coordinator.cancel(recordID: entry.id)
        let inventory = try await coordinator.inventory()
        XCTAssertTrue(inventory.isEmpty, "Removal cannot wait for process relaunch to reclaim staged bytes")
        do { _ = try await coordinator.receive(receipt); XCTFail("Cancelled ingress bytes have already been removed") }
        catch DownloadStorageFailure.missingComponent { }
        let cancelled = try await coordinator.snapshot()
        XCTAssertTrue(cancelled.records.isEmpty)
        XCTAssertTrue(cancelled.receipts.isEmpty)
        XCTAssertEqual(cancelled.queue.first?.state, .cancelled)
    }

    func testCancellationTombstoneWinsAgainstAnInterruptedUncommittedInstallation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let entry = entry()
        let interrupted = DownloadStorageCoordinator(store: store) { boundary in
            if boundary == .packageMoved { throw DownloadStorageFailure.interrupted }
        }
        _ = try await interrupted.enqueue(entry)
        do { _ = try await deliver(.media, entry: entry, coordinator: interrupted, root: root) }
        catch DownloadStorageFailure.interrupted { }
        // Reproduce death after durable user cancellation but before rollback.
        try store.stateStore.update { snapshot in
            snapshot.queue[0].state = .cancelled
        }
        let reopened = DownloadStorageCoordinator(store: DownloadManifestStore(rootDirectory: store.rootDirectory))
        let recovered = try await reopened.restore()
        XCTAssertTrue(recovered.records.isEmpty)
        XCTAssertTrue(recovered.receipts.isEmpty)
        XCTAssertTrue(recovered.transactions.isEmpty)
        XCTAssertEqual(recovered.queue.first?.state, .cancelled)
        let inventory = try await reopened.inventory()
        XCTAssertTrue(inventory.isEmpty)
    }

    func testLegacyRemovedAmbiguityMigratesWithoutDeletingOrAssigningAnAccount() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = entry().metadata
        let payload = try OfflineMediaFixture.validData()
        let fileName = "legacy-catalog-42048.mp4"
        try payload.write(to: root.appendingPathComponent(fileName))
        let record = DownloadRecord(id: metadata.recordID, serverOrigin: "https://MEDIA.example.test:443/", mediaID: metadata.mediaID,
                                    title: metadata.title, kind: .compatible, fileName: fileName, byteCount: Int64(payload.count),
                                    completedAt: Date(), durationSeconds: 2, resolution: "96x64", artworkPath: nil)
        let manifestData = try JSONEncoder().encode(DownloadManifest(records: [record]))
        try manifestData.write(to: root.appendingPathComponent("manifest.json"))
        var legacyMetadata = metadata
        legacyMetadata.accountUsername = nil
        try JSONEncoder().encode(DownloadQueueJournal(entries: [DownloadQueueEntry(metadata: legacyMetadata, state: .removed)]))
            .write(to: root.appendingPathComponent("queue.json"))
        let coordinator = DownloadStorageCoordinator(store: DownloadManifestStore(rootDirectory: root))
        let recovered = try await coordinator.restore()
        XCTAssertEqual(recovered.records.count, 1)
        XCTAssertNil(recovered.records.first?.accountUsername)
        XCTAssertEqual(recovered.records.first?.serverOrigin, "https://media.example.test")
        XCTAssertEqual(recovered.queue.first?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(fileName)), payload)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), manifestData)
        let inventory = try await coordinator.inventory()
        XCTAssertEqual(inventory.count, 1)
        XCTAssertEqual(inventory.first?.byteCount, Int64(payload.count), "Legacy media names contribute to actual managed storage")
    }

    func testCorruptIndexRecoveryPreservesPackageMetadataAndBackupEvidence() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let coordinator = DownloadStorageCoordinator(store: store)
        let entry = entry(caption: true)
        _ = try await coordinator.enqueue(entry)
        _ = try await deliver(.media, entry: entry, coordinator: coordinator, root: root)
        let installed = try await deliver(.caption, entry: entry, coordinator: coordinator, root: root)
        let record = try XCTUnwrap(installed.records.first)
        // The untouched migration input can name an older distinct file using
        // the same ID. Its bytes and nil ownership must survive, without
        // replacing the later complete package's ownership or identity.
        let legacyName = "legacy-observatory-42048.mp4"
        let legacyBytes = try OfflineMediaFixture.validData()
        try legacyBytes.write(to: store.rootDirectory.appendingPathComponent(legacyName))
        let legacy = DownloadRecord(id: record.id, serverOrigin: "https://MEDIA.example.test:443/", mediaID: record.mediaID,
                                    title: "The Older Synthetic Observatory", kind: .original, fileName: legacyName,
                                    byteCount: Int64(legacyBytes.count), completedAt: record.completedAt.addingTimeInterval(-100),
                                    durationSeconds: 2, resolution: "96x64", artworkPath: nil)
        let legacyData = try JSONEncoder().encode(DownloadManifest(records: [legacy]))
        try legacyData.write(to: store.rootDirectory.appendingPathComponent("manifest.json"))
        let damaged = Data("{damaged-index".utf8)
        try damaged.write(to: store.stateStore.stateURL)
        let reopened = DownloadStorageCoordinator(store: DownloadManifestStore(rootDirectory: store.rootDirectory))
        do { _ = try await reopened.restore(); XCTFail("A damaged index must be reported") }
        catch DownloadStoreError.invalidManifest { }
        let inventory = try await reopened.inventory()
        XCTAssertTrue(inventory.contains(where: \.recoverable))
        let repaired = try await reopened.recoverDamagedIndex()
        XCTAssertEqual(repaired.records.first(where: { $0.id == record.id }), record)
        let recoveredLegacy = try XCTUnwrap(repaired.records.first(where: { $0.fileName == legacyName }))
        XCTAssertNil(recoveredLegacy.accountUsername)
        XCTAssertEqual(recoveredLegacy.serverOrigin, "https://media.example.test")
        XCTAssertNotEqual(recoveredLegacy.id, record.id)
        XCTAssertTrue(recoveredLegacy.isReadyToWatch)
        XCTAssertEqual(repaired.records.count, 2)
        let backups = try FileManager.default.contentsOfDirectory(at: store.rootDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("recovered-index-") }
        XCTAssertTrue(try backups.contains { try Data(contentsOf: $0) == damaged })
        XCTAssertEqual(try Data(contentsOf: store.localURL(for: record)), try OfflineMediaFixture.validData())
        XCTAssertEqual(try Data(contentsOf: store.localURL(for: recoveredLegacy)), legacyBytes)
        XCTAssertEqual(try Data(contentsOf: store.rootDirectory.appendingPathComponent("manifest.json")), legacyData)
        let recoveredInventory = try await reopened.inventory()
        XCTAssertTrue(recoveredInventory.contains(where: { $0.id == legacyName && $0.byteCount == Int64(legacyBytes.count) }))
    }

    func testRecoveryCannotOverwriteReadableOrTemporarilyUnavailableQueuedIntent() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root)
        let coordinator = DownloadStorageCoordinator(store: store)
        let entry = entry()
        _ = try await coordinator.enqueue(entry)
        let before = try Data(contentsOf: store.stateStore.stateURL)
        do { _ = try await coordinator.recoverDamagedIndex(); XCTFail("A stale recovery action must preserve readable queued intent") }
        catch DownloadStorageFailure.recoveryNotNeeded { }
        XCTAssertEqual(try Data(contentsOf: store.stateStore.stateURL), before)
        let deniedStore = DownloadManifestStore(rootDirectory: root, fileManager: IndexReadDeniedFileManager())
        let inaccessible = DownloadStorageCoordinator(store: deniedStore)
        do { _ = try await inaccessible.recoverDamagedIndex(); XCTFail("Temporary file access failure must never authorize rebuilding") }
        catch { XCTAssertEqual((error as NSError).code, NSFileReadNoPermissionError) }
        XCTAssertEqual(try Data(contentsOf: store.stateStore.stateURL), before)
        XCTAssertEqual(try store.stateStore.load().queue.map(\.id), [entry.id])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix("recovered-index-") }))
    }

    func testCaptionSymlinkNeverBecomesAnOfflinePackageResource() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let coordinator = DownloadStorageCoordinator(store: store)
        let entry = entry(caption: true)
        _ = try await coordinator.enqueue(entry)
        _ = try await deliver(.media, entry: entry, coordinator: coordinator, root: root)
        let saved = try await deliver(.caption, entry: entry, coordinator: coordinator, root: root)
        let record = try XCTUnwrap(saved.records.first)
        let caption = try XCTUnwrap(record.localCaptions?.first)
        let captionURL = try XCTUnwrap(store.captionURL(for: record, caption: caption))
        let outside = root.appendingPathComponent("outside.vtt")
        let outsideBytes = Data("WEBVTT\n\n00:00.000 --> 00:01.000\nPrivate synthetic outside text\n".utf8)
        try outsideBytes.write(to: outside)
        try FileManager.default.removeItem(at: captionURL)
        try FileManager.default.createSymbolicLink(at: captionURL, withDestinationURL: outside)
        let recovered = try await coordinator.restore()
        let checked = try XCTUnwrap(recovered.records.first)
        XCTAssertFalse(checked.isReadyToWatch)
        XCTAssertNil(store.captionURL(for: checked, caption: caption))
        XCTAssertNil(store.cachedCaptionURL(for: checked, caption: caption))
        XCTAssertEqual(try Data(contentsOf: outside), outsideBytes)
    }

    func testIncomingDirectorySymlinkCannotRedirectACompletedSystemDownload() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let offline = root.appendingPathComponent("offline")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: offline, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: offline.appendingPathComponent("incoming"), withDestinationURL: outside)
        let coordinator = DownloadStorageCoordinator(store: DownloadManifestStore(rootDirectory: offline))
        let temporary = root.appendingPathComponent("system.tmp")
        let bytes = try OfflineMediaFixture.validData()
        try bytes.write(to: temporary)
        XCTAssertThrowsError(try coordinator.stageTemporaryFile(temporaryURL: temporary, metadata: entry().metadata))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: temporary), bytes)
    }

    func testDeletingAReplacedPackageDirectoryNeverDeletesTheLinkedOutsideMedia() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let coordinator = DownloadStorageCoordinator(store: store)
        let entry = entry()
        _ = try await coordinator.enqueue(entry)
        let saved = try await deliver(.media, entry: entry, coordinator: coordinator, root: root)
        let record = try XCTUnwrap(saved.records.first)
        let package = try XCTUnwrap(store.packageURL(for: record))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let bytes = Data("Synthetic external media must remain unchanged".utf8)
        try bytes.write(to: outside.appendingPathComponent(record.fileName))
        try FileManager.default.removeItem(at: package)
        try FileManager.default.createSymbolicLink(at: package, withDestinationURL: outside)
        try store.delete(record)
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent(record.fileName)), bytes)
        XCTAssertTrue(try store.load().records.isEmpty)
    }

    func testAuthoritativeIndexCannotBeImportedAsALegacyMovieFile() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root)
        let metadata = entry().metadata
        let record = DownloadRecord(id: metadata.recordID, serverOrigin: metadata.serverOrigin, mediaID: metadata.mediaID,
                                    title: metadata.title, kind: .original, fileName: "state.json", byteCount: 1,
                                    completedAt: Date(), durationSeconds: nil, resolution: nil, artworkPath: nil)
        try store.stateStore.update { $0.records = [record] }
        let validated = try store.loadValidated()
        XCTAssertTrue(validated.records.isEmpty)
        XCTAssertNoThrow(try store.stateStore.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.stateStore.stateURL.path))
    }

    func testDeletingOneLegacyReferencePreservesAnotherAccountsSharedMedia() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let coordinator = DownloadStorageCoordinator(store: store)
        let entry = entry()
        _ = try await coordinator.enqueue(entry)
        let saved = try await deliver(.media, entry: entry, coordinator: coordinator, root: root)
        let record = try XCTUnwrap(saved.records.first)
        let overlapping = DownloadRecord(id: UUID(), serverOrigin: record.serverOrigin, mediaID: record.mediaID,
                                        title: record.title, kind: record.kind, fileName: record.fileName,
                                        byteCount: record.byteCount, completedAt: record.completedAt,
                                        durationSeconds: record.durationSeconds, resolution: record.resolution, artworkPath: nil,
                                        accountUsername: "other-synthetic-viewer", assetInspection: record.assetInspection,
                                        movie: record.movie, packageDirectoryName: record.packageDirectoryName,
                                        localCaptions: record.localCaptions, packageStorageBytes: record.packageStorageBytes)
        try store.stateStore.update { $0.records.append(overlapping) }
        _ = try await coordinator.delete(recordID: record.id)
        let restored = try await coordinator.restore()
        XCTAssertEqual(restored.records, [overlapping])
        XCTAssertEqual(try Data(contentsOf: store.localURL(for: overlapping)), try OfflineMediaFixture.validData())
        XCTAssertEqual(restored.queue.first(where: { $0.id == record.id })?.state, .deleted)
    }

    func testDamagedInterruptedPackageDoesNotBlockAnUnrelatedReceipt() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let damagedEntry = entry()
        let interrupted = DownloadStorageCoordinator(store: store) { boundary in
            if boundary == .packageMoved { throw DownloadStorageFailure.interrupted }
        }
        _ = try await interrupted.enqueue(damagedEntry)
        do { _ = try await deliver(.media, entry: damagedEntry, coordinator: interrupted, root: root) }
        catch DownloadStorageFailure.interrupted { }
        let transaction = try XCTUnwrap(store.stateStore.load().transactions.first)
        let damagedPackage = store.rootDirectory.appendingPathComponent(transaction.destinationName)
        try FileManager.default.removeItem(at: damagedPackage.appendingPathComponent(transaction.record.fileName))

        let next = entry()
        let reopened = DownloadStorageCoordinator(store: store)
        _ = try await reopened.enqueue(next)
        let descriptor = try XCTUnwrap(next.resources?.first)
        let temporary = root.appendingPathComponent("another-system.tmp")
        try OfflineMediaFixture.validData().write(to: temporary)
        _ = try reopened.stageTemporaryFile(temporaryURL: temporary, metadata: next.metadata,
                                            resourceID: descriptor.id, transferID: descriptor.transferID)
        let recovered = try await reopened.restore()
        XCTAssertEqual(recovered.records.map(\.id), [next.id])
        XCTAssertTrue(try XCTUnwrap(recovered.records.first).isReadyToWatch)
        XCTAssertEqual(recovered.queue.first(where: { $0.id == damagedEntry.id })?.state, .failed)
        XCTAssertNotNil(recovered.queue.first(where: { $0.id == damagedEntry.id })?.reason)
        XCTAssertEqual(recovered.queue.first(where: { $0.id == damagedEntry.id })?.packagePlan?.movie, damagedEntry.packagePlan?.movie,
                       "Recovery preserves metadata in the durable job while retiring an unusable assembly")
        XCTAssertEqual(recovered.queue.first(where: { $0.id == damagedEntry.id })?.resources?.first?.state, .failed)
    }

    func testMissingInterruptedMediaCanBeReacquiredWithoutDownloadingItsSavedCaptionsAgain() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let original = entry(caption: true)
        let interrupted = DownloadStorageCoordinator(store: store) { boundary in
            if boundary == .packageMoved { throw DownloadStorageFailure.interrupted }
        }
        _ = try await interrupted.enqueue(original)
        _ = try await deliver(.media, entry: original, coordinator: interrupted, root: root)
        do { _ = try await deliver(.caption, entry: original, coordinator: interrupted, root: root) }
        catch DownloadStorageFailure.interrupted { }
        let transaction = try XCTUnwrap(store.stateStore.load().transactions.first)
        try FileManager.default.removeItem(at: store.rootDirectory.appendingPathComponent(transaction.destinationName)
            .appendingPathComponent(transaction.record.fileName))
        let reopened = DownloadStorageCoordinator(store: DownloadManifestStore(rootDirectory: store.rootDirectory))
        let restored = try await reopened.restore()
        var retry = try XCTUnwrap(restored.queue.first)
        XCTAssertEqual(retry.state, .failed)
        XCTAssertTrue(restored.transactions.isEmpty)
        let caption = try XCTUnwrap(retry.resources?.first(where: { $0.resource.kind == .caption }))
        XCTAssertEqual(caption.state, .delivered)
        let mediaIndex = try XCTUnwrap(retry.resources?.firstIndex(where: { $0.resource.kind == .media }))
        XCTAssertEqual(retry.resources?[mediaIndex].state, .failed)
        retry.resources?[mediaIndex].transferID = UUID()
        retry.resources?[mediaIndex].state = .queued
        retry.state = .queued
        _ = try await reopened.update(retry, expectedAttemptID: retry.metadata.attemptID)
        let completed = try await deliver(.media, entry: retry, coordinator: reopened, root: root)
        let record = try XCTUnwrap(completed.records.first)
        XCTAssertTrue(record.isReadyToWatch)
        XCTAssertEqual(record.localCaptions?.count, 1)
        XCTAssertEqual(completed.queue.first?.resources?.first(where: { $0.resource.kind == .caption })?.transferID, caption.transferID)
        let localCaption = try XCTUnwrap(record.localCaptions?.first)
        let captionURL = try XCTUnwrap(store.captionURL(for: record, caption: localCaption))
        XCTAssertEqual(try WebVTTParser.parse(Data(contentsOf: captionURL)).first?.text, "A synthetic offline subtitle")
    }

    func testPausedPackageRetainsArrivingMediaAndPublishesOnlyAfterResume() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let coordinator = DownloadStorageCoordinator(store: store)
        var entry = entry()
        _ = try await coordinator.enqueue(entry)
        entry.state = .paused
        _ = try await coordinator.update(entry, expectedAttemptID: entry.metadata.attemptID)
        let paused = try await deliver(.media, entry: entry, coordinator: coordinator, root: root)
        XCTAssertTrue(paused.records.isEmpty)
        XCTAssertEqual(paused.receipts.count, 1)
        var resumed = try XCTUnwrap(paused.queue.first)
        resumed.state = .queued
        _ = try await coordinator.update(resumed, expectedAttemptID: entry.metadata.attemptID)
        let saved = try await coordinator.finishAvailablePackage(recordID: entry.id)
        XCTAssertTrue(try XCTUnwrap(saved.records.first).isReadyToWatch)
        XCTAssertEqual(saved.queue.first?.state, .completed)
    }

    func testFailedOptionalArtworkDoesNotPreventSavingVerifiedVideoAndCaptions() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DownloadStorageCoordinator(store: DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline")))
        let entry = entry(caption: true, artwork: true)
        _ = try await coordinator.enqueue(entry)
        _ = try await deliver(.media, entry: entry, coordinator: coordinator, root: root)
        let waiting = try await deliver(.caption, entry: entry, coordinator: coordinator, root: root)
        var changed = try XCTUnwrap(waiting.queue.first)
        let artworkIndex = try XCTUnwrap(changed.resources?.firstIndex(where: { $0.resource.kind == .artwork }))
        changed.resources?[artworkIndex].state = .failed
        changed.resources?[artworkIndex].reason = "Artwork is unavailable."
        _ = try await coordinator.update(changed, expectedAttemptID: entry.metadata.attemptID)
        let saved = try await coordinator.finishAvailablePackage(recordID: entry.id)
        let record = try XCTUnwrap(saved.records.first)
        XCTAssertTrue(record.isReadyToWatch)
        XCTAssertEqual(record.localCaptions?.count, 1)
        XCTAssertNil(record.artworkPath)
        XCTAssertNotNil(record.artworkFailure)
    }

    @MainActor
    func testFiveHundredStoredMoviesRestoreWithoutBlockingTheMainActor() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = StorageReadBarrierFileManager()
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"), fileManager: files)
        try FileManager.default.createDirectory(at: store.rootDirectory, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("synthetic.mp4")
        let bytes = try OfflineMediaFixture.validData()
        try bytes.write(to: original)
        let metadata = entry().metadata
        let inspection = try await Task.detached {
            try store.inspectDownload(temporaryURL: original, metadata: metadata)
        }.value
        let records = try (0..<500).map { index -> DownloadRecord in
            let id = UUID()
            let name = "offline-\(id.uuidString.lowercased()).mp4"
            try FileManager.default.linkItem(at: original, to: store.rootDirectory.appendingPathComponent(name))
            return DownloadRecord(id: id, serverOrigin: "https://media.example.test", mediaID: String(index),
                                  title: "Synthetic Movie \(index)", kind: .compatible, fileName: name,
                                  byteCount: Int64(bytes.count), completedAt: Date(timeIntervalSince1970: Double(index)),
                                  durationSeconds: 2, resolution: "96x64", artworkPath: nil, assetInspection: inspection)
        }
        let clock = ContinuousClock()
        let encodeStart = clock.now
        let legacyData = try JSONEncoder().encode(DownloadManifest(records: records))
        let encodeElapsed = encodeStart.duration(to: clock.now)
        let decodeStart = clock.now
        XCTAssertEqual(try JSONDecoder().decode(DownloadManifest.self, from: legacyData).records.count, 500)
        let decodeElapsed = decodeStart.duration(to: clock.now)
        let saveStart = clock.now
        try store.stateStore.update { $0.records = records }
        let saveElapsed = saveStart.duration(to: clock.now)
        let enteredRead = expectation(description: "Actor entered actual index file I/O")
        files.arm { enteredRead.fulfill() }
        let coordinator = DownloadStorageCoordinator(store: store)
        let operation = Task { try await coordinator.restore() }
        await fulfillment(of: [enteredRead], timeout: 5)
        // Reaching here on the main actor while its storage operation is held
        // proves that UI event work can proceed during index file I/O.
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertFalse(files.readWasOnMainThread)
        XCTAssertFalse(files.readTimedOut)
        files.releaseRead()
        let restoreStart = clock.now
        let restored = try await operation.value
        let restoreElapsed = restoreStart.duration(to: clock.now)
        XCTAssertEqual(restored.records.count, 500)
        XCTAssertTrue(restored.records.allSatisfy(\.isReadyToWatch))
        print("STORAGE_BENCHMARK synthetic_records=500 legacy_encode=\(encodeElapsed) legacy_decode=\(decodeElapsed) atomic_save=\(saveElapsed) actor_restore=\(restoreElapsed) main_actor_progressed_during_io=true")
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func entry(caption: Bool = false, artwork: Bool = false) -> DownloadQueueEntry {
        var metadata = DownloadTaskMetadata(recordID: UUID(), serverOrigin: "https://media.example.test", mediaID: "42048",
                                            title: "The Synthetic Observatory", kind: .compatible, fileExtension: "mp4",
                                            durationSeconds: 2, resolution: "96x64", serverPath: "/web/media/42048.mp4?session=1&request=1",
                                            attemptID: UUID(), accountUsername: "package-viewer")
        var movie = MovieMetadata(mediaID: metadata.mediaID, title: metadata.title, durationSeconds: 2, resolution: metadata.resolution)
        movie.chapters = [MovieChapter(id: 0, title: "The Opening", startSeconds: 0, endSeconds: 1),
                          MovieChapter(id: 1, title: "The Arrival", startSeconds: 1, endSeconds: 2)]
        if caption {
            movie.captions = [MovieCaption(CaptionTrack(index: 0, label: "English", language: "en", default: false,
                                                       sourceFormat: "srt", browserSupported: true, url: "/Captions/42048/0.vtt?format=webvtt"))]
        }
        if artwork { movie.remoteArtworkPath = "/Artwork/42048.jpg" }
        metadata.movie = movie
        let plan = OfflinePackagePlan(metadata: metadata, movie: movie)
        var entry = DownloadQueueEntry(metadata: metadata)
        entry.packagePlan = plan
        entry.resources = plan.resources.map { DownloadResourceDescriptor(resource: $0) }
        return entry
    }

    private func deliver(_ kind: OfflineResourceKind, entry: DownloadQueueEntry, coordinator: DownloadStorageCoordinator,
                         root: URL) async throws -> DownloadStorageSnapshot {
        let descriptor = try XCTUnwrap(entry.resources?.first(where: { $0.resource.kind == kind }))
        let payload: Data
        switch kind {
        case .media: payload = try OfflineMediaFixture.validData()
        case .caption: payload = Data("WEBVTT\n\n00:00.000 --> 00:02.000\nA synthetic offline subtitle\n".utf8)
        case .artwork: payload = try artwork()
        }
        let incoming = root.appendingPathComponent("system-\(UUID().uuidString).tmp")
        try payload.write(to: incoming)
        let receipt = try coordinator.stageTemporaryFile(temporaryURL: incoming, metadata: entry.metadata,
                                                         resourceID: descriptor.id, transferID: descriptor.transferID,
                                                         expectedByteCount: Int64(payload.count))
        return try await coordinator.receive(receipt)
    }

    private func artwork() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private final class DeleteCommitFailureFileManager: FileManager, @unchecked Sendable {
    var failAfterDeleteMove = false
    var rejectDirectoryPreparation = false

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try super.moveItem(at: srcURL, to: dstURL)
        if failAfterDeleteMove, dstURL.lastPathComponent.hasPrefix("deleting-") { rejectDirectoryPreparation = true }
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if rejectDirectoryPreparation { throw CocoaError(.fileWriteOutOfSpace) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

private final class StorageReadBarrierFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var onRead: (() -> Void)?
    private var wasMainThread = false
    private var timedOut = false
    var readWasOnMainThread: Bool {
        lock.lock(); defer { lock.unlock() }
        return wasMainThread
    }
    var readTimedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }

    func arm(_ onRead: @escaping () -> Void) {
        lock.lock()
        self.onRead = onRead
        lock.unlock()
    }

    func releaseRead() { gate.signal() }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        lock.lock()
        let callback = (path as NSString).lastPathComponent == "state.json" ? onRead : nil
        if callback != nil {
            onRead = nil
            wasMainThread = Thread.isMainThread
        }
        lock.unlock()
        if let callback {
            callback()
            let result = gate.wait(timeout: .now() + 5) == .timedOut
            lock.lock()
            timedOut = result
            lock.unlock()
        }
        return try super.attributesOfItem(atPath: path)
    }
}

private final class ValidationRaceFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var watchedPath: String?
    private var callback: (() -> Void)?

    func arm(path: String, callback: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        watchedPath = path
        self.callback = callback
    }

    func releaseRead() { gate.signal() }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        let attributes = try super.attributesOfItem(atPath: path)
        lock.lock()
        let entered = watchedPath == path ? callback : nil
        if entered != nil { watchedPath = nil; callback = nil }
        lock.unlock()
        if let entered {
            entered()
            _ = gate.wait(timeout: .now() + 5)
        }
        return attributes
    }
}

private final class IndexReadDeniedFileManager: FileManager, @unchecked Sendable {
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if (path as NSString).lastPathComponent == "state.json" { throw CocoaError(.fileReadNoPermission) }
        return try super.attributesOfItem(atPath: path)
    }
}
