import AVFoundation
import Foundation
import XCTest
@testable import rustyView

@MainActor
final class PlaybackTrustTests: XCTestCase {
    override func tearDown() {
        PlaybackOwnershipHTTPProtocol.server = nil
        super.tearDown()
    }

    func testPreparedReplacementCancelsExactGenerationBeforeLateGETAndRetainsOldCredentials() async throws {
        let server = PlaybackOwnershipServer()
        PlaybackOwnershipHTTPProtocol.server = server
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackOwnershipHTTPProtocol.self]
        let client = RustyDLNAClient(configuration: configuration)
        let original = try ServerConnection(serverAddress: "https://first.example.test", username: "viewer", password: "synthetic-one")
        client.configure(original)
        let item = try fixture()
        let owner = try PreparedPlaybackSession(client: client, mediaID: item.id, heartbeatInterval: .milliseconds(40))
        let otherViewer = try PreparedPlaybackSession(client: client, mediaID: item.id, heartbeatInterval: .seconds(20))
        let other = otherViewer.prepare(item: item, quality: "auto", audioIndex: 1, startSeconds: 0, forceVideoTranscode: false)
        _ = try await otherViewer.client.data(serverPath: other)
        let first = owner.prepare(item: item, quality: "full_hd", audioIndex: 0, startSeconds: 50, forceVideoTranscode: true)
        let firstIdentity = try identity(first)
        client.configure(try ServerConnection(serverAddress: "https://second.example.test", username: "different-viewer", password: "synthetic-two"))
        let second = owner.prepare(item: item, quality: "full_hd", audioIndex: 0, startSeconds: 900, forceVideoTranscode: true)
        let secondIdentity = try identity(second)
        XCTAssertEqual(firstIdentity.session, secondIdentity.session)
        XCTAssertGreaterThan(secondIdentity.generation, firstIdentity.generation)

        await waitFor("Exact old generation was cancelled before a media GET") { server.cancelled.contains(firstIdentity) }
        do {
            _ = try await owner.client.data(serverPath: first)
            XCTFail("The delayed cancelled GET must not create a producer")
        } catch RustyDLNAError.http(let status, _, _) { XCTAssertEqual(status, 410) }
        _ = try await owner.client.data(serverPath: second)
        await waitFor("Active generation receives reader-free heartbeats") { server.heartbeats(secondIdentity) >= 2 }
        XCTAssertTrue(server.active.contains(try identity(other)), "Replacing this viewer must preserve another viewer")
        XCTAssertFalse(server.active.contains(firstIdentity))
        XCTAssertTrue(server.active.contains(secondIdentity))
        owner.cancelActive()
        await waitFor("Close cancels the retained generation") { server.cancelled.contains(secondIdentity) }
        XCTAssertTrue(server.active.contains(try identity(other)))
        XCTAssertTrue(server.requests.allSatisfy {
            $0.url?.host == "first.example.test" && $0.value(forHTTPHeaderField: "Authorization") == original.authorizationHeader()
        }, "A connection edit cannot redirect cleanup or heartbeats to the new account")
        otherViewer.cancelActive()
        await waitFor("Other viewer cleanup completed") { server.active.isEmpty }
    }

    func testPreparingControlReflectsPauseIntentAndSurvivesAReplacement() throws {
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(try ServerConnection(serverAddress: "https://media.example.test", username: "viewer", password: "synthetic"))
        let model = PlaybackModel(client: client)
        defer { model.stop() }
        model.play(try fixture(), mode: .portable, quality: "full_hd", audioIndex: 0, startAt: 123)
        XCTAssertTrue(model.isPreparing)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.transport.actionLabel, "Pause", "Playing intent must offer Pause before AVPlayer advances")
        model.togglePlayback()
        XCTAssertEqual(model.transport.actionLabel, "Play")
        model.selectAudio(1)
        XCTAssertEqual(model.transport.intent, .paused)
        XCTAssertEqual(model.transport.actionLabel, "Play")
        XCTAssertEqual(model.selectedQuality, "full_hd")
        XCTAssertEqual(model.currentTime, 123)
        model.togglePlayback()
        XCTAssertEqual(model.transport.actionLabel, "Pause")
    }

    func testWatchdogRequiresAdvancementAndExcludesPauseAndSeekTime() {
        var watchdog = PlaybackProgressWatchdog(timeout: 15)
        XCTAssertFalse(watchdog.sample(time: 0, now: 0, shouldAdvance: true))
        XCTAssertTrue(watchdog.sample(time: 0, now: 16, shouldAdvance: true), "A ready but motionless player must time out")
        watchdog.reset()
        XCTAssertFalse(watchdog.sample(time: 0, now: 20, shouldAdvance: true))
        XCTAssertFalse(watchdog.sample(time: 1, now: 21, shouldAdvance: true))
        XCTAssertTrue(watchdog.hasProgressed)
        XCTAssertFalse(watchdog.sample(time: 1, now: 100, shouldAdvance: false), "A deliberate pause is not a stall")
        XCTAssertFalse(watchdog.sample(time: 1, now: 101, shouldAdvance: true))
        XCTAssertFalse(watchdog.sample(time: 900, now: 102, shouldAdvance: false), "An in-progress seek must not count its time jump as playback")
        XCTAssertFalse(watchdog.sample(time: 900, now: 150, shouldAdvance: true))
        XCTAssertFalse(watchdog.sample(time: 901, now: 151, shouldAdvance: true))
        XCTAssertTrue(watchdog.sample(time: 901, now: 167, shouldAdvance: true), "A later stall must remain bounded after initial successful playback")
    }

    func testUnavailableMediaTimeStillConsumesTheStartupDeadline() {
        var watchdog = PlaybackProgressWatchdog(timeout: 15)
        XCTAssertFalse(watchdog.sample(time: .nan, now: 0, shouldAdvance: true))
        XCTAssertFalse(watchdog.sample(time: .infinity, now: 8, shouldAdvance: true))
        XCTAssertTrue(watchdog.sample(time: .nan, now: 16, shouldAdvance: true),
                      "An asset that never obtains valid time must not stay Preparing forever")
        XCTAssertFalse(watchdog.hasProgressed)
        XCTAssertFalse(watchdog.sample(time: .nan, now: 30, shouldAdvance: false))
        XCTAssertFalse(watchdog.sample(time: .nan, now: 31, shouldAdvance: true))
        XCTAssertTrue(watchdog.sample(time: .nan, now: 47, shouldAdvance: true))
    }

    func testFailedLocalPlaybackRetriesSameFileAndPreservesPausedPositionWithoutHTTP() async throws {
        let server = PlaybackOwnershipServer()
        PlaybackOwnershipHTTPProtocol.server = server
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackOwnershipHTTPProtocol.self]
        let client = RustyDLNAClient(configuration: configuration)
        client.configure(try ServerConnection(serverAddress: "https://media.example.test", username: "viewer", password: "synthetic"))
        let media = try OfflineMediaFixture.validData()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("playback-retry-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try media.write(to: url)
        let inspection = await Task.detached { DownloadAssetInspector.inspect(url) }.value
        try FileManager.default.removeItem(at: url)
        let record = DownloadRecord(
            id: UUID(), serverOrigin: "https://media.example.test", mediaID: "42001", title: "The Paper Harbor",
            kind: .compatible, fileName: url.lastPathComponent, byteCount: Int64(media.count),
            completedAt: Date(), durationSeconds: 7200, resolution: "96x64", artworkPath: nil,
            assetInspection: inspection
        )
        let model = PlaybackModel(client: client)
        defer { model.stop() }
        model.playLocal(record: record, url: url, startAt: 0.5, preservingIntent: .paused)
        XCTAssertEqual(model.duration, 2, accuracy: 0.1,
                       "The offline timeline must use inspected media duration instead of a stale catalog runtime")
        await waitFor("Missing local media surfaces a recoverable failure") { model.errorMessage != nil }
        XCTAssertEqual(model.transport.actionLabel, "Retry Current Playback")
        XCTAssertEqual(model.transport.intent, .paused)
        XCTAssertEqual(model.currentTime, 0.5)
        try media.write(to: url)
        model.retryCurrentPlayback()
        await waitFor("Retry loads the same repaired local file and applies the retained position") {
            model.player.currentItem?.status == .readyToPlay && model.player.currentTime().seconds >= 0.45
        }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.transport.intent, .paused)
        XCTAssertEqual(model.transport.actionLabel, "Play")
        model.togglePlayback()
        await waitFor("The retried local asset actually advances") { model.player.currentTime().seconds >= 1 }
        XCTAssertTrue(server.requests.isEmpty, "Recovering local playback must never silently select a remote source")
    }

    func testInitialSavedSeekCannotOverrideANewerUserSeekBeforeReadiness() async throws {
        let data = try OfflineMediaFixture.validData()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("playback-seek-\(UUID().uuidString).mp4")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let record = DownloadRecord(
            id: UUID(), serverOrigin: "https://media.example.test", mediaID: "42001", title: "The Paper Harbor",
            kind: .compatible, fileName: url.lastPathComponent, byteCount: Int64(data.count), completedAt: Date(),
            durationSeconds: 2, resolution: "96x64", artworkPath: nil
        )
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral))
        defer { model.stop() }
        model.playLocal(record: record, url: url, startAt: 0.25, preservingIntent: .paused)
        // No actor yield: readiness cannot consume the saved seek before this
        // newer user action. Both seeks reach the same real AVPlayer boundary.
        model.seek(toGlobalTime: 1.2)
        await waitFor("The newer seek owns the position once the asset is ready") {
            model.player.currentItem?.status == .readyToPlay && model.player.currentTime().seconds >= 1.15
        }
        XCTAssertEqual(model.player.currentTime().seconds, 1.2, accuracy: 0.1)
        XCTAssertEqual(model.transport.intent, .paused)
    }

    private func fixture() throws -> MediaItem {
        try JSONDecoder().decode(ItemResponse.self, from: Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)).item
    }

    private func identity(_ path: String) throws -> PreparedPlaybackIdentity {
        let items = try XCTUnwrap(URLComponents(string: path)?.queryItems)
        return PreparedPlaybackIdentity(
            session: try XCTUnwrap(items.first(where: { $0.name == "session" })?.value.flatMap(UInt64.init)),
            generation: try XCTUnwrap(items.first(where: { $0.name == "request" })?.value.flatMap(UInt64.init))
        )
    }

    private func waitFor(_ description: String, condition: @escaping () -> Bool) async {
        let reached = expectation(description: description)
        let poll = Task {
            for _ in 0..<200 {
                if condition() { reached.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await fulfillment(of: [reached], timeout: 3)
        poll.cancel()
    }
}

/// A generation-aware HTTP fixture, preserving server ownership and DELETE
/// tombstones at the URL loading boundary instead of returning canned success.
private final class PlaybackOwnershipServer: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCancelled: [PreparedPlaybackIdentity] = []
    private var storedActive: [PreparedPlaybackIdentity] = []
    private var storedRequests: [URLRequest] = []
    private var storedHeartbeats: [PreparedPlaybackIdentity] = []
    var cancelled: [PreparedPlaybackIdentity] { lock.withLock { storedCancelled } }
    var active: [PreparedPlaybackIdentity] { lock.withLock { storedActive } }
    var requests: [URLRequest] { lock.withLock { storedRequests } }
    func heartbeats(_ identity: PreparedPlaybackIdentity) -> Int { lock.withLock { storedHeartbeats.filter { $0 == identity }.count } }

    func respond(_ request: URLRequest) -> (Int, Data) {
        lock.withLock {
            storedRequests.append(request)
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            guard let session = query.first(where: { $0.name == "session" })?.value.flatMap(UInt64.init),
                  let generation = query.first(where: { $0.name == "request" })?.value.flatMap(UInt64.init) else { return (400, Data()) }
            let identity = PreparedPlaybackIdentity(session: session, generation: generation)
            let mediaGET = request.url?.path.hasPrefix("/web/media/") == true
            if request.httpMethod == "DELETE" {
                storedCancelled.append(identity)
                storedActive.removeAll { $0 == identity }
            } else if mediaGET {
                guard !storedCancelled.contains(identity) else { return (410, Data()) }
                storedActive.removeAll { $0.session == session && $0.generation < generation }
                if !storedActive.contains(identity) { storedActive.append(identity) }
            } else {
                storedHeartbeats.append(identity)
            }
            return (200, Data("{\"schema_version\":2,\"item_id\":\"42001\",\"request_id\":\(generation),\"state\":\"\(request.httpMethod == "DELETE" ? "cancelled" : "producing")\",\"retry_after_seconds\":null}".utf8))
        }
    }
}

private final class PlaybackOwnershipHTTPProtocol: URLProtocol {
    static var server: PlaybackOwnershipServer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let server = Self.server, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = server.respond(request)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
