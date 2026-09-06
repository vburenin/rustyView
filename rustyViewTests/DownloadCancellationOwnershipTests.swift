import Foundation
import XCTest
@testable import rustyView

final class DownloadCancellationOwnershipTests: XCTestCase {
    func testCancellationBeforeTaskAssociationRollsBackAnInstallationAlreadyPastItsJournalCheck() async throws {
        let context = try makeContext()
        defer { context.releaseAndRemove() }
        let metadata = metadata()
        try context.queue.update(DownloadQueueEntry(metadata: metadata))
        let installing = Task.detached {
            try context.delegate.install(temporaryURL: context.incoming, metadata: metadata, taskIdentifier: 71)
        }
        await fulfillment(of: [context.files.moveEntered], timeout: 5)

        // No taskIdentifier association exists in this persisted intent. The
        // journal check already passed, so its tombstone alone is insufficient.
        try context.queue.update(DownloadQueueEntry(metadata: metadata, state: .removed))
        let started = expectation(description: "Logical cancellation entered its worker")
        let finished = CompletionFlag()
        let cancelling = Task.detached {
            started.fulfill()
            try context.delegate.discard(recordID: metadata.recordID)
            finished.mark()
        }
        await fulfillment(of: [started], timeout: 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(finished.value, "Cancellation must serialize with the installation already moving its file")
        context.files.releaseMove()
        let installationResult = try await installing.value
        let record = try XCTUnwrap(installationResult)
        try await cancelling.value

        XCTAssertFalse(context.delegate.acceptCompletion(taskIdentifier: 71, metadata: metadata, recordID: record.id))
        XCTAssertTrue(try DownloadManifestStore(rootDirectory: context.store.rootDirectory).loadValidated().records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.store.localURL(for: record).path))
        XCTAssertEqual(try context.queue.load().entries.first?.state, .removed)
    }

    func testOriginalRetryBeforeAssociationDiscardsOldInstallationBeforeInstallingReplacement() async throws {
        let context = try makeContext()
        defer { context.releaseAndRemove() }
        let original = metadata()
        try context.queue.update(DownloadQueueEntry(metadata: original))
        let installing = Task.detached {
            try context.delegate.install(temporaryURL: context.incoming, metadata: original, taskIdentifier: 81)
        }
        await fulfillment(of: [context.files.moveEntered], timeout: 5)
        var replacement = original
        replacement.attemptID = UUID()
        // Both original URL and retry budget remain the same. Only attempt
        // ownership distinguishes this explicit replacement after relaunch.
        try context.queue.update(DownloadQueueEntry(metadata: replacement))
        let started = expectation(description: "Attempt replacement entered its worker")
        let finished = CompletionFlag()
        let superseding = Task.detached {
            started.fulfill()
            try context.delegate.discard(metadata: original)
            finished.mark()
        }
        await fulfillment(of: [started], timeout: 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(finished.value, "The old attempt must finish rolling back before its replacement is launched")
        context.files.releaseMove()
        let installationResult = try await installing.value
        let oldRecord = try XCTUnwrap(installationResult)
        try await superseding.value
        XCTAssertFalse(context.delegate.acceptCompletion(taskIdentifier: 81, metadata: original, recordID: oldRecord.id))
        XCTAssertTrue(try context.store.load().records.isEmpty)

        let replacementURL = context.root.appendingPathComponent("replacement.tmp")
        let payload = try OfflineMediaFixture.validData()
        try payload.write(to: replacementURL)
        let newRecord = try XCTUnwrap(context.delegate.install(temporaryURL: replacementURL, metadata: replacement, taskIdentifier: 82))
        XCTAssertTrue(newRecord.isReadyToWatch)
        XCTAssertTrue(context.delegate.acceptCompletion(taskIdentifier: 82, metadata: replacement, recordID: newRecord.id))
        XCTAssertEqual(try DownloadManifestStore(rootDirectory: context.store.rootDirectory).loadValidated().records, [newRecord])
        XCTAssertEqual(try Data(contentsOf: context.store.localURL(for: newRecord)), payload)
        XCTAssertNil(try context.delegate.install(temporaryURL: context.root.appendingPathComponent("late-original.tmp"),
                                                  metadata: original, taskIdentifier: 83))
    }

    func testStaleCompletionCannotConsumeReplacementRollbackOwnershipAtReusedTaskNumber() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let queue = DownloadQueueStore(rootDirectory: store.rootDirectory)
        let delegate = DownloadSessionDelegate(store: store, queueStore: queue)
        let old = metadata()
        try delegate.discard(metadata: old)
        var current = old
        current.attemptID = UUID()
        try queue.update(DownloadQueueEntry(metadata: current))
        let incoming = root.appendingPathComponent("current.tmp")
        try OfflineMediaFixture.validData().write(to: incoming)
        let record = try XCTUnwrap(delegate.install(temporaryURL: incoming, metadata: current, taskIdentifier: 1))

        XCTAssertFalse(delegate.acceptCompletion(taskIdentifier: 1, metadata: old, recordID: old.recordID))
        try queue.update(DownloadQueueEntry(metadata: current, state: .removed))
        try delegate.discard(recordID: current.recordID)
        XCTAssertTrue(try DownloadManifestStore(rootDirectory: store.rootDirectory).loadValidated().records.isEmpty,
                      "The stale callback must leave the current attempt's file rollback ownership intact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.localURL(for: record).path))
    }

    func testDiscardingDuplicateDeliveryDoesNotDeleteAnAlreadyPublishedCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let delegate = DownloadSessionDelegate(store: store)
        let metadata = metadata()
        let payload = try OfflineMediaFixture.validData()
        let firstURL = root.appendingPathComponent("first.tmp")
        try payload.write(to: firstURL)
        let record = try XCTUnwrap(delegate.install(temporaryURL: firstURL, metadata: metadata, taskIdentifier: 11))
        XCTAssertTrue(delegate.acceptCompletion(taskIdentifier: 11, metadata: metadata, recordID: record.id))
        let duplicateURL = root.appendingPathComponent("duplicate.tmp")
        try payload.write(to: duplicateURL)
        XCTAssertEqual(try delegate.install(temporaryURL: duplicateURL, metadata: metadata, taskIdentifier: 12), record)
        try delegate.discard(taskIdentifier: 12)

        XCTAssertFalse(delegate.acceptCompletion(taskIdentifier: 12, metadata: metadata, recordID: record.id))
        XCTAssertEqual(try DownloadManifestStore(rootDirectory: store.rootDirectory).loadValidated().records, [record])
        XCTAssertEqual(try Data(contentsOf: store.localURL(for: record)), payload)
    }

    private func metadata() -> DownloadTaskMetadata {
        DownloadTaskMetadata(
            recordID: UUID(), serverOrigin: "https://media.example.test", mediaID: "42046",
            title: "The Synthetic Clocktower", kind: .original, fileExtension: "mp4",
            durationSeconds: 2, resolution: "96x64", serverPath: "/web/download/42046",
            retryAttempt: 0, attemptID: UUID(), accountUsername: "fixture-viewer"
        )
    }

    private func makeContext() throws -> InstallationContext {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let incoming = root.appendingPathComponent("system-download.tmp")
        try OfflineMediaFixture.validData().write(to: incoming)
        let files = MovePausedFileManager(source: incoming)
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"), fileManager: files)
        let queue = DownloadQueueStore(rootDirectory: store.rootDirectory)
        return InstallationContext(root: root, incoming: incoming, files: files, store: store,
                                   queue: queue, delegate: DownloadSessionDelegate(store: store, queueStore: queue))
    }
}

private struct InstallationContext: @unchecked Sendable {
    let root: URL
    let incoming: URL
    let files: MovePausedFileManager
    let store: DownloadManifestStore
    let queue: DownloadQueueStore
    let delegate: DownloadSessionDelegate

    func releaseAndRemove() {
        files.releaseMove()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class MovePausedFileManager: FileManager, @unchecked Sendable {
    let moveEntered = XCTestExpectation(description: "Real installation reached its atomic file move")
    private let source: URL
    private let gate = DispatchSemaphore(value: 0)

    init(source: URL) { self.source = source; super.init() }

    func releaseMove() { gate.signal() }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL == source {
            moveEntered.fulfill()
            guard gate.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileWriteUnknown) }
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return completed }
    func mark() { lock.lock(); defer { lock.unlock() }; completed = true }
}
