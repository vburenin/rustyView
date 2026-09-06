import Foundation
import Network
import Security
import XCTest
@testable import rustyView

@MainActor
final class DownloadResumeTests: XCTestCase {
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
    var rejectedWrites: Int { lock.lock(); defer { lock.unlock() }; return rejected }
    func rejectWrites(_ value: Bool) { lock.lock(); rejects = value; lock.unlock() }
    func read(account: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func write(_ value: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if rejects { rejected += 1; throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed) }
        values[account] = value
    }
    func remove(account: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
}

private final class ResumeHTTPServer: @unchecked Sendable {
    enum Behavior { case ranges, changedValidator, ignoreRange, growingSnapshot }
    struct Request { let rangeStart: Int?; let authorization: String? }
    let payload: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "resume-tests.http")
    private let lock = NSLock()
    private var behavior: Behavior = .ranges
    private var captured: [Request] = []
    private var transferred = 0
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
        let start = header("Range")?.replacingOccurrences(of: "bytes=", with: "").split(separator: "-").first.flatMap { Int($0) }
        lock.lock()
        captured.append(Request(rangeStart: start, authorization: header("Authorization")))
        let behavior = behavior
        let body = data(for: behavior)
        lock.unlock()
        let validator = behavior == .changedValidator ? "\"synthetic-v2\"" : "\"synthetic-v1\""
        let honorsRange = behavior != .ignoreRange && (header("If-Range") == nil || header("If-Range") == validator)
        let offset = honorsRange ? min(max(0, start ?? 0), body.count - 1) : 0
        let ranged = (start != nil && honorsRange) || behavior == .growingSnapshot
        let total = behavior == .growingSnapshot ? "*" : String(body.count)
        let rangeHeader = ranged ? "Content-Range: bytes \(offset)-\(body.count - 1)/\(total)\r\n" : ""
        let response = "HTTP/1.1 \(ranged ? 206 : 200) Synthetic\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\nETag: \(validator)\r\n\(rangeHeader)Content-Length: \(body.count - offset)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else { connection.cancel(); return }
            self?.send(connection, body: body, offset: offset)
        })
    }
    private func send(_ connection: NWConnection, body: Data, offset: Int) {
        guard offset < body.count else { connection.cancel(); return }
        let end = min(offset + 16 * 1_024, body.count)
        connection.send(content: body.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.lock.lock(); self.transferred += end - offset; self.lock.unlock()
            self.queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in self?.send(connection, body: body, offset: end) }
        })
    }
}
