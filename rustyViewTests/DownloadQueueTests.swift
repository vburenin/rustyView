import Foundation
import Network
import Combine
import XCTest
@testable import rustyView

@MainActor
final class DownloadQueueTests: XCTestCase {
    func testCaptionDeliveryAndOptionalArtworkFailurePreserveRealMediaByteProgress() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A real larger movie crosses URLSession's buffered file-write threshold
        // before the server releases its final chunk. The 22 KB inspection
        // fixture can hold only 7 KB here, which yields no native progress event.
        let mediaURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-native-tracks", withExtension: "mp4"))
        let payload = try Data(contentsOf: mediaURL)
        let server = try QueueHTTPServer(payload: payload, status: 200,
                                         holdMediaAndCaptions: true, failFirstMediaRequest: true)
        let address = try await server.start()
        defer { server.stop() }
        let owner = try ServerConnection(serverAddress: address, username: "queue-viewer", password: "synthetic-secret")
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(owner)
        let item = try JSONDecoder().decode(ItemResponse.self, from: Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)).item
        let manager = await manager(root)
        var measuredLengths: [Int64] = []
        var phases: [DownloadPhase] = []
        let observation = manager.$active.sink { rows in
            if let phase = rows.first?.phase { phases.append(phase) }
            if case .downloading(_, _, let expected) = rows.first?.phase, let expected {
                measuredLengths.append(expected)
            }
        }
        defer { observation.cancel() }
        manager.configure(connection: owner)
        try manager.start(item: item, kind: .compatible, client: client)
        try await waitUntil {
            if case .downloading(_, let received, let expected) = manager.active.first?.phase {
                return received > 0 && received < Int64(payload.count) && expected == Int64(payload.count)
                    && server.hasHeldCaption && server.mediaRequests.count == 2
                    && manager.active.first?.metadata.retryAttempt == 1
            }
            return false
        }
        guard case .downloading(_, let beforeCaption, _) = try XCTUnwrap(manager.active.first?.phase) else {
            return XCTFail("The real media response must produce native byte progress before caption delivery")
        }
        XCTAssertEqual(manager.active.first?.metadata.retryAttempt, 1,
                       "Actual transfer progress must supersede the scheduled retry presentation without resetting its budget")
        let phaseBoundary = phases.count
        server.releaseCaptions()
        try await waitUntil {
            guard let resources = try? DownloadQueueStore(rootDirectory: root).load().entries.first?.resources else { return false }
            return resources.first(where: { $0.resource.kind == .caption })?.state == .delivered
                && resources.first(where: { $0.resource.kind == .artwork })?.state == .failed
        }
        await manager.waitForPendingOperations()
        let auxiliaryPhases = phases.dropFirst(phaseBoundary)
        XCTAssertFalse(auxiliaryPhases.isEmpty)
        XCTAssertTrue(auxiliaryPhases.allSatisfy { phase in
            if case .downloading(_, let received, let expected) = phase {
                return received >= beforeCaption && received < Int64(payload.count) && expected == Int64(payload.count)
            }
            return false
        }, "Saving a sidecar must never replace actual byte progress with Queued, Retry, or Saving")
        XCTAssertTrue(manager.completed.isEmpty, "The fixture still holds the rest of the media response")
        XCTAssertFalse(measuredLengths.isEmpty)
        XCTAssertTrue(measuredLengths.allSatisfy { $0 == Int64(payload.count) },
                      "An HTTP error body's bytes must never appear as movie download progress")
        XCTAssertEqual(server.mediaRequests.count, 2)
        manager.cancel(try XCTUnwrap(manager.active.first))
        await manager.waitForPendingOperations()
    }

    func testRealHTTPFailureRelaunchAndRetryInstallsOneCopyUsingTheOwnedAccount() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try QueueHTTPServer(payload: OfflineMediaFixture.validData(), status: 401)
        let address = try await server.start()
        defer { server.stop() }
        let owner = try ServerConnection(serverAddress: address, username: "queue-viewer", password: "synthetic-secret")
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(owner)
        let item = try JSONDecoder().decode(ItemResponse.self, from: Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)).item
        var first: DownloadManager? = await manager(root)
        first?.configure(connection: owner, statusClient: client)
        try first?.start(item: item, kind: .compatible, client: client, quality: "720p", audioIndex: 1)
        try await waitUntil { first?.active.first.map { if case .failed = $0.phase { return true }; return false } == true }
        let failed = try XCTUnwrap(first?.active.first)
        XCTAssertEqual(failed.failure?.category, .authentication)
        XCTAssertEqual(failed.failure?.recoveryActions(), [.editConnection])
        guard case .failed(let reason) = failed.phase else { return XCTFail("HTTP 401 must fail visibly") }
        XCTAssertFalse(reason.isEmpty, "HTTP authentication failure must offer an explanation")
        first = nil

        let reopened = await manager(root)
        XCTAssertEqual(reopened.active.first?.id, failed.id)
        XCTAssertEqual(reopened.active.first?.phase, failed.phase)
        XCTAssertEqual(reopened.active.first?.failure, failed.failure, "Authentication recovery must survive journal restoration")
        let wrongAccount = try ServerConnection(serverAddress: address, username: "other-viewer", password: "other-secret")
        reopened.configure(connection: wrongAccount)
        let before = server.mediaRequests.count
        reopened.retry(try XCTUnwrap(reopened.active.first))
        await reopened.waitForPendingOperations()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.mediaRequests.count, before, "Retry may never adopt another account's credentials")

        server.setStatus(200)
        try server.expirePreparedRequest(try XCTUnwrap(failed.metadata.serverPath))
        reopened.configure(connection: owner)
        reopened.retry(try XCTUnwrap(reopened.active.first))
        await reopened.waitForPendingOperations()
        try await waitUntil { reopened.completed.count == 1 }
        let record = try XCTUnwrap(reopened.completed.first)
        XCTAssertTrue(record.isReadyToWatch)
        XCTAssertTrue(reopened.active.isEmpty)
        XCTAssertEqual(record.accountUsername, "queue-viewer")
        XCTAssertEqual(record.qualityID, "720p")
        XCTAssertEqual(record.audioTrackIndex, 1)
        XCTAssertEqual(record.id, failed.id)
        let mediaRequests = server.mediaRequests
        XCTAssertEqual(mediaRequests.count, before + 1, "User retry must create one additional media request and one installed copy")
        XCTAssertTrue(mediaRequests.allSatisfy { $0.authorization == owner.authorizationHeader() })
        XCTAssertTrue(mediaRequests.allSatisfy { $0.target.contains("quality=720p") && $0.target.contains("audio=1") })
        let firstIdentity = try XCTUnwrap(mediaRequests.first?.preparedIdentity)
        let retriedIdentity = try XCTUnwrap(mediaRequests.last?.preparedIdentity)
        XCTAssertEqual(retriedIdentity.session, firstIdentity.session)
        XCTAssertGreaterThan(retriedIdentity.generation, firstIdentity.generation,
                             "An expired prepared producer must be replaced instead of reopening its tombstone")
        try await waitUntil { server.cancellations.contains { $0.preparedIdentity == firstIdentity } }
        XCTAssertTrue(server.cancellations.allSatisfy { $0.authorization == owner.authorizationHeader() })
        XCTAssertFalse(server.cancellations.contains { $0.preparedIdentity == retriedIdentity })
        let final = await manager(root)
        XCTAssertTrue(final.active.isEmpty)
        XCTAssertEqual(final.completed.map(\.id), [record.id])
    }

    func testRealInstallationOutOfSpaceFailureSurvivesRelaunchAndCanRetry() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try QueueHTTPServer(payload: OfflineMediaFixture.validData(), status: 200)
        let address = try await server.start()
        defer { server.stop() }
        let owner = try ServerConnection(serverAddress: address, username: "queue-viewer", password: "synthetic-secret")
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(owner)
        let item = try JSONDecoder().decode(ItemResponse.self, from: Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)).item
        let disk = QueueOutOfSpaceFileManager()
        let first = DownloadManager(store: DownloadManifestStore(rootDirectory: root, fileManager: disk),
                                    sessionIdentifier: "queue-tests.\(UUID().uuidString)", sessionConfiguration: .ephemeral)
        first.configure(connection: owner)
        try first.start(item: item, kind: .compatible, client: client)
        try await waitUntil { first.active.first.map { if case .failed = $0.phase { return true }; return false } == true }
        let phase = try XCTUnwrap(first.active.first?.phase)
        XCTAssertEqual(first.active.first?.failure?.category, .storage)
        XCTAssertTrue(first.active.first?.failure?.recoveryActions().contains(.manageStorage) == true)
        XCTAssertTrue(first.completed.isEmpty)
        XCTAssertTrue(disk.rejectedInstallation, "The fault must happen during the real temporary-file installation")
        let reopened = await manager(root)
        XCTAssertEqual(reopened.active.first?.phase, phase)
        XCTAssertEqual(reopened.active.first?.failure?.category, .storage)
        reopened.configure(connection: owner)
        reopened.retry(try XCTUnwrap(reopened.active.first))
        await reopened.waitForPendingOperations()
        try await waitUntil { reopened.completed.count == 1 }
        XCTAssertTrue(try XCTUnwrap(reopened.completed.first).isReadyToWatch)
        XCTAssertTrue(reopened.active.isEmpty)
    }

    func testInterruptedEnqueueCreatesOneAuthenticatedTaskWithRetainedChoices() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = metadata()
        try DownloadQueueStore(rootDirectory: root).update(DownloadQueueEntry(metadata: metadata))
        let reachedTransport = expectation(description: "Recovered intent reached URL loading")
        var receivedRequests: [URLRequest] = []
        QueueHoldingProtocol.handler = { request in
            Task { @MainActor in
                receivedRequests.append(request)
                if receivedRequests.count == 1 { reachedTransport.fulfill() }
            }
        }
        defer { QueueHoldingProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QueueHoldingProtocol.self]
        let manager = DownloadManager(store: DownloadManifestStore(rootDirectory: root),
                                      sessionIdentifier: "queue-tests.\(UUID().uuidString)", sessionConfiguration: configuration)
        let owner = try connection(username: "first-viewer")
        manager.configure(connection: owner)
        await fulfillment(of: [reachedTransport], timeout: 3)
        let request = try XCTUnwrap(receivedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), owner.authorizationHeader())
        XCTAssertEqual(request.url?.path, "/web/media/42043.mp4")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "audio" })?.value, "2")
        XCTAssertEqual(query?.first(where: { $0.name == "quality" })?.value, "720p")
        manager.configure(connection: owner)
        manager.configure(connection: owner)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(receivedRequests.count, 1, "Repeated reconnect must attach to the existing task")
        XCTAssertEqual(manager.active.count, 1)
        XCTAssertEqual(try DownloadQueueStore(rootDirectory: root).load().entries.first?.taskIdentifier,
                       manager.active.first?.taskIdentifier)
        for download in manager.active { manager.cancel(download) }
    }

    /// These faults used to disappear as soon as URLSession discarded the failed
    /// task: only the in-memory active array retained the request and its choices.
    func testPermanentHTTPFailuresAndExhaustedRetriesSurviveRelaunchWithoutSystemTasks() async throws {
        for status in [401, 404, 503] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let metadata = metadata(attempt: status == 503 ? DownloadRetryPolicy.maximumAttempts : 0)
            let task = try suspendedTask(metadata, session: session)
            let manager = await manager(root)
            manager.restore(tasks: [task])
            await manager.waitForPendingOperations()
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(task.originalRequest?.url), statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            ))
            manager.handleFailure(taskIdentifier: task.taskIdentifier,
                                  message: try XCTUnwrap(DownloadResponseValidator.failure(for: response)),
                                  retryable: DownloadResponseValidator.isRetryable(response))
            await manager.waitForPendingOperations()
            let original = try XCTUnwrap(manager.active.first)
            guard case .failed = original.phase else { return XCTFail("Fault must offer manual recovery") }

            let reopened = await self.manager(root)
            reopened.restore(tasks: [])
            await reopened.waitForPendingOperations()
            XCTAssertEqual(reopened.active.count, 1)
            XCTAssertEqual(reopened.active.first?.metadata, metadata)
            XCTAssertEqual(reopened.active.first?.phase, original.phase)
            reopened.restore(tasks: [])
            await reopened.waitForPendingOperations()
            XCTAssertEqual(reopened.active.count, 1, "Repeated reconciliation must be idempotent")
        }
    }

    func testInstallationFailureRemainsVisibleAfterRelaunch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = try suspendedTask(metadata(), session: session)
        let manager = await manager(root)
        manager.restore(tasks: [task])
        await manager.waitForPendingOperations()
        manager.update(taskIdentifier: task.taskIdentifier, phase: .finishing)
        let diskFailure = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        manager.handleFailure(taskIdentifier: task.taskIdentifier, message: diskFailure.localizedDescription, retryable: false)
        await manager.waitForPendingOperations()
        let reopened = await self.manager(root)
        reopened.restore(tasks: [])
        await reopened.waitForPendingOperations()
        XCTAssertEqual(reopened.active.first?.phase, .failed(message: diskFailure.localizedDescription))
        XCTAssertTrue(reopened.completed.isEmpty)
    }

    func testIntentCommittedBeforeTaskCreationSurvivesAndDoesNotAdoptAnAccount() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = metadata()
        try DownloadQueueStore(rootDirectory: root).update(DownloadQueueEntry(metadata: metadata))
        let reopened = await manager(root)
        XCTAssertEqual(reopened.active.first?.metadata, metadata)
        reopened.restore(tasks: [])
        await reopened.waitForPendingOperations()
        XCTAssertEqual(reopened.active.count, 1)
        XCTAssertEqual(reopened.active.first?.metadata.accountUsername, "first-viewer")
        XCTAssertEqual(try DownloadQueueStore(rootDirectory: root).load().entries.first?.state, .waiting)
        XCTAssertFalse(DownloadOwnership.matches(metadata, connection: try connection(username: "second-viewer")))
        XCTAssertTrue(DownloadOwnership.matches(metadata, connection: try connection(username: "first-viewer")))
    }

    func testTaskCreatedBeforeAssociationIsRecoveredOnceAndRetainsRetryDate() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let metadata = metadata(attempt: 4)
        let scheduled = Date().addingTimeInterval(600)
        try DownloadQueueStore(rootDirectory: root).update(
            DownloadQueueEntry(metadata: metadata, scheduledAt: scheduled, reason: "Service unavailable")
        )
        let task = try suspendedTask(metadata, session: session)
        let duplicate = try suspendedTask(metadata, session: session)
        let reopened = await manager(root)
        reopened.restore(tasks: [task, duplicate])
        await reopened.waitForPendingOperations()
        reopened.restore(tasks: [task, duplicate])
        await reopened.waitForPendingOperations()
        XCTAssertEqual(reopened.active.count, 1)
        XCTAssertEqual(reopened.active.first?.taskIdentifier, task.taskIdentifier)
        XCTAssertTrue(duplicate.state == .canceling || duplicate.state == .completed)
        XCTAssertEqual(reopened.active.first?.phase,
                       .retrying(attempt: 4, scheduledAt: scheduled, reason: "Service unavailable"))
        XCTAssertEqual(try DownloadQueueStore(rootDirectory: root).load().entries.first?.taskIdentifier,
                       task.taskIdentifier)
    }

    func testReconciliationKeepsReplacementWhenAnOlderAttemptHasNotFinishedDisappearing() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let originalMetadata = metadata()
        let older = try suspendedTask(originalMetadata, session: session)
        var replacementMetadata = originalMetadata
        replacementMetadata.retryAttempt = 1
        let replacement = try suspendedTask(replacementMetadata, session: session)
        // Crash after creating the replacement but before taskIdentifier save:
        // URLSession can still return both tasks for this one logical request.
        try DownloadQueueStore(rootDirectory: root).update(DownloadQueueEntry(metadata: replacementMetadata))
        let reopened = await manager(root)
        reopened.restore(tasks: [older, replacement])
        await reopened.waitForPendingOperations()
        XCTAssertEqual(reopened.active.count, 1)
        XCTAssertEqual(reopened.active.first?.taskIdentifier, replacement.taskIdentifier)
        XCTAssertEqual(reopened.active.first?.metadata.retryAttempt, 1)
        XCTAssertTrue(older.state == .canceling || older.state == .completed)
        XCTAssertEqual(replacement.state, .suspended)
    }

    func testPersistedTaskNumbersCannotStealProgressFromANewSessionTask() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldMetadata = metadata()
        try DownloadQueueStore(rootDirectory: root).update(
            DownloadQueueEntry(metadata: oldMetadata, state: .failed, taskIdentifier: 1, reason: "Earlier failure")
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let newMetadata = metadata(mediaID: "42044")
        let newTask = try suspendedTask(newMetadata, session: session)
        let reopened = await manager(root)
        XCTAssertEqual(reopened.active.first?.taskIdentifier, -1, "An old task number is unconfirmed until restoration")
        reopened.restore(tasks: [newTask])
        await reopened.waitForPendingOperations()
        reopened.update(taskIdentifier: newTask.taskIdentifier, phase: .downloading(progress: 0.5, received: 500, expected: 1_000))
        XCTAssertEqual(reopened.active.first(where: { $0.id == oldMetadata.recordID })?.phase, .failed(message: "Earlier failure"))
        XCTAssertEqual(reopened.active.first(where: { $0.id == newMetadata.recordID })?.phase,
                       .downloading(progress: 0.5, received: 500, expected: 1_000))
    }

    func testOriginalRetryRejectsPreviousAttemptAfterRelaunchEvenWhenURLAndRetryBudgetMatch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var original = DownloadTaskMetadata(recordID: UUID(), serverOrigin: "https://media.example.test", mediaID: "42045",
                                            title: "The Synthetic Lighthouse", kind: .original, fileExtension: "mp4",
                                            durationSeconds: 2, resolution: "96x64", serverPath: "/web/download/42045",
                                            retryAttempt: 0, accountUsername: "first-viewer")
        original.attemptID = UUID()
        let oldTask = try suspendedTask(original, session: session)
        var replacement = original
        replacement.attemptID = UUID()
        let newTask = try suspendedTask(replacement, session: session)
        // Manual retry restarts its retry budget but remains a distinct attempt.
        try DownloadQueueStore(rootDirectory: root).update(DownloadQueueEntry(metadata: replacement))
        let reopened = await manager(root)
        reopened.restore(tasks: [oldTask, newTask])
        await reopened.waitForPendingOperations()
        XCTAssertEqual(reopened.active.first?.taskIdentifier, newTask.taskIdentifier)
        XCTAssertTrue(oldTask.state == .canceling || oldTask.state == .completed)
        let delegate = DownloadSessionDelegate(store: DownloadManifestStore(rootDirectory: root),
                                               queueStore: DownloadQueueStore(rootDirectory: root))
        XCTAssertNil(try delegate.install(temporaryURL: root.appendingPathComponent("old-temporary-file"),
                                          metadata: original, taskIdentifier: oldTask.taskIdentifier),
                     "A prior attempt must be rejected before media inspection or installation after process relaunch")
    }

    func testRemovedFailureCannotBeReimportedOrInstalledByLateTask() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let metadata = metadata()
        let task = try suspendedTask(metadata, session: session)
        let manager = await manager(root)
        manager.restore(tasks: [task])
        await manager.waitForPendingOperations()
        manager.handleFailure(taskIdentifier: task.taskIdentifier, message: "No longer available", retryable: false)
        await manager.waitForPendingOperations()
        manager.dismissFailure(try XCTUnwrap(manager.active.first))
        await manager.waitForPendingOperations()
        let reopened = await self.manager(root)
        reopened.restore(tasks: [task])
        await reopened.waitForPendingOperations()
        XCTAssertTrue(reopened.active.isEmpty)
        let store = DownloadManifestStore(rootDirectory: root)
        let delegate = DownloadSessionDelegate(store: store, queueStore: DownloadQueueStore(rootDirectory: root))
        let missingTemporaryFile = root.appendingPathComponent("late-download")
        XCTAssertNil(try delegate.install(temporaryURL: missingTemporaryFile, metadata: metadata,
                                          taskIdentifier: task.taskIdentifier))
        XCTAssertTrue(try store.load().records.isEmpty)
    }

    func testDeletingCompletedCopyPersistsItsRemovalAgainstLateRelaunchCallbacks() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadata = metadata()
        let incoming = root.appendingPathComponent("completed.tmp")
        try OfflineMediaFixture.validData().write(to: incoming)
        let store = DownloadManifestStore(rootDirectory: root)
        let record = try store.install(temporaryURL: incoming, metadata: metadata)
        let manager = await manager(root)
        manager.delete(record)
        await manager.waitForPendingOperations()
        XCTAssertTrue(manager.completed.isEmpty)
        let reopened = await self.manager(root)
        XCTAssertTrue(reopened.completed.isEmpty)
        XCTAssertTrue(reopened.active.isEmpty)
        let lateDelegate = DownloadSessionDelegate(store: store, queueStore: DownloadQueueStore(rootDirectory: root))
        XCTAssertNil(try lateDelegate.install(temporaryURL: root.appendingPathComponent("late-copy.tmp"),
                                              metadata: metadata, taskIdentifier: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.localURL(for: record).path))
    }

    func testLegacyMetadataNeverReceivesCurrentAccountCredentials() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var metadata = metadata()
        metadata.accountUsername = nil
        let task = try suspendedTask(metadata, session: session)
        let manager = await manager(root)
        manager.restore(tasks: [task])
        await manager.waitForPendingOperations()
        manager.handleFailure(taskIdentifier: task.taskIdentifier, message: "Sign in", retryable: false)
        await manager.waitForPendingOperations()
        manager.retry(try XCTUnwrap(manager.active.first))
        await manager.waitForPendingOperations()
        XCTAssertNil(manager.active.first?.metadata.accountUsername)
        XCTAssertFalse(DownloadOwnership.matches(metadata, connection: try connection(username: "first-viewer")))
        XCTAssertEqual(manager.active.first?.phase, .failed(message: DownloadQueueError.missingOwnership.localizedDescription))
        XCTAssertNil(try DownloadQueueStore(rootDirectory: root).load().entries.first?.metadata.accountUsername)
    }

    func testCorruptQueueIsReportedAndCannotBeOverwrittenByTaskRestoration() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let broken = Data(#"{"schemaVersion":99,"entries":[]}"#.utf8)
        try broken.write(to: root.appendingPathComponent("queue.json"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let manager = await manager(root)
        manager.restore(tasks: [try suspendedTask(metadata(), session: session)])
        await manager.waitForPendingOperations()
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertTrue(manager.storageRecoveryAvailable)
        XCTAssertFalse(manager.storageRetryAvailable)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("queue.json")), broken)
        XCTAssertTrue(manager.active.isEmpty)
    }

    func testStartupScanFailureRetainsReadableQueueAndOffersRetryWithoutRebuilding() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let intent = DownloadQueueEntry(metadata: metadata(), state: .paused)
        try DownloadQueueStore(rootDirectory: root).update(intent)
        let saved = try Data(contentsOf: root.appendingPathComponent("state.json"))
        let files = QueueRestoreScanFailureFileManager()
        let manager = DownloadManager(store: DownloadManifestStore(rootDirectory: root, fileManager: files),
                                      sessionIdentifier: "queue-tests.\(UUID().uuidString)", sessionConfiguration: .ephemeral)
        await manager.waitForPendingOperations()
        XCTAssertTrue(manager.storageRetryAvailable)
        XCTAssertFalse(manager.storageRecoveryAvailable, "A readable queue cannot be replaced by a records-only recovery")
        XCTAssertEqual(manager.active.first?.id, intent.id)
        XCTAssertNotNil(manager.errorMessage)
        manager.recoverStorageIndex()
        await manager.waitForPendingOperations()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("state.json")), saved,
                       "A stale recovery action must not erase readable intent")
        files.allowDirectoryReads()
        manager.retryStorageRestoration()
        await manager.waitForPendingOperations()
        XCTAssertFalse(manager.storageRetryAvailable)
        XCTAssertFalse(manager.storageRecoveryAvailable)
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.active.first?.id, intent.id)
        XCTAssertEqual(try DownloadQueueStore(rootDirectory: root).load().entries.first?.state, .paused)
    }

    func testFailedRestorationSaveShowsRecoveryAndRetainsTheSystemTasksOnlyDurableMetadata() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = await manager(root)
        let journalURL = root.appendingPathComponent("state.json")
        // A real filesystem failure after manager initialization makes atomic
        // journal persistence unavailable without replacing URLSession behavior.
        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let metadata = metadata()
        let task = try suspendedTask(metadata, session: session)
        manager.restore(tasks: [task])
        await manager.waitForPendingOperations()
        manager.restore(tasks: [task])
        await manager.waitForPendingOperations()
        XCTAssertEqual(manager.active.count, 1)
        guard case .failed = manager.active.first?.phase else { return XCTFail("A save failure must offer recovery") }
        XCTAssertEqual(task.state, .suspended, "Cancelling would destroy pre-journal work's only persisted intent")
        XCTAssertEqual(DownloadSessionDelegate.metadata(for: task), metadata)
        XCTAssertNotNil(manager.errorMessage)
        try FileManager.default.removeItem(at: journalURL)
        manager.restore(tasks: [task])
        await manager.waitForPendingOperations()
        let reopened = await self.manager(root)
        XCTAssertEqual(reopened.active.first?.metadata, metadata)
        guard case .failed = reopened.active.first?.phase else { return XCTFail("Repairing storage must preserve the failure row") }
    }

    private func manager(_ root: URL) async -> DownloadManager {
        let manager = DownloadManager(store: DownloadManifestStore(rootDirectory: root),
                        sessionIdentifier: "queue-tests.\(UUID().uuidString)", sessionConfiguration: .ephemeral)
        await manager.waitForPendingOperations()
        return manager
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("queue-tests-\(UUID().uuidString)")
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "The real download did not reach the expected state before the bounded deadline")
    }

    private func connection(username: String) throws -> ServerConnection {
        try ServerConnection(serverAddress: "https://MEDIA.example.test:443/", username: username, password: "synthetic")
    }

    private func metadata(attempt: Int = 0, mediaID: String = "42043") -> DownloadTaskMetadata {
        var value = DownloadTaskMetadata(recordID: UUID(), serverOrigin: "https://media.example.test", mediaID: mediaID,
                                        title: "The Clockwork Lagoon", kind: .compatible, fileExtension: "mp4",
                                        durationSeconds: 1800, resolution: "1280x720", serverPath: "/web/media/42043.mp4?quality=720p&audio=2",
                                        retryAttempt: attempt, qualityID: "720p", qualityLabel: "Data saver",
                                        audioTrackIndex: 2, audioTrackLabel: "Invented alternate language")
        value.accountUsername = "first-viewer"
        return value
    }

    private func suspendedTask(_ metadata: DownloadTaskMetadata, session: URLSession) throws -> URLSessionDownloadTask {
        let task = session.downloadTask(with: try XCTUnwrap(URL(string: "https://media.example.test/web/media/42043.mp4")))
        task.taskDescription = String(data: try JSONEncoder().encode(metadata), encoding: .utf8)
        return task
    }
}

final class QueueHoldingProtocol: URLProtocol {
    static var handler: ((URLRequest) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request) }
    override func stopLoading() {}
}

private final class QueueOutOfSpaceFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = false
    var rejectedInstallation: Bool { lock.lock(); defer { lock.unlock() }; return rejected }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.lastPathComponent.hasPrefix("offline-") {
            lock.lock()
            rejected = true
            lock.unlock()
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class QueueRestoreScanFailureFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var rejectsReads = true

    func allowDirectoryReads() { lock.lock(); rejectsReads = false; lock.unlock() }

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                     options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        lock.lock()
        let rejects = rejectsReads
        lock.unlock()
        if rejects { throw CocoaError(.fileReadNoPermission) }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}

/// A real loopback HTTP boundary: URLSession owns its temporary file and invokes
/// the production delegate exactly as it does for a remote service.
private final class QueueHTTPServer: @unchecked Sendable {
    struct Request {
        let method: String
        let target: String
        let authorization: String?

        var preparedIdentity: PreparedPlaybackIdentity? {
            let items = URLComponents(string: target)?.queryItems
            guard let session = items?.first(where: { $0.name == "session" })?.value.flatMap(UInt64.init),
                  let generation = items?.first(where: { $0.name == "request" })?.value.flatMap(UInt64.init) else { return nil }
            return PreparedPlaybackIdentity(session: session, generation: generation)
        }
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "queue-tests.http")
    private let lock = NSLock()
    private let payload: Data
    private let expectedAuthorization = "Basic " + Data("queue-viewer:synthetic-secret".utf8).base64EncodedString()
    private var status: Int
    private var captured: [Request] = []
    private var expiredGenerations: [UInt64: UInt64] = [:]
    private var connections: [NWConnection] = []
    private let holdMediaAndCaptions: Bool
    private let failFirstMediaRequest: Bool
    private var heldCaptions: [(NWConnection, Data)] = []

    init(payload: Data, status: Int, holdMediaAndCaptions: Bool = false, failFirstMediaRequest: Bool = false) throws {
        self.payload = payload
        self.status = status
        self.holdMediaAndCaptions = holdMediaAndCaptions
        self.failFirstMediaRequest = failFirstMediaRequest
        listener = try NWListener(using: .tcp, on: .any)
    }

    var hasHeldCaption: Bool { lock.lock(); defer { lock.unlock() }; return !heldCaptions.isEmpty }

    func releaseCaptions() {
        queue.async { [self] in
            lock.lock()
            let pending = heldCaptions
            heldCaptions.removeAll()
            lock.unlock()
            for (connection, bytes) in pending {
                connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    var mediaRequests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return captured.filter { $0.target.hasPrefix("/web/media/") }
    }

    var cancellations: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return captured.filter { $0.method == "DELETE" && $0.target.hasPrefix("/api/web/transcode/") }
    }

    func expirePreparedRequest(_ path: String) throws {
        let identity = try XCTUnwrap(Request(method: "GET", target: path, authorization: nil).preparedIdentity)
        lock.lock()
        expiredGenerations[identity.session] = identity.generation
        lock.unlock()
    }

    func setStatus(_ value: Int) {
        lock.lock()
        status = value
        lock.unlock()
    }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, let port = self.listener.port else { return }
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: "http://127.0.0.1:\(port.rawValue)")
                case .failed(let error):
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            if let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") {
                self.respond(connection, request: text)
            } else if complete || error != nil || bytes.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(connection, accumulated: bytes)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let lines = request.components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let method = lines.first?.split(separator: " ").first.map(String.init) ?? "GET"
        let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }?
            .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        lock.lock()
        let capturedRequest = Request(method: method, target: target, authorization: authorization)
        captured.append(capturedRequest)
        let identity = capturedRequest.preparedIdentity
        let isCancellation = method == "DELETE" && target.hasPrefix("/api/web/transcode/")
        if isCancellation, authorization == expectedAuthorization, let identity {
            expiredGenerations[identity.session] = max(expiredGenerations[identity.session] ?? 0, identity.generation)
        }
        let expired = identity.map { $0.generation <= (expiredGenerations[$0.session] ?? 0) } ?? false
        let responseStatus: Int
        if authorization != expectedAuthorization { responseStatus = 401 }
        else if isCancellation { responseStatus = 200 }
        else if target.hasPrefix("/api/") { responseStatus = 404 }
        else if expired { responseStatus = 409 }
        else if failFirstMediaRequest, target.hasPrefix("/web/media/"),
                captured.filter({ $0.target.hasPrefix("/web/media/") }).count == 1 { responseStatus = 503 }
        else { responseStatus = status }
        lock.unlock()
        let body: Data
        if isCancellation, responseStatus == 200 {
            body = Data("{\"schema_version\":2,\"item_id\":\"42001\",\"state\":\"cancelled\",\"request_id\":\(identity?.generation ?? 0)}".utf8)
        } else if responseStatus == 200, target.hasPrefix("/Captions/") {
            body = Data("WEBVTT\n\n00:00.000 --> 00:01.500\nA synthetic queue caption.\n".utf8)
        } else {
            body = responseStatus == 200 ? payload : Data(#"{"error":"synthetic failure"}"#.utf8)
        }
        let type = responseStatus == 200 && !isCancellation ? "video/mp4" : "application/json"
        let challenge = responseStatus == 401 ? "WWW-Authenticate: Basic realm=\"Synthetic queue\"\r\n" : ""
        let header = "HTTP/1.1 \(responseStatus) Test Response\r\n\(challenge)Content-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var bytes = Data(header.utf8)
        if holdMediaAndCaptions, responseStatus == 200, target.hasPrefix("/web/media/") {
            bytes.append(body.prefix(max(1, body.count / 3)))
            connection.send(content: bytes, completion: .contentProcessed { _ in })
            return
        }
        bytes.append(body)
        if holdMediaAndCaptions, responseStatus == 200, target.hasPrefix("/Captions/") {
            lock.lock()
            heldCaptions.append((connection, bytes))
            lock.unlock()
            return
        }
        connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}
