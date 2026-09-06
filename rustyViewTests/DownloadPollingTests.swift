import Foundation
import XCTest
@testable import rustyView

@MainActor
final class DownloadPollingTests: XCTestCase {
    func testCompatibleJobsShareOneStatusRequestCadenceAndKeepTheirRequestOwner() async throws {
        let fixture = try PollingFixture(count: 4) { _, request in
            .response(status: 200, body: PollingHTTP.status(for: request), delay: 0.2)
        }
        addTeardownBlock { await fixture.cleanUp() }
        await fixture.start()
        try await eventually("Every admitted movie receives optional preparation progress", timeout: 7) {
            fixture.manager.preparationProgress.count == 4
        }
        let requests = fixture.http.statusRequests
        XCTAssertEqual(Set(requests.prefix(4).compactMap { $0.request.url?.lastPathComponent }), Set(fixture.mediaIDs))
        XCTAssertEqual(fixture.http.maximumConcurrentStatusRequests, 1,
                       "A per-download polling task would overlap these deliberately delayed HTTP responses")
        for pair in zip(requests, requests.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.started - pair.0.started, 0.9,
                                       "Optional status traffic must share one request cadence across all four movies")
        }
        XCTAssertEqual(fixture.http.mediaRequestCount, 4)
        XCTAssertEqual(fixture.manager.active.count, 4)
        for observed in requests {
            XCTAssertEqual(observed.request.value(forHTTPHeaderField: "Authorization"), fixture.authorization)
            let url = try XCTUnwrap(observed.request.url)
            let metadata = try XCTUnwrap(fixture.entries.first { $0.metadata.mediaID == url.lastPathComponent }?.metadata)
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(query.first { $0.name == "request" }?.value, "7")
            XCTAssertEqual(query.first { $0.name == "session" }?.value, "9\(metadata.mediaID)")
            XCTAssertEqual(fixture.manager.preparationProgress[metadata.recordID]?.producedSeconds, 6)
        }
    }

    func testUnsupportedStatusEndpointsStopPollingWithoutFailingOrRestartingMedia() async throws {
        let fixture = try PollingFixture(count: 3) { _, request in
            let code = ["42070": 404, "42071": 405, "42072": 501][request.url?.lastPathComponent ?? ""] ?? 500
            return .response(status: code, body: Data("{\"message\":\"Synthetic optional endpoint unavailable\"}".utf8))
        }
        addTeardownBlock { await fixture.cleanUp() }
        await fixture.start()
        try await eventually("All unsupported responses reach the actual client", timeout: 5) {
            fixture.http.statusRequests.count == 3 && fixture.http.activeStatusRequestCount == 0
        }
        // This spans the normal three-second cadence and the first failure
        // retry. Without unsupported-endpoint suppression, requests recur.
        try await Task.sleep(for: .milliseconds(3_400))
        XCTAssertEqual(fixture.http.statusRequests.count, 3)
        XCTAssertEqual(Set(fixture.http.statusRequests.compactMap { $0.request.url?.lastPathComponent }), Set(fixture.mediaIDs))
        XCTAssertEqual(fixture.http.mediaRequestCount, 3, "An optional endpoint failure must not replace the media transfers")
        XCTAssertEqual(fixture.manager.active.count, 3)
        XCTAssertTrue(fixture.manager.preparationProgress.isEmpty)
        let journal = try DownloadQueueStore(rootDirectory: fixture.root).load()
        let evidence = XCTAttachment(data: try JSONEncoder().encode(journal), uniformTypeIdentifier: "public.json")
        evidence.name = "Synthetic durable queue after unsupported status responses"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertEqual(Set(journal.entries.map(\.id)), Set(fixture.entries.map(\.id)))
        for entry in journal.entries {
            XCTAssertEqual(entry.state, .running, "Optional status errors must not fail media \(entry.metadata.mediaID)")
            XCTAssertEqual(entry.metadata.retryAttempt, 0, "Optional status errors must not spend the media retry budget")
            XCTAssertNil(entry.failure)
            let media = try XCTUnwrap(entry.resources?.first { $0.resource.kind == .media })
            XCTAssertEqual(media.state, .running)
            XCTAssertEqual(media.retryAttempt, 0)
            XCTAssertNil(media.failure)
        }
    }

    func testStatusBackoffHonorsServerHintAndCancelsAnOutstandingRequestWithItsJob() async throws {
        let fixture = try PollingFixture(count: 1) { index, request in
            switch index {
            case 0: return .response(status: 503, body: Data("{\"message\":\"Synthetic temporary status failure\"}".utf8))
            case 1: return .response(status: 200, body: PollingHTTP.status(for: request, retryHint: 5))
            default: return .held
            }
        }
        addTeardownBlock { await fixture.cleanUp() }
        await fixture.start()
        try await eventually("A failed optional request is retried and its response supplies a retry hint", timeout: 5) {
            fixture.manager.preparationProgress.count == 1
        }
        try await eventually("Polling resumes after the server's hint", timeout: 7) {
            fixture.http.statusRequests.count == 3 && fixture.http.activeStatusRequestCount == 1
        }
        let requests = fixture.http.statusRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertGreaterThanOrEqual(requests[1].started - requests[0].started, 1.8,
                                   "A 503 response must back off instead of retrying at the shared one-second tick")
        XCTAssertGreaterThanOrEqual(requests[2].started - requests[1].started, 4.8,
                                   "The decoded five-second hint must delay polling beyond its ordinary cadence")
        let row = try XCTUnwrap(fixture.manager.active.first)
        // Sign-out keeps system downloads available. Removing that retained
        // job must still cancel the status request owned by its former login.
        fixture.manager.configure(connection: nil)
        await fixture.manager.waitForPendingOperations()
        fixture.manager.cancel(row)
        await fixture.manager.waitForPendingOperations()
        try await eventually("Cancellation reaches URLProtocol.stopLoading for the held HTTP request") {
            fixture.http.cancelledStatusRequestCount == 1
        }
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(fixture.http.statusRequests.count, 3)
        XCTAssertTrue(fixture.manager.active.isEmpty)
        XCTAssertTrue(fixture.manager.preparationProgress.isEmpty)
        XCTAssertEqual(try DownloadQueueStore(rootDirectory: fixture.root).load().entries.first?.state, .cancelled)
    }

    private func eventually(_ description: String, timeout: TimeInterval = 3,
                            _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard predicate() else {
            XCTFail(description)
            throw PollingTestError.timedOut
        }
    }
}

private enum PollingTestError: Error { case timedOut }

@MainActor
private final class PollingFixture {
    let root: URL
    let manager: DownloadManager
    let entries: [DownloadQueueEntry]
    let http: PollingHTTP
    let client: RustyDLNAClient
    let owner: ServerConnection
    var mediaIDs: [String] { entries.map(\.metadata.mediaID) }
    var authorization: String { "Basic " + Data("poll-viewer:synthetic-poll-secret".utf8).base64EncodedString() }

    init(count: Int, response: @escaping (Int, URLRequest) -> PollingHTTP.Reply) throws {
        let namespace = UUID().uuidString.lowercased()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("polling-tests-\(namespace)")
        var address = URLComponents()
        address.scheme = "https"
        address.host = "poll-\(namespace).example.test"
        let capturedOwner = try ServerConnection(serverAddress: try XCTUnwrap(address.string), username: "poll-viewer", password: "synthetic-poll-secret")
        owner = capturedOwner
        entries = (0..<count).map { index in
            let id = String(42070 + index)
            let metadata = DownloadTaskMetadata(recordID: UUID(), serverOrigin: capturedOwner.serverIdentity,
                mediaID: id, title: "Synthetic Preparation \(index)", kind: .compatible, fileExtension: "mp4",
                durationSeconds: 60, resolution: "96x64", serverPath: "/web/media/\(id).mp4?request=7&session=9\(id)",
                retryAttempt: 0, attemptID: UUID(), accountUsername: capturedOwner.username)
            var entry = DownloadQueueEntry(metadata: metadata)
            entry.enqueuedAt = Date(timeIntervalSince1970: Double(100 + index))
            return entry
        }
        try DownloadQueueStore(rootDirectory: root).save(DownloadQueueJournal(entries: entries))
        http = PollingHTTP(response: response)
        PollingProtocol.register(http, host: owner.baseURL.host ?? "")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PollingProtocol.self]
        client = RustyDLNAClient(configuration: configuration)
        client.configure(owner)
        manager = DownloadManager(store: DownloadManifestStore(rootDirectory: root), sessionIdentifier: "polling-tests.\(namespace)",
                                  sessionConfiguration: configuration, maximumTransfers: count)
    }

    func start() async {
        manager.configure(connection: owner, statusClient: client)
        await manager.waitForPendingOperations()
        // Mutating the caller's client must not retarget the manager's captured
        // status owner or make its optional requests disappear.
        client.configure(nil)
    }

    func cleanUp() async {
        manager.configure(connection: nil)
        for row in manager.active { manager.cancel(row) }
        await manager.waitForPendingOperations()
        PollingProtocol.unregister(host: owner.baseURL.host ?? "")
        try? FileManager.default.removeItem(at: root)
    }
}

private final class PollingHTTP: @unchecked Sendable {
    enum Reply {
        case held
        case response(status: Int, body: Data, delay: TimeInterval = 0)
    }
    struct Observation {
        let request: URLRequest
        let started: TimeInterval
    }
    private let lock = NSLock()
    private let response: (Int, URLRequest) -> Reply
    private var observations: [Observation] = []
    private var inFlight: Set<UUID> = []
    private var maximum = 0
    private var cancelled = 0
    private var mediaCount = 0
    init(response: @escaping (Int, URLRequest) -> Reply) { self.response = response }

    func begin(_ request: URLRequest, token: UUID) -> Reply {
        lock.lock(); defer { lock.unlock() }
        guard request.url?.path.hasPrefix("/api/web/transcode/") == true else {
            mediaCount += 1
            return .held
        }
        let index = observations.count
        observations.append(Observation(request: request, started: ProcessInfo.processInfo.systemUptime))
        inFlight.insert(token)
        maximum = max(maximum, inFlight.count)
        return response(index, request)
    }
    func ended(_ token: UUID, cancelled: Bool) {
        lock.lock(); defer { lock.unlock() }
        if inFlight.remove(token) != nil, cancelled { self.cancelled += 1 }
    }
    var statusRequests: [Observation] { lock.lock(); defer { lock.unlock() }; return observations }
    var maximumConcurrentStatusRequests: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    var activeStatusRequestCount: Int { lock.lock(); defer { lock.unlock() }; return inFlight.count }
    var cancelledStatusRequestCount: Int { lock.lock(); defer { lock.unlock() }; return cancelled }
    var mediaRequestCount: Int { lock.lock(); defer { lock.unlock() }; return mediaCount }
    static func status(for request: URLRequest, retryHint: Int = 3) -> Data {
        let id = request.url?.lastPathComponent ?? "42070"
        return Data("{\"schema_version\":2,\"item_id\":\"\(id)\",\"request_id\":7,\"state\":\"running\",\"produced_seconds\":6,\"retry_after_seconds\":\(retryHint)}".utf8)
    }
}

private final class PollingProtocol: URLProtocol {
    private static let registryLock = NSLock()
    private static var registry: [String: PollingHTTP] = [:]
    private let callbacks = DispatchQueue(label: "polling-tests.callbacks")
    private let token = UUID()
    private var http: PollingHTTP?
    private var stopped = false
    static func register(_ fixture: PollingHTTP, host: String) {
        registryLock.lock(); defer { registryLock.unlock() }; registry[host] = fixture
    }
    static func unregister(host: String) {
        registryLock.lock(); defer { registryLock.unlock() }; registry.removeValue(forKey: host)
    }
    private static func fixture(for request: URLRequest) -> PollingHTTP? {
        registryLock.lock(); defer { registryLock.unlock() }; return registry[request.url?.host ?? ""]
    }
    override class func canInit(with request: URLRequest) -> Bool { fixture(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        callbacks.async { [self] in
            guard !stopped, let fixture = Self.fixture(for: request) else { return }
            http = fixture
            switch fixture.begin(request, token: token) {
            case .held: break
            case .response(let status, let body, let delay):
                callbacks.asyncAfter(deadline: .now() + delay) { [self] in
                    guard !stopped, let url = request.url,
                          let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                              headerFields: ["Content-Type": "application/json", "Content-Length": String(body.count)]) else { return }
                    fixture.ended(token, cancelled: false)
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: body)
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
        }
    }
    override func stopLoading() {
        callbacks.async { [self] in
            stopped = true
            http?.ended(token, cancelled: true)
        }
    }
}
