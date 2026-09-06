import Foundation
import XCTest
@testable import rustyView

@MainActor
final class DownloadSchedulingTests: XCTestCase {
    func testDurableFairQueueStartsTwoTransfersThenAdmitsTheNextAfterCancellation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); QueueHoldingProtocol.handler = nil }
        let entries = (0..<4).map { entry(offset: $0) }
        try DownloadQueueStore(rootDirectory: root).save(DownloadQueueJournal(entries: entries))
        let requests = SchedulingRequests()
        QueueHoldingProtocol.handler = { requests.append($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QueueHoldingProtocol.self]
        let manager = DownloadManager(store: DownloadManifestStore(rootDirectory: root),
                                      sessionIdentifier: "scheduler-tests.\(UUID().uuidString)", sessionConfiguration: configuration)
        manager.configure(connection: try connection())
        await manager.waitForPendingOperations()
        try await waitUntil { requests.count == 2 }
        XCTAssertEqual(manager.active.count, 4, "Every selection remains visible while the transfer slots are occupied")
        XCTAssertEqual(Set(requests.paths), Set(["/web/download/42050", "/web/download/42051"]))
        XCTAssertEqual(manager.active.first(where: { $0.id == entries[2].id })?.phase, .waiting(reason: .turn))
        manager.cancel(try XCTUnwrap(manager.active.first(where: { $0.id == entries[0].id })))
        await manager.waitForPendingOperations()
        try await waitUntil { requests.count == 3 }
        XCTAssertEqual(requests.paths.last, "/web/download/42052")
        XCTAssertEqual(try DownloadQueueStore(rootDirectory: root).load().entries.first(where: { $0.id == entries[0].id })?.state, .cancelled)
        for row in manager.active { manager.cancel(row) }
        await manager.waitForPendingOperations()
    }

    func testPolicyChangesRetainDurableRetryBudgetAndScheduledDate() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); QueueHoldingProtocol.handler = nil }
        var queued = entry(offset: 0)
        queued.metadata.retryAttempt = 3
        queued.scheduledAt = Date().addingTimeInterval(600)
        queued.reason = "Synthetic temporary service failure"
        try DownloadQueueStore(rootDirectory: root).update(queued)
        QueueHoldingProtocol.handler = { _ in }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QueueHoldingProtocol.self]
        let manager = DownloadManager(store: DownloadManifestStore(rootDirectory: root),
                                      sessionIdentifier: "scheduler-tests.\(UUID().uuidString)", sessionConfiguration: configuration)
        manager.configure(connection: try connection())
        await manager.waitForPendingOperations()
        for allowed in [false, true] {
            manager.setAllowsCellularDownloads(allowed)
            await manager.waitForPendingOperations()
            let restored = try XCTUnwrap(DownloadQueueStore(rootDirectory: root).load().entries.first)
            XCTAssertEqual(restored.scheduledAt, queued.scheduledAt)
            XCTAssertEqual(restored.metadata.retryAttempt, 3)
            XCTAssertEqual(restored.resources?.first?.scheduledAt, queued.scheduledAt)
            XCTAssertEqual(restored.resources?.first?.retryAttempt, 3)
        }
        manager.cancel(try XCTUnwrap(manager.active.first))
        await manager.waitForPendingOperations()
    }

    func testBackgroundHandlersAreRetainedAndCompletedOnlyForTheirOwnSession() {
        let events = BackgroundSessionEvents()
        var reconnected: [String] = []
        var completed: [String] = []
        events.store(identifier: "download-A") { completed.append("first-A") }
        events.store(identifier: "download-A") { completed.append("second-A") }
        events.store(identifier: "download-B") { completed.append("B") }
        XCTAssertTrue(completed.isEmpty, "A second OS event must not prematurely acknowledge the first batch")
        events.register { reconnected.append($0) }
        XCTAssertEqual(Set(reconnected), Set(["download-A", "download-B"]))
        events.finish(identifier: "download-B")
        XCTAssertEqual(completed, ["B"])
        events.finish(identifier: "download-A")
        XCTAssertEqual(completed, ["B", "first-A", "second-A"])
        events.finish(identifier: "download-A")
        XCTAssertEqual(completed.count, 3)
    }

    func testAnExistingSystemTaskShowsNetworkAndWiFiWaitsWithoutStartingAnotherTransfer() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); QueueHoldingProtocol.handler = nil }
        let queued = entry(offset: 0)
        try DownloadQueueStore(rootDirectory: root).update(queued)
        let requests = SchedulingRequests()
        QueueHoldingProtocol.handler = { requests.append($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QueueHoldingProtocol.self]
        let manager = DownloadManager(store: DownloadManifestStore(rootDirectory: root), allowsCellularDownloads: false,
                                      sessionIdentifier: "scheduler-tests.\(UUID().uuidString)", sessionConfiguration: configuration)
        manager.configure(connection: try connection())
        await manager.waitForPendingOperations()
        try await waitUntil { requests.count == 1 }
        let transferID = try XCTUnwrap(DownloadQueueStore(rootDirectory: root).load().entries.first?.resources?.first?.transferID)
        manager.updateNetworkPath(available: true, cellular: true)
        await manager.waitForPendingOperations()
        XCTAssertEqual(manager.active.first?.phase, .waiting(reason: .wifi))
        manager.updateNetworkPath(available: false, cellular: false)
        await manager.waitForPendingOperations()
        XCTAssertEqual(manager.active.first?.phase, .waiting(reason: .network))
        manager.updateNetworkPath(available: true, cellular: false)
        await manager.waitForPendingOperations()
        XCTAssertEqual(try DownloadQueueStore(rootDirectory: root).load().entries.first?.state, .running)
        XCTAssertEqual(try DownloadQueueStore(rootDirectory: root).load().entries.first?.resources?.first?.transferID, transferID)
        XCTAssertEqual(requests.count, 1, "Path observations label the retained system task instead of restarting its bytes")
        manager.cancel(try XCTUnwrap(manager.active.first))
        await manager.waitForPendingOperations()
    }

    private func entry(offset: Int) -> DownloadQueueEntry {
        let metadata = DownloadTaskMetadata(recordID: UUID(), serverOrigin: "https://scheduler.example.test", mediaID: String(42050 + offset),
                                            title: "Synthetic Queue Movie \(offset)", kind: .original, fileExtension: "mp4", durationSeconds: 2,
                                            resolution: "96x64", serverPath: "/web/download/\(42050 + offset)", retryAttempt: 0,
                                            attemptID: UUID(), accountUsername: "synthetic-viewer")
        var entry = DownloadQueueEntry(metadata: metadata)
        entry.enqueuedAt = Date(timeIntervalSince1970: Double(100 + offset))
        return entry
    }
    private func connection() throws -> ServerConnection {
        try ServerConnection(serverAddress: "https://scheduler.example.test", username: "synthetic-viewer", password: "synthetic-secret")
    }
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("scheduler-tests-\(UUID().uuidString)") }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate())
    }
}

private final class SchedulingRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return requests.compactMap { $0.url?.path } }
}
