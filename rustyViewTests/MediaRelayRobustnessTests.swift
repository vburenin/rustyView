import AVFoundation
import CryptoKit
import Foundation
import Network
import XCTest
@testable import rustyView

/// Post-implementation tests: keep these out of the unchanged-wrapper baseline
/// gate. They exercise actual upstream HTTPS plus the public local HTTP relay.
@MainActor
final class MediaRelayRobustnessTests: XCTestCase {
    func testNativeEVENTRefreshCannotIntroduceForeignSegmentAfterPlaybackStarts() async throws {
        let fixture = try RelayFixture.load()
        let product = try MediaOriginProductViewer(client: fixture.client, path: fixture.url("event.m3u8").absoluteString)
        defer { product.stop() }
        try await eventually("Initial native EVENT media must play") {
            product.model.player.currentTime().seconds >= 0.5
        }
        XCTAssertNil(product.model.errorMessage)
        try await fixture.advance()
        try await eventually("The changed EVENT playlist must produce a terminal product failure") {
            product.model.errorMessage != nil
        }
        product.assertTrustFailure(MediaRelayError.untrustedReference.issue)
        let counts = try await fixture.counts()
        XCTAssertGreaterThanOrEqual(counts["trustedEventResponses"] ?? 0, 2)
        XCTAssertEqual(counts["hostileRequests"] ?? 0, 0)
        XCTAssertEqual(counts["hostileCredentials"] ?? 0, 0)
    }

    func testUnknownDuplicateAndMalformedURIAttributesFailBeforeForeignFetch() async throws {
        for path in ["unknown-uri.m3u8", "duplicate-uri.m3u8", "malformed-uri.m3u8"] {
            let fixture = try RelayFixture.load()
            let media = try await AuthenticatedMediaAsset(url: fixture.url(path), connection: fixture.owner)
            let item = AVPlayerItem(asset: media.asset)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            defer { player.pause(); player.replaceCurrentItem(with: nil); media.stop() }
            player.play()
            try await eventually("Unsafe URI syntax must become an actionable trust failure") {
                media.rejection?.category == .transportSecurity && item.status == .failed
            }
            let counts = try await fixture.counts()
            XCTAssertGreaterThan(counts["trustedFirstCredentials"] ?? 0, 0)
            XCTAssertEqual(counts["hostileRequests"] ?? 0, 0, path)
            XCTAssertEqual(counts["hostileCredentials"] ?? 0, 0, path)
        }
    }

    func testOwnedRedirectLoopHasPerRequestHopBound() async throws {
        let fixture = try RelayFixture.load()
        var limits = MediaRelayLimits()
        limits.redirectHops = 2
        let relay = try OwnedMediaRelay(sourceURL: fixture.url("loop.mp4"), connection: fixture.owner, limits: limits)
        defer { relay.stop() }
        let local = try await relay.assetURL()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do { _ = try await session.data(from: local) } catch { }
        let counts = try await fixture.counts()
        XCTAssertGreaterThanOrEqual(counts["trustedPathloop_mp4"] ?? 0, 3)
        XCTAssertLessThanOrEqual(counts["trustedPathloop_mp4"] ?? 0, 6,
                                "Two redirects plus bounded Basic challenges must stop well before URLSession's default loop limit")
        XCTAssertEqual(counts["hostileRequests"] ?? 0, 0)
        XCTAssertNotNil(relay.rejection)
    }

    func testCompleteLargeMediaForwardingUsesBoundedStreamingBuffers() async throws {
        let fixture = try RelayFixture.load()
        let expected = try await fixture.largeMetadata()
        let limits = MediaRelayLimits()
        let relay = try OwnedMediaRelay(sourceURL: fixture.url("large.mp4"), connection: fixture.owner, limits: limits)
        defer { relay.stop() }
        let local = try await relay.assetURL()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (file, response) = try await session.download(from: local)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, expected.byteCount)
        XCTAssertEqual(try hash(file), expected.sha256, "Complete bytes, not first-frame advancement, prove forwarding")
        try await eventually("The complete local HTTP response must finish") {
            await relay.metrics().completedMediaResponses == 1
        }
        let metrics = await relay.metrics()
        XCTAssertEqual(metrics.forwardedBodyBytes, expected.byteCount)
        XCTAssertGreaterThan(metrics.peakRetainedBytes, 0)
        XCTAssertLessThanOrEqual(metrics.peakRetainedBytes, limits.totalBufferBytes)
        XCTAssertLessThanOrEqual(metrics.peakStreamBytes, limits.streamBufferBytes)
        XCTAssertEqual(metrics.retainedBytes, 0)
    }

    func testSlowReaderAndCancelledQueuedRequestKeepBoundedFairWork() async throws {
        let fixture = try RelayFixture.load()
        var limits = MediaRelayLimits()
        limits.activeRequests = 1
        limits.waitingRequests = 2
        limits.acceptedConnections = 4
        let relay = try OwnedMediaRelay(sourceURL: fixture.url("large.mp4"), connection: fixture.owner, limits: limits)
        let local = try await relay.assetURL()
        var readers: [RelaySlowReader] = []
        defer { readers.forEach { $0.close() }; relay.stop() }
        for index in 0..<4 {
            let reader = try RelaySlowReader(url: local)
            readers.append(reader)
            try await reader.start()
            if index == 0 {
                try await eventually("The first reader must own the active response before waiters arrive") {
                    let metrics = await relay.metrics()
                    return metrics.activeRequests == 1 && metrics.peakRetainedBytes > 0
                }
            } else if index < 3 {
                try await eventually("Each waiter must be admitted in request order") { await relay.metrics().waitingRequests == index }
            }
        }
        try await eventually("One active body and two queued requests must be retained") {
            let metrics = await relay.metrics()
            return metrics.activeRequests == 1 && metrics.waitingRequests == 2 && metrics.peakRetainedBytes > 0
        }
        let before = try await fixture.counts()
        XCTAssertEqual(before["trustedPathlarge_mp4FirstCredentials"] ?? 0, 1)
        readers[1].close()
        try await eventually("A cancelled waiter must leave the queue immediately") { await relay.metrics().waitingRequests == 1 }
        let afterWaiterCancel = try await fixture.counts()
        XCTAssertEqual(afterWaiterCancel["trustedPathlarge_mp4FirstCredentials"] ?? 0, 1,
                       "Cancelling a waiter cannot start its HTTP request")
        readers[0].close()
        try await eventually("The remaining oldest request must take the released slot") {
            try await fixture.counts()["trustedPathlarge_mp4FirstCredentials"] ?? 0 >= 2
        }
        try await eventually("The old upstream response must actually observe cancellation") {
            try await fixture.counts()["trustedLargeCancelled"] ?? 0 >= 1
        }
        let running = await relay.metrics()
        XCTAssertLessThanOrEqual(running.activeRequests, 1)
        XCTAssertLessThanOrEqual(running.peakRetainedBytes, limits.totalBufferBytes)
        XCTAssertLessThanOrEqual(running.peakStreamBytes, limits.streamBufferBytes)
        readers.forEach { $0.close() }
        relay.stop()
        try await eventually("Stop must release sockets, tasks, queued work and retained buffers") {
            let metrics = await relay.metrics()
            return metrics.activeRequests == 0 && metrics.waitingRequests == 0 && metrics.acceptedConnections == 0 && metrics.retainedBytes == 0
        }
    }

    func testFullHoursLongEVENTGrowthKeepsOldRegisteredURLsAndGeneration() async throws {
        let fixture = try RelayFixture.load()
        let relay = try OwnedMediaRelay(sourceURL: fixture.url("long-event.m3u8"), connection: fixture.owner)
        defer { relay.stop() }
        let local = try await relay.assetURL()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (initial, _) = try await session.data(from: local)
        let firstURLs = try playlistURLs(initial)
        XCTAssertEqual(firstURLs.count, 6000, "A full three-hour EVENT window must fit the normal limits")
        let oldURL = try XCTUnwrap(firstURLs.first)
        try await fixture.advance()
        let (grown, _) = try await session.data(from: local)
        let nextURLs = try playlistURLs(grown)
        XCTAssertEqual(nextURLs.count, 7200)
        XCTAssertEqual(nextURLs.first, oldURL, "Refresh must preserve a URI held by a paused or seeking native player")
        var oldRequest = URLRequest(url: oldURL)
        oldRequest.setValue("bytes=0-31", forHTTPHeaderField: "Range")
        let (oldBytes, response) = try await session.data(for: oldRequest)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(oldBytes.count, 32)
        let counts = try await fixture.counts()
        XCTAssertGreaterThan(counts["trustedGeneration37Session41Requests"] ?? 0, 0,
                             "The native-local route must retain exact remote generation/session query ownership")
        XCTAssertEqual(counts["hostileRequests"] ?? 0, 0)
    }

    private func playlistURLs(_ data: Data) throws -> [URL] {
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        return try text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { try XCTUnwrap(URL(string: String($0))) }
    }
    private func hash(_ url: URL) throws -> String {
        let stream = try XCTUnwrap(InputStream(url: url))
        stream.open()
        defer { stream.close() }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            digest.update(data: Data(buffer.prefix(count)))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func eventually(_ message: String, _ condition: @escaping @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let result = try await condition()
        guard result else {
            XCTFail(message)
            throw NSError(domain: "SyntheticRelayCondition", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

@MainActor private struct RelayFixture {
    struct Descriptor: Decodable { let trusted: String; let hostile: String }
    struct LargeMetadata: Decodable { let byteCount: Int64; let sha256: String }
    let owner: ServerConnection
    let client: RustyDLNAClient
    let caseID: String
    static func load() throws -> Self {
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HTTPSOriginFixture.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Run the dedicated synthetic HTTPS fixture for relay verification.") }
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: Data(contentsOf: file))
        let owner = try ServerConnection(serverAddress: descriptor.trusted, username: "tls-viewer", password: "synthetic-tls-secret")
        guard owner.baseURL.scheme == "https", owner.baseURL.host == "127.0.0.1",
              let other = URL(string: descriptor.hostile), other.host == "127.0.0.1", other.port != owner.baseURL.port else { throw CocoaError(.fileReadCorruptFile) }
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(owner)
        return Self(owner: owner, client: client, caseID: UUID().uuidString)
    }
    func url(_ path: String) throws -> URL { try owner.resolve(serverPath: "/av/\(path)?case=\(caseID)") }
    func counts() async throws -> [String: Int] { try await JSONDecoder().decode([String: Int].self, from: client.data(serverPath: "/observations?case=\(caseID)")) }
    func advance() async throws { _ = try await client.data(serverPath: "/av/advance?case=\(caseID)") }
    func largeMetadata() async throws -> LargeMetadata { try await JSONDecoder().decode(LargeMetadata.self, from: client.data(serverPath: "/av/large-metadata?case=\(caseID)")) }
}

/// Send a real local HTTP request and deliberately never read its body. This
/// makes Network.framework backpressure, task admission and cancellation real.
private final class RelaySlowReader: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "synthetic.relay-slow-reader")
    private let request: Data
    private var startup: CheckedContinuation<Void, Error>?
    init(url: URL) throws {
        let portValue = try XCTUnwrap(url.port).description
        let port = try XCTUnwrap(NWEndpoint.Port(portValue))
        connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        request = Data("GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\nConnection: close\r\n\r\n".utf8)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.startup = continuation
                self.connection.stateUpdateHandler = { [weak self] state in
                    guard let self, let startup = self.startup else { return }
                    switch state {
                    case .ready:
                        self.startup = nil
                        self.connection.send(content: self.request, completion: .contentProcessed { error in
                            if let error { startup.resume(throwing: error) } else { startup.resume() }
                        })
                    case .failed(let error): self.startup = nil; startup.resume(throwing: error)
                    case .cancelled: self.startup = nil; startup.resume(throwing: URLError(.cancelled))
                    default: break
                    }
                }
                self.connection.start(queue: self.queue)
            }
        }
    }
    func close() { connection.cancel() }
}
