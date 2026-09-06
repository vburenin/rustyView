import AVFoundation
import Foundation
import XCTest
@testable import rustyView

/// These tests exercise the application's actual asset wrapper and real iOS
/// AVPlayer over two OS-trusted synthetic HTTPS origins. No URLProtocol or
/// delegate invocation stands in for media loading. Each test owns unique URLs.
@MainActor
final class AVFoundationOriginTests: XCTestCase {
    func testTrustedNativeHTTPSOriginalSupportsPlaybackAndSeeking() async throws {
        let fixture = try AVOriginFixture.load()
        let viewer = try await AVOriginViewer(client: fixture.client, path: fixture.path("media.mp4"))
        defer { viewer.stop() }
        try await viewer.waitForPlayback()
        let seeked = await viewer.player.seek(to: CMTime(seconds: 4, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(seeked)
        try await waitUntil("A real native seek must reach the requested media time") {
            viewer.player.currentTime().seconds >= 4.25 || viewer.item.status == .failed
        }
        XCTAssertGreaterThanOrEqual(viewer.player.currentTime().seconds, 4.25)
        let counts = try await fixture.counts()
        XCTAssertGreaterThan(counts["trustedRangeRequests"] ?? 0, 0)
        XCTAssertGreaterThan(counts["trustedMediaResponseBytes"] ?? 0, 0)
        XCTAssertGreaterThan(counts["trustedFirstCredentials"] ?? 0, 0)
        XCTAssertEqual(counts["hostileRequests"] ?? 0, 0)
    }

    func testTrustedNativeHTTPSHLSMasterKeyMapAndRedirectControlsPlay() async throws {
        for resource in ["same.m3u8", "master.m3u8", "encrypted.m3u8", "fmp4.m3u8", "same-redirect.mp4"] {
            let fixture = try AVOriginFixture.load()
            let viewer = try await AVOriginViewer(client: fixture.client, path: fixture.path(resource))
            defer { viewer.stop() }
            try await viewer.waitForPlayback()
            let counts = try await fixture.counts()
            XCTAssertEqual(viewer.item.status, .readyToPlay, resource)
            XCTAssertGreaterThan(counts["trustedMediaResponseBytes"] ?? 0, 0, resource)
            XCTAssertGreaterThan(counts["trustedFirstCredentials"] ?? 0, 0, resource)
            XCTAssertEqual(counts["hostileRequests"] ?? 0, 0, resource)
            if resource == "same-redirect.mp4" {
                XCTAssertGreaterThanOrEqual(counts["trustedPathsame_redirect_mp4"] ?? 0, 3,
                                          "Legitimate same-origin redirect hops must reach native playback")
            }
        }
    }

    func testNativeHTTPSRedirectCannotRequestAnotherPort() async throws {
        try await assertConfined("redirect.mp4")
    }

    func testNativeHTTPSMasterCannotRequestForeignMediaPlaylist() async throws {
        try await assertConfined("master-foreign.m3u8")
    }

    func testNativeHTTPSMediaPlaylistCannotRequestForeignSegment() async throws {
        try await assertConfined("media-foreign.m3u8")
    }

    func testNativeHTTPSMediaAttributeCannotRequestForeignRendition() async throws {
        try await assertConfined("media-attribute-foreign.m3u8")
    }

    func testNativeHTTPSOwnedSegmentCannotFollowForeignRedirect() async throws {
        try await assertConfined("segment-redirect.m3u8")
    }

    func testNativeHTTPSOriginalCannotSniffForeignPlaylistBehindMP4Headers() async throws {
        try await assertConfined("disguised.mp4")
    }

    func testNativeHTTPSMediaSegmentCannotSniffForeignPlaylistBehindTSHeaders() async throws {
        try await assertConfined("disguised-segment.m3u8", control: "same.m3u8")
    }

    func testNativeHTTPSKeyAttributeCannotRequestForeignKey() async throws {
        try await assertConfined("key-foreign.m3u8", control: "encrypted.m3u8")
    }

    func testNativeHTTPSMapAttributeCannotRequestForeignInitialization() async throws {
        try await assertConfined("map-foreign.m3u8", control: "fmp4.m3u8")
    }

    func testNativeHTTPSRedirectCannotReuseWarmForeignConnection() async throws {
        try await assertConfined("redirect.mp4", warmingForeignOrigin: true)
    }

    func testHeldNativeHTTPSChallengeKeepsItsStartingAccountAfterConnectionEdit() async throws {
        let fixture = try AVOriginFixture.load()
        let viewer = try await AVOriginViewer(client: fixture.client, path: fixture.path("held.mp4"))
        defer { viewer.stop() }
        try await fixture.waitForCount("trustedHeldRequests", atLeast: 1)
        fixture.client.configure(try fixture.connection(secondAccount: true))
        try await fixture.release()
        try await viewer.waitForPlayback()
        let counts = try await fixture.counts()
        XCTAssertGreaterThan(counts["trustedPathheld_mp4FirstCredentials"] ?? 0, 0)
        XCTAssertEqual(counts["trustedPathheld_mp4SecondCredentials"] ?? 0, 0,
                       "A delayed challenge must use the account that created this asset")
        let replacement = try await AVOriginViewer(client: fixture.client, path: fixture.path("media.mp4"))
        defer { replacement.stop() }
        try await replacement.waitForPlayback()
        let replacementCounts = try await fixture.counts()
        XCTAssertGreaterThan(replacementCounts["trustedPathmedia_mp4SecondCredentials"] ?? 0, 0)
    }

    func testCancelHeldNativeHTTPSLoadClosesOldTransferBeforeNewAccountPlays() async throws {
        let fixture = try AVOriginFixture.load()
        let viewer = try await AVOriginViewer(client: fixture.client, path: fixture.path("held.mp4"))
        try await fixture.waitForCount("trustedHeldRequests", atLeast: 1)
        viewer.stop()
        fixture.client.configure(try fixture.connection(secondAccount: true))
        try await fixture.waitForCount("trustedHeldClosed", atLeast: 1)
        let stopped = try await fixture.counts()
        try await fixture.release()
        let replacement = try await AVOriginViewer(client: fixture.client, path: fixture.path("media.mp4"))
        defer { replacement.stop() }
        try await replacement.waitForPlayback()
        let counts = try await fixture.counts()
        XCTAssertEqual(counts["trustedHeldRequests"] ?? 0, stopped["trustedHeldRequests"] ?? 0,
                       "Releasing a cancelled response cannot start a late authentication retry")
        XCTAssertEqual(counts["trustedPathheld_mp4SecondCredentials"] ?? 0, 0)
        XCTAssertGreaterThan(counts["trustedPathmedia_mp4SecondCredentials"] ?? 0, 0)
    }

    private func assertConfined(_ resource: String, control: String = "media.mp4", warmingForeignOrigin: Bool = false) async throws {
        let fixture = try AVOriginFixture.load()
        // A positive actual-media control prevents TLS, Basic auth or decoder
        // failure from falsely satisfying the hostile-response assertions.
        let positive = try await AVOriginViewer(client: fixture.client, path: fixture.path(control))
        try await positive.waitForPlayback()
        positive.stop()
        if warmingForeignOrigin {
            let warmClient = RustyDLNAClient(configuration: .ephemeral)
            warmClient.configure(try fixture.connection(hostile: true))
            let warm = try await AVOriginViewer(client: warmClient, path: fixture.path("media.mp4"))
            try await warm.waitForPlayback()
            warm.stop()
        }
        let before = try await fixture.counts()
        let viewer = try await AVOriginViewer(client: fixture.client, path: fixture.path(resource))
        defer { viewer.stop() }
        try await waitUntil("The hostile media attempt must report a terminal trust rejection") {
            viewer.terminalFailure != nil || viewer.player.currentTime().seconds >= 0.5
        }
        let counts = try await fixture.counts()
        XCTAssertGreaterThan(counts["trustedRequests"] ?? 0, before["trustedRequests"] ?? 0)
        XCTAssertEqual(counts["hostileRequests"] ?? 0, before["hostileRequests"] ?? 0,
                       "No HTTP request may reach the other HTTPS port, even without credentials: \(resource)")
        XCTAssertEqual(counts["hostileCredentials"] ?? 0, before["hostileCredentials"] ?? 0,
                       "No credential may reach the foreign origin: \(resource)")
        XCTAssertEqual(viewer.terminalFailure?.category, .transportSecurity, resource)
        XCTAssertEqual(viewer.terminalFailureCount, 1, "A rejected attempt must notify its owner exactly once")
        XCTAssertLessThan(viewer.player.currentTime().seconds, 0.5, resource)
        let failure = try XCTUnwrap(viewer.terminalFailure)
        viewer.stop()

        // AVFoundation can keep a segmented item unknown while retrying an
        // interrupted local request. The product must still leave Preparing
        // immediately, consume the typed rejection, and never try a fallback.
        let product = try MediaOriginProductViewer(client: fixture.client, path: fixture.path(resource))
        defer { product.stop() }
        try await waitUntil("The actual playback model must expose the trust failure") {
            product.model.errorMessage != nil
        }
        product.assertTrustFailure(failure)
        try await Task.sleep(for: .milliseconds(150))
        product.assertTrustFailure(failure)
        let productCounts = try await fixture.counts()
        XCTAssertGreaterThan(productCounts["trustedRequests"] ?? 0, counts["trustedRequests"] ?? 0,
                             "The product must exercise its own real media request")
        XCTAssertEqual(productCounts["hostileRequests"] ?? 0, before["hostileRequests"] ?? 0)
        XCTAssertEqual(productCounts["hostileCredentials"] ?? 0, before["hostileCredentials"] ?? 0)
    }

    private func waitUntil(_ message: String, _ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard predicate() else {
            XCTFail(message)
            throw NSError(domain: "SyntheticNativePlayback", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

@MainActor
private final class AVOriginViewer {
    private var retainedAsset: AuthenticatedMediaAsset?
    let item: AVPlayerItem
    let player: AVPlayer
    private(set) var terminalFailure: UserFacingError?
    private(set) var terminalFailureCount = 0
    init(client: RustyDLNAClient, path: String) async throws {
        let media = try await client.asset(serverPath: path)
        retainedAsset = media
        item = AVPlayerItem(asset: media.asset)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        media.onFailure = { [weak self] failure in
            self?.terminalFailure = failure
            self?.terminalFailureCount += 1
        }
        player.play()
    }
    func waitForPlayback() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while player.currentTime().seconds < 0.5, item.status != .failed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(item.status, .readyToPlay, "Synthetic HTTPS control must decode: \(item.error?.localizedDescription ?? "no error")")
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, 0.5,
                                    "Readiness alone does not prove native video advancement")
        guard item.status == .readyToPlay, player.currentTime().seconds >= 0.5 else {
            stop()
            throw NSError(domain: "SyntheticNativePlayback", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The synthetic native playback control did not advance."])
        }
    }
    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        retainedAsset?.stop()
        retainedAsset = nil
    }
}

/// Use the actual product error/attempt state, including enabled automatic
/// fallback, without changing app-wide progress or playback preferences.
@MainActor
final class MediaOriginProductViewer {
    let model: PlaybackModel
    private let defaults: UserDefaults
    private let namespace = "SyntheticMediaOrigin.\(UUID().uuidString)"

    init(client: RustyDLNAClient, path: String) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        model = PlaybackModel(client: client, progressStore: PlaybackProgressStore(defaults: defaults),
                              preferences: PlaybackPreferences(defaults: defaults))
        let item = MediaItem(
            id: "42098", title: "Synthetic Origin Voyage", fileName: "synthetic-origin.mp4", kind: .video,
            mime: "video/mp4", ext: "mp4", duration: "0:06", durationSeconds: 6, resolution: "640x360",
            width: 640, height: 360, about: nil, plot: nil, genre: nil, sizeBytes: 0, container: "mp4",
            videoCodec: "h264", videoProfile: nil, bitDepth: 8, frameRate: "30", videoRepairRequired: false,
            audioCodec: "aac", audioLayout: "stereo", codecString: nil, hdr: "sdr", audioTracks: [],
            defaultAudioIndex: 0, captions: [], chapters: [], artURL: nil, downloadURL: nil,
            sourceURL: path, fallbackURL: path, transcodeLikely: false
        )
        model.player.isMuted = true
        model.play(item, mode: .automatic, startAt: 0)
    }

    func assertTrustFailure(_ failure: UserFacingError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.errorMessage, failure.message, file: file, line: line)
        XCTAssertEqual(model.transport.phase, .failed(failure.message), file: file, line: line)
        XCTAssertEqual(model.transport.attempt, .original, "A trust failure must not start a prepared fallback", file: file, line: line)
        XCTAssertEqual(model.transport.recoveryAttempt, 0, file: file, line: line)
        XCTAssertFalse(model.isPreparing, file: file, line: line)
        XCTAssertFalse(model.isBuffering, file: file, line: line)
        XCTAssertFalse(model.isPlaying, file: file, line: line)
        XCTAssertEqual(model.player.rate, 0, file: file, line: line)
        XCTAssertEqual(model.transport.actionLabel, "Retry Current Playback", file: file, line: line)
    }

    func stop() {
        model.stop()
        defaults.removePersistentDomain(forName: namespace)
    }
}

@MainActor
private struct AVOriginFixture {
    struct Descriptor: Decodable { let trusted: String; let hostile: String }
    let descriptor: Descriptor
    let caseID: String
    let client: RustyDLNAClient
    private let controlClient: RustyDLNAClient
    static func load() throws -> Self {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HTTPSOriginFixture.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Start the staged HTTPS fixture on the dedicated rustyView Test iPhone before this gate.")
        }
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: Data(contentsOf: url))
        let trusted = try XCTUnwrap(URL(string: descriptor.trusted))
        let hostile = try XCTUnwrap(URL(string: descriptor.hostile))
        guard trusted.scheme == "https", hostile.scheme == "https", trusted.host == "127.0.0.1",
              hostile.host == "127.0.0.1", trusted.port != hostile.port else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let connection = try ServerConnection(serverAddress: descriptor.trusted, username: "tls-viewer", password: "synthetic-tls-secret")
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(connection)
        return Self(descriptor: descriptor, caseID: UUID().uuidString, client: client,
                    controlClient: try client.ownedConnection())
    }
    func path(_ resource: String) -> String { "/av/\(resource)?case=\(caseID)" }
    func connection(hostile: Bool = false, secondAccount: Bool = false) throws -> ServerConnection {
        try ServerConnection(serverAddress: hostile ? descriptor.hostile : descriptor.trusted,
                             username: secondAccount ? "second-tls-viewer" : "tls-viewer",
                             password: secondAccount ? "second-synthetic-tls-secret" : "synthetic-tls-secret")
    }
    func counts() async throws -> [String: Int] {
        try await JSONDecoder().decode([String: Int].self, from: controlClient.data(serverPath: "/observations?case=\(caseID)"))
    }
    func release() async throws { _ = try await controlClient.data(serverPath: path("release")) }
    func waitForCount(_ key: String, atLeast: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var observed = 0
        while ContinuousClock.now < deadline {
            observed = try await counts()[key] ?? 0
            if observed >= atLeast { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThanOrEqual(observed, atLeast, "Expected real HTTPS listener event: \(key)")
    }
}
