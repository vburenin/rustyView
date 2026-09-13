import Foundation
import Network
import Security
import XCTest
@testable import rustyView

@MainActor
final class DownloadResumeTests: XCTestCase {
    func testGrowingPrefixSurvivesPauseRelaunchAndCompletesWithoutDownloadingItAgain() async throws {
        let fixture = try await context()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        fixture.server.publishPrefix(fixture.server.payload.count, complete: false)
        var manager: DownloadManager? = fixture.manager()
        manager?.configure(connection: fixture.owner)
        try manager?.start(item: fixture.item, kind: .compatible, client: fixture.client)
        let queue = DownloadQueueStore(rootDirectory: fixture.root)
        try await waitUntil { (try? queue.load().entries.first?.resources?.first?.partial?.byteCount) == Int64(fixture.server.payload.count) }
        XCTAssertTrue(manager?.completed.isEmpty == true)
        manager?.pause(try XCTUnwrap(manager?.active.first))
        await manager?.waitForPendingOperations()
        let retained = try XCTUnwrap(queue.load().entries.first)
        manager = nil
        fixture.server.publishPrefix(fixture.server.payload.count, complete: true)
        let reopened = fixture.manager()
        await reopened.waitForPendingOperations()
        reopened.configure(connection: fixture.owner)
        reopened.resume(try XCTUnwrap(reopened.active.first))
        try await waitUntil { reopened.completed.count == 1 }
        let record = try XCTUnwrap(reopened.completed.first)
        XCTAssertEqual(try Data(contentsOf: reopened.localURL(for: record)), fixture.server.payload)
        XCTAssertEqual(fixture.server.sentBytes, fixture.server.payload.count)
        XCTAssertEqual(try queue.load().entries.first?.metadata.attemptID, retained.metadata.attemptID)
        XCTAssertEqual(try queue.load().entries.first?.metadata.serverPath, retained.metadata.serverPath)
    }

    func testGrowingDownloadKeepsReceivingAndResumesAfterInterruptionBeforePreparationFinishes() async throws {
        let fixture = try await context()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        let megabyte = 1_024 * 1_024
        fixture.server.publishPrefix(2 * megabyte, complete: false)
        let manager = fixture.manager()
        manager.configure(connection: fixture.owner)
        try manager.start(item: fixture.item, kind: .compatible, client: fixture.client)
        let queue = DownloadQueueStore(rootDirectory: fixture.root)
        try await waitUntil { (try? queue.load().entries.first?.resources?.first?.partial?.byteCount) == Int64(2 * megabyte) }
        XCTAssertTrue(manager.completed.isEmpty, "An available growing prefix must never become Ready to Watch")
        fixture.server.interruptAfter(4 * megabyte)
        fixture.server.publishPrefix(6 * megabyte, complete: false)
        try await waitUntil { (try? queue.load().entries.first?.resources?.first?.partial?.byteCount) == Int64(6 * megabyte) }
        XCTAssertTrue(manager.completed.isEmpty, "Recovery must keep downloading while preparation is still incomplete")
        try await waitUntil { Self.received(manager) >= Int64(6 * megabyte) }
        XCTAssertEqual(try queue.load().entries.first?.metadata.retryAttempt, 0,
                       "A committed range ends transport backoff; the next range must show retained byte progress")
        XCTAssertTrue(fixture.server.requests.contains { ($0.rangeStart ?? 0) > 3 * megabyte },
                      "Native recovery must resume inside the interrupted range, in addition to retaining earlier committed ranges")
        fixture.server.publishPrefix(fixture.server.payload.count, complete: true)
        try await waitUntil { manager.completed.count == 1 }
        let record = try XCTUnwrap(manager.completed.first)
        XCTAssertEqual(try Data(contentsOf: manager.localURL(for: record)), fixture.server.payload)
        XCTAssertLessThan(fixture.server.sentBytes, fixture.server.payload.count + 512 * 1_024)
    }

    func testConnectionLossAutomaticallyResumesAtReceivedOffset() async throws {
        let fixture = try await context()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        fixture.server.interruptAfter(4 * 1_024 * 1_024)
        let manager = fixture.manager()
        manager.configure(connection: fixture.owner)
        try manager.start(item: fixture.item, kind: .original, client: fixture.client)
        try await waitUntil { manager.completed.count == 1 }
        XCTAssertTrue(fixture.server.requests.contains { ($0.rangeStart ?? 0) >= 3 * 1_024 * 1_024 },
                      "A broken connection must recover the native partial file using a nonzero HTTP Range")
        XCTAssertLessThan(fixture.server.sentBytes, fixture.server.payload.count + 512 * 1_024)
        let record = try XCTUnwrap(manager.completed.first)
        XCTAssertEqual(try Data(contentsOf: manager.localURL(for: record)), fixture.server.payload)
    }

    func testCompatiblePreparationThenConnectionLossResumesWithoutRestarting() async throws {
        let fixture = try await context()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        fixture.server.changeBehavior(.preparing)
        fixture.server.interruptAfter(4 * 1_024 * 1_024)
        let manager = fixture.manager()
        manager.configure(connection: fixture.owner)
        try manager.start(item: fixture.item, kind: .compatible, client: fixture.client)
        try await waitUntil { manager.completed.count == 1 }
        XCTAssertTrue(fixture.server.requests.contains { $0.resumableDownload },
                      "Compatible downloads must request finalized, validator-backed delivery")
        XCTAssertTrue(fixture.server.requests.contains { ($0.rangeStart ?? 0) >= 3 * 1_024 * 1_024 })
        XCTAssertLessThan(fixture.server.sentBytes, fixture.server.payload.count + 512 * 1_024)
        let record = try XCTUnwrap(manager.completed.first)
        XCTAssertEqual(try Data(contentsOf: manager.localURL(for: record)), fixture.server.payload)
    }

    func testRetryAfterRelaunchKeepsNativeBytesAndPreparedGeneration() async throws {
        let fixture = try await context()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        var manager: DownloadManager? = fixture.manager()
        manager?.configure(connection: fixture.owner)
        try manager?.start(item: fixture.item, kind: .compatible, client: fixture.client)
        try await waitUntil { Self.received(manager) > 4 * 1_024 * 1_024 }
        manager?.pause(try XCTUnwrap(manager?.active.first))
        await manager?.waitForPendingOperations()
        let queue = DownloadQueueStore(rootDirectory: fixture.root)
        var entry = try XCTUnwrap(queue.load().entries.first)
        XCTAssertNotNil(entry.resources?.first?.resumeReference)
        // Reproduce the durable exhausted-retry boundary using a real native
        // partial file and encrypted archive, not a fabricated resume payload.
        entry.state = .failed
        entry.resources?[0].state = .failed
        entry.resources?[0].retryAttempt = DownloadRetryPolicy.maximumAttempts
        entry.metadata.retryAttempt = DownloadRetryPolicy.maximumAttempts
        try queue.update(entry)
        manager = nil
        let reopened = fixture.manager()
        await reopened.waitForPendingOperations()
        reopened.configure(connection: fixture.owner)
        reopened.retry(try XCTUnwrap(reopened.active.first))
        await reopened.waitForPendingOperations()
        let retry = try XCTUnwrap(queue.load().entries.first)
        XCTAssertEqual(retry.metadata.attemptID, entry.metadata.attemptID)
        XCTAssertEqual(retry.metadata.serverPath, entry.metadata.serverPath)
        try await waitUntil { reopened.completed.count == 1 }
        XCTAssertTrue(fixture.server.requests.contains { ($0.rangeStart ?? 0) >= 3 * 1_024 * 1_024 })
        XCTAssertLessThan(fixture.server.sentBytes, fixture.server.payload.count + 512 * 1_024)
        let record = try XCTUnwrap(reopened.completed.first)
        XCTAssertEqual(try Data(contentsOf: reopened.localURL(for: record)), fixture.server.payload)
    }

    func testPreparationSurvivesPauseRelaunchWithoutConsumingFailureBudget() async throws {
        let fixture = try await context()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        fixture.server.prepareForRequests(8)
        var manager: DownloadManager? = fixture.manager()
        manager?.configure(connection: fixture.owner)
        try manager?.start(item: fixture.item, kind: .compatible, client: fixture.client)
        try await waitUntil { fixture.server.requests.count >= 7 && manager?.active.first?.phase == .preparing }
        XCTAssertEqual(fixture.server.sentBytes, 0)
        XCTAssertTrue(manager?.completed.isEmpty == true)
        manager?.pause(try XCTUnwrap(manager?.active.first))
        await manager?.waitForPendingOperations()
        let queue = DownloadQueueStore(rootDirectory: fixture.root)
        let saved = try XCTUnwrap(queue.load().entries.first)
        XCTAssertEqual(saved.metadata.retryAttempt, 0)
        XCTAssertEqual(saved.resources?.first?.retryAttempt, 0)
        XCTAssertEqual(saved.state, .paused)
        manager = nil
        fixture.server.changeBehavior(.ranges)
        let reopened = fixture.manager()
        await reopened.waitForPendingOperations()
        reopened.configure(connection: fixture.owner)
        reopened.resume(try XCTUnwrap(reopened.active.first))
        try await waitUntil { reopened.completed.count == 1 }
        let completed = try XCTUnwrap(queue.load().entries.first)
        XCTAssertEqual(completed.metadata.serverPath, saved.metadata.serverPath)
        XCTAssertEqual(completed.metadata.attemptID, saved.metadata.attemptID)
        let record = try XCTUnwrap(reopened.completed.first)
        XCTAssertEqual(try Data(contentsOf: reopened.localURL(for: record)), fixture.server.payload)
    }

    func testTemporarilyUnavailableResumeKeyKeepsBytesForRetry() async throws {
        let fixture = try await context()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager()
        manager.configure(connection: fixture.owner)
        try manager.start(item: fixture.item, kind: .original, client: fixture.client)
        try await waitUntil { Self.received(manager) > 4 * 1_024 * 1_024 }
        manager.pause(try XCTUnwrap(manager.active.first))
        await manager.waitForPendingOperations()
        let queue = DownloadQueueStore(rootDirectory: fixture.root)
        let saved = try XCTUnwrap(queue.load().entries.first?.resources?.first?.resumeReference)
        fixture.secrets.rejectReads(true)
        manager.resume(try XCTUnwrap(manager.active.first))
        await manager.waitForPendingOperations()
        let failed = try XCTUnwrap(queue.load().entries.first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.resources?.first?.resumeReference, saved)
        XCTAssertEqual(fixture.server.requests.count, 1, "A temporarily locked key must not silently discard the partial download")
        fixture.secrets.rejectReads(false)
        manager.retry(try XCTUnwrap(manager.active.first))
        try await waitUntil { manager.completed.count == 1 }
        XCTAssertTrue(fixture.server.requests.contains { ($0.rangeStart ?? 0) >= 3 * 1_024 * 1_024 })
        let record = try XCTUnwrap(manager.completed.first)
        XCTAssertEqual(try Data(contentsOf: manager.localURL(for: record)), fixture.server.payload)
    }

    func testUnavailableKeychainDuringNativePauseOrPolicyChangeKeepsActionableDurableIntent() async throws {
        for userInitiated in [true, false] {
            let fixture = try await context()
            defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
            var manager: DownloadManager? = fixture.manager()
            manager?.configure(connection: fixture.owner)
            try manager?.start(item: fixture.item, kind: .original, client: fixture.client)
            try await waitUntil { Self.received(manager) > 512 * 1_024 }
            fixture.secrets.rejectWrites(true)
            if userInitiated { manager?.pause(try XCTUnwrap(manager?.active.first)) }
            else { manager?.setAllowsCellularDownloads(false) }
            await manager?.waitForPendingOperations()
            let entry = try XCTUnwrap(DownloadQueueStore(rootDirectory: fixture.root).load().entries.first)
            XCTAssertGreaterThan(fixture.secrets.rejectedWrites, 0,
                                 "The real native cancellation must provide resume data and reach the failing Keychain write")
            XCTAssertEqual(entry.state, userInitiated ? .paused : .failed)
            XCTAssertEqual(entry.resources?.first?.state, userInitiated ? .paused : .failed)
            XCTAssertNil(entry.resources?.first?.taskIdentifier)
            XCTAssertNil(entry.resources?.first?.resumeReference)
            XCTAssertEqual(entry.failure?.category, .credentialsUnavailable)
            XCTAssertEqual(fixture.server.requests.count, 1, "A failed policy migration must not silently restart the movie")
            manager = nil
            let reopened = fixture.manager()
            await reopened.waitForPendingOperations()
            XCTAssertEqual(reopened.active.first?.failure, entry.failure)
            if userInitiated { XCTAssertEqual(reopened.active.first?.phase, .paused(canResume: false)) }
            else if case .failed = reopened.active.first?.phase { } else { XCTFail("Retry must remain available after relaunch") }
            fixture.secrets.rejectWrites(false)
            reopened.configure(connection: fixture.owner)
            if userInitiated { reopened.resume(try XCTUnwrap(reopened.active.first)) }
            else { reopened.retry(try XCTUnwrap(reopened.active.first)) }
            try await waitUntil { fixture.server.requests.count == 2 && Self.received(reopened) > 0 }
            XCTAssertNil(fixture.server.requests.last?.rangeStart, "The unavailable archive was honestly reported as a restart")
            XCTAssertTrue(fixture.server.requests.allSatisfy { $0.authorization == fixture.owner.authorizationHeader() })
            reopened.cancel(try XCTUnwrap(reopened.active.first))
            await reopened.waitForPendingOperations()
        }
    }

    func testNativePauseRelaunchAndResumeReusesPreviouslyTransferredBytes() async throws {
        let fixture = try await context()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        var manager: DownloadManager? = fixture.manager()
        manager?.configure(connection: fixture.owner)
        try manager?.start(item: fixture.item, kind: .original, client: fixture.client)
        try await waitUntil { Self.received(manager) > Int64(fixture.server.payload.count * 3 / 4) }
        manager?.pause(try XCTUnwrap(manager?.active.first))
        await manager?.waitForPendingOperations()
        guard case .paused(let resumable) = manager?.active.first?.phase else { return XCTFail("Native pause did not persist") }
        XCTAssertTrue(resumable, "A validator-backed ranged response should provide native resume data")
        let saved = try XCTUnwrap(DownloadQueueStore(rootDirectory: fixture.root).load().entries.first?.resources?.first)
        XCTAssertNotNil(saved.resumeReference)
        let savedReceived = saved.receivedBytes
        manager = nil
        let reopened = fixture.manager()
        await reopened.waitForPendingOperations()
        XCTAssertEqual(reopened.active.first?.phase, .paused(canResume: true))
        reopened.configure(connection: fixture.owner)
        reopened.resume(try XCTUnwrap(reopened.active.first))
        try await waitUntil { reopened.completed.count == 1 }
        let resumed = try XCTUnwrap(fixture.server.requests.last)
        XCTAssertGreaterThan(resumed.rangeStart ?? 0, 0, "Resume must issue an actual nonzero HTTP Range")
        XCTAssertGreaterThanOrEqual(Int64(resumed.rangeStart ?? 0), max(1, savedReceived - 256 * 1_024))
        XCTAssertTrue(try XCTUnwrap(reopened.completed.first).isReadyToWatch)
        XCTAssertEqual(try Data(contentsOf: reopened.localURL(for: XCTUnwrap(reopened.completed.first))), fixture.server.payload)
        XCTAssertTrue(fixture.server.requests.allSatisfy { $0.authorization == fixture.owner.authorizationHeader() })
    }

    func testBothNetworkPolicyDirectionsPreserveNativeBytesAndUseTheirPolicySession() async throws {
        let fixture = try await context()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager()
        manager.configure(connection: fixture.owner)
        try manager.start(item: fixture.item, kind: .original, client: fixture.client)
        try await waitUntil { Self.received(manager) > Int64(fixture.server.payload.count / 2) }
        manager.setAllowsCellularDownloads(false)
        await manager.waitForPendingOperations()
        var component = try XCTUnwrap(DownloadQueueStore(rootDirectory: fixture.root).load().entries.first?.resources?.first)
        XCTAssertTrue(component.sessionIdentifier?.hasSuffix(".wifi") == true)
        try await waitUntil { Self.received(manager) > Int64(fixture.server.payload.count * 4 / 5) }
        manager.setAllowsCellularDownloads(true)
        await manager.waitForPendingOperations()
        component = try XCTUnwrap(DownloadQueueStore(rootDirectory: fixture.root).load().entries.first?.resources?.first)
        XCTAssertTrue(component.sessionIdentifier?.hasSuffix(".any") == true)
        try await waitUntil { manager.completed.count == 1 }
        XCTAssertGreaterThanOrEqual(fixture.server.requests.filter { ($0.rangeStart ?? 0) > 0 }.count, 2)
        XCTAssertLessThan(fixture.server.sentBytes, fixture.server.payload.count + 512 * 1_024,
                          "Changing policy must reuse bytes, not silently download the movie three times")
    }

    func testChangedValidatorAndDeniedRangeRestartSafelyWithoutJoiningDifferentFiles() async throws {
        for changedValidator in [true, false] {
            let fixture = try await context()
            defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
            let manager = fixture.manager()
            manager.configure(connection: fixture.owner)
            try manager.start(item: fixture.item, kind: .original, client: fixture.client)
            try await waitUntil { Self.received(manager) > Int64(fixture.server.payload.count / 2) }
            manager.pause(try XCTUnwrap(manager.active.first))
            await manager.waitForPendingOperations()
            fixture.server.changeBehavior(changedValidator ? .changedValidator : .ignoreRange)
            manager.resume(try XCTUnwrap(manager.active.first))
            try await waitUntil { manager.completed.count == 1 }
            XCTAssertTrue(fixture.server.requests.contains { ($0.rangeStart ?? 0) > 0 })
            let record = try XCTUnwrap(manager.completed.first)
            XCTAssertEqual(try Data(contentsOf: manager.localURL(for: record)), fixture.server.currentPayload)
            XCTAssertTrue(record.isReadyToWatch)
        }
    }

    func testInvalidOpaqueResumeDataFallsBackOnceToOrdinaryOwnedRequest() async throws {
        let fixture = try await context()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager()
        manager.configure(connection: fixture.owner)
        try manager.start(item: fixture.item, kind: .original, client: fixture.client)
        try await waitUntil { Self.received(manager) > 256 * 1_024 }
        manager.pause(try XCTUnwrap(manager.active.first))
        await manager.waitForPendingOperations()
        var entry = try XCTUnwrap(DownloadQueueStore(rootDirectory: fixture.root).load().entries.first)
        let resource = try XCTUnwrap(entry.resources?.first)
        let envelope = DownloadTaskEnvelope(metadata: entry.metadata, resource: resource)
        let vault = DownloadResumeVault(rootDirectory: fixture.root, secrets: fixture.secrets)
        let reference = try await vault.save(Data("invalid opaque native resume data".utf8), envelope: envelope)
        entry.resources?[0].resumeReference = reference
        try DownloadQueueStore(rootDirectory: fixture.root).update(entry)
        let reopened = fixture.manager()
        await reopened.waitForPendingOperations()
        reopened.configure(connection: fixture.owner)
        reopened.resume(try XCTUnwrap(reopened.active.first))
        try await waitUntil { reopened.completed.count == 1 }
        XCTAssertTrue(try XCTUnwrap(reopened.completed.first).isReadyToWatch)
        XCTAssertLessThanOrEqual(fixture.server.requests.count, 3, "Rejected native state must not create an endless retry loop")
    }

    func testEncryptedResumeDataIsBoundToAccountAndResourceWithoutPersistingCredentials() async throws {
        let fixture = try await context()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        var metadata = DownloadTaskMetadata(recordID: UUID(), serverOrigin: fixture.owner.serverIdentity, mediaID: "42001",
                                             title: "The Synthetic Range Observatory", kind: .original, fileExtension: "mp4",
                                             durationSeconds: 2, resolution: "96x64", attemptID: UUID(), accountUsername: fixture.owner.username)
        let plan = OfflinePackagePlan(metadata: metadata, movie: MovieMetadata(item: fixture.item))
        var resource = DownloadResourceDescriptor(resource: try XCTUnwrap(plan.resources.first))
        let envelope = DownloadTaskEnvelope(metadata: metadata, resource: resource)
        let vault = DownloadResumeVault(rootDirectory: fixture.root, secrets: fixture.secrets)
        let secretBlob = Data((fixture.owner.authorizationHeader() + " opaque system payload").utf8)
        let savedReference = try await vault.save(secretBlob, envelope: envelope)
        let reference = try XCTUnwrap(savedReference)
        let encrypted = try Data(contentsOf: fixture.root.appendingPathComponent("resume").appendingPathComponent(reference))
        XCTAssertNil(encrypted.range(of: Data(fixture.owner.authorizationHeader().utf8)))
        resource.transferID = UUID()
        let legitimateRetry = try await vault.load(reference, envelope: DownloadTaskEnvelope(metadata: metadata, resource: resource))
        XCTAssertEqual(legitimateRetry, secretBlob, "A fresh callback identity must retain same-resource resume data")
        metadata.accountUsername = "another-synthetic-viewer"
        do {
            _ = try await vault.load(reference, envelope: DownloadTaskEnvelope(metadata: metadata, resource: resource))
            XCTFail("A different account must not open the authenticated resume archive")
        } catch { }
    }

    func testContentRangeUsesTotalAndRejectsGrowingSnapshotsAsComplete() throws {
        let url = try XCTUnwrap(URL(string: "https://synthetic.example.test/web/download/42"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                                                    headerFields: ["Content-Length": "25", "Content-Range": "bytes 75-99/100"]))
        XCTAssertEqual(DownloadHTTPRange.completeLength(of: response), 100)
        let growing = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                                                   headerFields: ["Content-Length": "25", "Content-Range": "bytes 75-99/*"]))
        XCTAssertNil(DownloadHTTPRange.completeLength(of: growing))
        XCTAssertNil(DownloadHTTPRange.parse("bytes 75-100/100"))
        XCTAssertNil(DownloadHTTPRange.parse("bytes -1-99/100"))
    }

    func testGrowingRangeResponseNeverPublishesItsSnapshotAsACompleteMovie() async throws {
        let fixture = try await context()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        fixture.server.changeBehavior(.growingSnapshot)
        let manager = fixture.manager()
        manager.configure(connection: fixture.owner)
        try manager.start(item: fixture.item, kind: .original, client: fixture.client)
        try await waitUntil { manager.active.first?.metadata.retryAttempt == 1 }
        XCTAssertTrue(manager.completed.isEmpty)
        let entry = try XCTUnwrap(DownloadQueueStore(rootDirectory: fixture.root).load().entries.first)
        XCTAssertNotNil(entry.scheduledAt)
        XCTAssertEqual(entry.resources?.first?.retryAttempt, 1)
        manager.cancel(try XCTUnwrap(manager.active.first))
        await manager.waitForPendingOperations()
    }

    private static func received(_ manager: DownloadManager?) -> Int64 {
        guard case .downloading(_, let received, _) = manager?.active.first?.phase else { return 0 }
        return received
    }
    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(35)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "Native download failed to reach its expected bounded state")
    }
    private func context() async throws -> ResumeContext {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resume-tests-\(UUID().uuidString)")
        let server = try ResumeHTTPServer(payload: OfflineMediaFixture.validData())
        let address = try await server.start()
        let owner = try ServerConnection(serverAddress: address, username: "resume-viewer", password: "synthetic-resume-secret")
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(owner)
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)) as? [String: Any])
        var item = try XCTUnwrap(wire["item"] as? [String: Any])
        item["captions"] = []
        item["art_url"] = NSNull()
        item["size_bytes"] = server.payload.count
        item["duration_seconds"] = 2
        item["ext"] = "mp4"
        item["mime"] = "video/mp4"
        item["file_name"] = "Synthetic Range Observatory.mp4"
        wire["item"] = item
        let decoded = try JSONDecoder().decode(ItemResponse.self, from: JSONSerialization.data(withJSONObject: wire)).item
        return ResumeContext(root: root, server: server, owner: owner, client: client, item: decoded, secrets: ResumeTestSecrets())
    }
}

@MainActor
private struct ResumeContext {
    let root: URL
    let server: ResumeHTTPServer
    let owner: ServerConnection
    let client: RustyDLNAClient
    let item: MediaItem
    let secrets: ResumeTestSecrets
    func manager() -> DownloadManager {
        // Real system download tasks, isolated from all developer sessions.
        DownloadManager(store: DownloadManifestStore(rootDirectory: root),
                        sessionIdentifier: "resume-tests.\(UUID().uuidString)", resumeSecrets: secrets)
    }
}

private final class ResumeTestSecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var rejects = false
    private var rejected = 0
    private var readsUnavailable = false
    var rejectedWrites: Int { lock.lock(); defer { lock.unlock() }; return rejected }
    func rejectWrites(_ value: Bool) { lock.lock(); rejects = value; lock.unlock() }
    func rejectReads(_ value: Bool) { lock.lock(); readsUnavailable = value; lock.unlock() }
    func read(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if readsUnavailable { throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed) }
        return values[account]
    }
    func write(_ value: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if rejects { rejected += 1; throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed) }
        values[account] = value
    }
    func remove(account: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
}

private final class ResumeHTTPServer: @unchecked Sendable {
    enum Behavior { case ranges, changedValidator, ignoreRange, growingSnapshot, preparing, progressive }
    struct Request { let rangeStart: Int?; let authorization: String?; let resumableDownload: Bool }
    let payload: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "resume-tests.http")
    private let lock = NSLock()
    private var behavior: Behavior = .ranges
    private var captured: [Request] = []
    private var transferred = 0
    private var interruptionOffset: Int?
    private var preparationReplies = 1
    private var availableBytes = 0
    private var preparationComplete = false
    private var connections: [NWConnection] = []
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return captured }
    var sentBytes: Int { lock.lock(); defer { lock.unlock() }; return transferred }
    var currentPayload: Data {
        lock.lock(); defer { lock.unlock() }
        return data(for: behavior)
    }
    init(payload: Data) throws {
        // A standards-conforming MP4 free box creates a slow deterministic file
        // while preserving actual AVFoundation inspection of the tiny movie.
        let padding = 8 * 1_024 * 1_024
        var boxSize = UInt32(padding).bigEndian
        var extended = payload
        withUnsafeBytes(of: &boxSize) { extended.append(contentsOf: $0) }
        extended.append(Data("free".utf8))
        extended.append(Data(repeating: 0, count: padding - 8))
        self.payload = extended
        listener = try NWListener(using: .tcp, on: .any)
    }
    func changeBehavior(_ behavior: Behavior) { lock.lock(); defer { lock.unlock() }; self.behavior = behavior }
    func interruptAfter(_ offset: Int) { lock.lock(); defer { lock.unlock() }; interruptionOffset = offset }
    func publishPrefix(_ bytes: Int, complete: Bool) {
        lock.lock(); defer { lock.unlock() }
        behavior = .progressive
        availableBytes = bytes
        preparationComplete = complete
    }
    func prepareForRequests(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        behavior = .preparing
        preparationReplies = count
    }
    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state, let port = self.listener.port {
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: "http://127.0.0.1:\(port.rawValue)")
                } else if case .failed(let error) = state {
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.read(connection, bytes: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        listener.cancel()
        queue.async { [self] in for connection in connections { connection.cancel() }; connections.removeAll() }
    }
    private func data(for behavior: Behavior) -> Data {
        guard behavior == .changedValidator else { return payload }
        var changed = payload
        changed[changed.count - 1] = 1
        return changed
    }
    private func read(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, finished, error in
            guard let self else { return }
            var combined = bytes
            if let data { combined.append(data) }
            if let text = String(data: combined, encoding: .utf8), text.contains("\r\n\r\n") { self.respond(connection, text: text) }
            else if finished || error != nil || combined.count > 65_536 { connection.cancel() }
            else { self.read(connection, bytes: combined) }
        }
    }
    private func respond(_ connection: NWConnection, text: String) {
        let lines = text.components(separatedBy: "\r\n")
        func header(_ name: String) -> String? {
            lines.first { $0.lowercased().hasPrefix(name.lowercased() + ":") }?
                .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        }
        let requestLine = lines.first?.split(separator: " ") ?? []
        if requestLine.count > 1, requestLine[1].hasPrefix("/api/") {
            connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let head = requestLine.first == "HEAD"
        let start = header("Range")?.replacingOccurrences(of: "bytes=", with: "").split(separator: "-").first.flatMap { Int($0) }
        lock.lock()
        let resumableDownload = ["resumable", "progressive"].contains(header("X-RustyDLNA-Download"))
        if !head { captured.append(Request(rangeStart: start, authorization: header("Authorization"), resumableDownload: resumableDownload)) }
        let behavior = behavior
        let body = data(for: behavior)
        let available = availableBytes
        let complete = preparationComplete
        if behavior == .preparing && resumableDownload && !head {
            preparationReplies -= 1
            if preparationReplies == 0 { self.behavior = .ranges }
        }
        lock.unlock()
        if behavior == .progressive && complete && (start ?? 0) >= available {
            let response = "HTTP/1.1 416 Requested Range Not Satisfiable\r\nContent-Range: bytes */\(available)\r\nETag: \"synthetic-v1\"\r\nX-RustyDLNA-Download: progressive\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        if (behavior == .preparing && resumableDownload) || (behavior == .progressive && (start ?? 0) >= available) {
            let response = "HTTP/1.1 202 Accepted\r\nX-RustyDLNA-Download: preparing\r\nRetry-After: 1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let validator = behavior == .changedValidator ? "\"synthetic-v2\"" : "\"synthetic-v1\""
        if behavior == .progressive {
            let offset = max(0, start ?? 0)
            let total = complete ? String(body.count) : "*"
            let response = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\nETag: \(validator)\r\nContent-Range: bytes \(offset)-\(available - 1)/\(total)\r\nContent-Length: \(available - offset)\r\nX-RustyDLNA-Download: progressive\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
                guard error == nil, !head else { connection.cancel(); return }
                self?.send(connection, body: Data(body.prefix(available)), offset: offset)
            })
            return
        }
        let honorsRange = behavior != .ignoreRange && (header("If-Range") == nil || header("If-Range") == validator)
        let offset = honorsRange ? min(max(0, start ?? 0), body.count - 1) : 0
        let ranged = (start != nil && honorsRange) || behavior == .growingSnapshot
        let total = behavior == .growingSnapshot ? "*" : String(body.count)
        let rangeHeader = ranged ? "Content-Range: bytes \(offset)-\(body.count - 1)/\(total)\r\n" : ""
        // Match the server's old growing response: no validator or final length.
        let fileHeaders = behavior == .preparing ? "" : "Accept-Ranges: bytes\r\nETag: \(validator)\r\nContent-Length: \(body.count - offset)\r\n"
        let response = "HTTP/1.1 \(ranged ? 206 : 200) Synthetic\r\nContent-Type: video/mp4\r\n\(rangeHeader)\(fileHeaders)Connection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, !head else { connection.cancel(); return }
            self?.send(connection, body: body, offset: offset)
        })
    }
    private func send(_ connection: NWConnection, body: Data, offset: Int) {
        guard offset < body.count else { connection.cancel(); return }
        lock.lock()
        let interrupt = interruptionOffset.map { offset >= $0 } == true
        if interrupt { interruptionOffset = nil }
        lock.unlock()
        if interrupt { connection.forceCancel(); return }
        let end = min(offset + 16 * 1_024, body.count)
        connection.send(content: body.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.lock.lock(); self.transferred += end - offset; self.lock.unlock()
            self.queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in self?.send(connection, body: body, offset: end) }
        })
    }
}
