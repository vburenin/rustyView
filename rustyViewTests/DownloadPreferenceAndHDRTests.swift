import AVFoundation
import XCTest
@testable import rustyView

@MainActor
final class DownloadPreferenceAndHDRTests: XCTestCase {
    func testDownloadLimitSurvivesRelaunchAndCannotBecomeStreamingAuto() throws {
        let suite = "download-limits-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DownloadPreferences(defaults: defaults)
        preferences.maximumQuality = .init(width: 1920, height: 1080, videoKbps: 8_000)
        preferences.audioSelection = .all
        PlaybackPreferences(defaults: defaults).preferredQualityID = "uhd_high"
        let restored = DownloadPreferences(defaults: defaults)
        let caps = try capabilities()
        let item = try item(width: 3840, height: 2160)
        let resolved = restored.resolve(item: item, capabilities: caps)
        XCTAssertEqual(resolved.quality, "full_hd")
        XCTAssertEqual(restored.audioSelection, .all)
        XCTAssertEqual(PlaybackPreferences(defaults: defaults).preferredQualityID, "uhd_high")
        let path = RustyDLNAClient(configuration: .ephemeral).compatiblePath(for: item, delivery: "mp4",
            quality: try XCTUnwrap(resolved.quality), downloadAudio: restored.audioSelection)
        XCTAssertEqual(query("quality", path), "full_hd")
        XCTAssertEqual(query("download_audio", path), "all")
        XCTAssertEqual(query("video_mode", path), "transcode")
        let oldServer = ServerCapabilities(transcoding: true, captions: true,
            qualityProfiles: caps.qualityProfiles.filter { $0.id == "auto" || $0.id == "uhd_high" })
        let unavailable = restored.resolve(item: item, capabilities: oldServer)
        XCTAssertNil(unavailable.quality, "A missing bounded profile cannot silently become unbounded Auto")
        XCTAssertNotNil(unavailable.issue)
        XCTAssertEqual(restored.maximumQuality, preferences.maximumQuality)
    }

    func testSmallSourceUsesNativeNoUpscaleContractAndLegacyAIUsesASafeEnvelope() throws {
        let suite = "download-small-source-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DownloadPreferences(defaults: defaults)
        let small = try item(width: 1024, height: 576)
        var caps = try capabilities()
        XCTAssertEqual(preferences.resolve(item: small, capabilities: caps).quality, "full_hd",
                       "The native server keeps the source dimensions while applying the selected bitrate cap")
        caps.nativeDownloads = false
        caps.aiUpscale = AIUpscaleCapability(label: "Synthetic upscaler")
        XCTAssertEqual(preferences.resolve(item: small, capabilities: caps).quality, "sd_480")
        XCTAssertNotNil(preferences.resolve(item: try item(width: 160, height: 90), capabilities: caps).issue)
    }

    func testHDRRequestAndDurableRetryKeepOutputQualityAndAllAudio() throws {
        let hdr = try item(width: 3840, height: 2160, hdr: true)
        let client = RustyDLNAClient(configuration: .ephemeral)
        let path = client.compatiblePath(for: hdr, delivery: "mp4", quality: "full_hd", audioIndex: 1, downloadAudio: .all)
        XCTAssertEqual(query("video_output", path), "hevc_hdr10")
        let retry = try DownloadPreparedRequest.replacementPath(path)
        for name in ["quality", "video_output", "download_audio", "audio"] {
            XCTAssertEqual(query(name, path), query(name, retry))
        }
        XCTAssertNotEqual(query("request", path), query("request", retry))
        let sdr = client.compatiblePath(for: hdr, delivery: "mp4", quality: "full_hd", preserveHDR: false)
        XCTAssertEqual(query("video_output", sdr), "h264_sdr")
    }

    func testActualPreparedHTTPFailureTriesHDRThenSDRKeepingQualityTimeAndSession() async throws {
        let fixture = try await CaptionHTTPFixture.make()
        defer { fixture.stop() }
        let model = PlaybackModel(client: fixture.client, progressTimeout: 0.35, watchdogInterval: .milliseconds(50))
        defer { model.stop() }
        model.play(try item(width: 3840, height: 2160, hdr: true), mode: .automatic,
                   quality: "full_hd", audioIndex: 1, startAt: 45)
        let terminal = expectation(description: "Real rejected HLS loads finish bounded format recovery")
        let poll = Task {
            for _ in 0..<1000 {
                if model.errorMessage != nil { terminal.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await fulfillment(of: [terminal], timeout: 11)
        poll.cancel()
        let requests = fixture.server.preparedRequests
        XCTAssertEqual(query("video_output", try XCTUnwrap(requests.first)), "hevc_hdr10")
        XCTAssertTrue(requests.contains { query("video_output", $0) == "h264_sdr" })
        XCTAssertEqual(Set(requests.compactMap { query("session", $0) }).count, 1)
        XCTAssertTrue(requests.allSatisfy { query("quality", $0) == "full_hd" && query("audio", $0) == "1" && query("start", $0) == "45" })
        XCTAssertNotNil(model.streamFormatNotice)
        XCTAssertEqual(model.currentTime, 45)
        XCTAssertFalse(model.isPreparing)
    }

    func testRealHDRFileStaysHDRThroughInspectionInstallationAndPlayback() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-hdr10", withExtension: "mp4"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = root.appendingPathComponent("received.tmp")
        try FileManager.default.copyItem(at: source, to: incoming)
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        var metadata = DownloadTaskMetadata(recordID: UUID(), serverOrigin: "https://hdr.example.test", mediaID: "79001",
            title: "The Prism Observatory", kind: .compatible, fileExtension: "mp4", durationSeconds: 3600,
            resolution: "3840×2160", accountUsername: "viewer")
        metadata.videoOutput = "hevc_hdr10"
        let record = try await Task.detached { try store.install(temporaryURL: incoming, metadata: metadata) }.value
        XCTAssertTrue(record.isReadyToWatch)
        XCTAssertEqual(record.assetInspection?.containsHDRVideo, true)
        XCTAssertEqual(record.movieMetadata.resolution, "320×180")
        XCTAssertEqual(record.movieMetadata.hdr, "HDR10")
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral))
        defer { model.stop() }
        model.playLocal(record: record, url: store.localURL(for: record))
        let advancing = expectation(description: "AVFoundation actually plays the installed HEVC Main 10 asset")
        let poll = Task {
            for _ in 0..<600 {
                if model.currentTime > 0.5 { advancing.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await fulfillment(of: [advancing], timeout: 7)
        poll.cancel()
        XCTAssertNil(model.errorMessage)
    }

    func testServerGeneratedHDRDownloadExposesAndPlaysBothNativeAudioTracks() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-server-hdr10", withExtension: "mp4"))
        let inspection = await Task.detached { DownloadAssetInspector.inspect(url) }.value
        XCTAssertEqual(inspection.integrity, .verified)
        XCTAssertEqual(inspection.containsHDRVideo, true)
        XCTAssertEqual(inspection.audioTrackCount, 2)
        let record = DownloadRecord(id: UUID(), serverOrigin: "https://hdr.example.test", mediaID: "79002",
            title: "The Synthetic Prism", kind: .compatible, fileName: url.lastPathComponent,
            byteCount: Int64(try Data(contentsOf: url).count), completedAt: Date(), durationSeconds: 3,
            resolution: "320×180", artworkPath: nil, accountUsername: "viewer", assetInspection: inspection)
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral))
        defer { model.stop() }
        model.playLocal(record: record, url: url, preservingIntent: .paused)
        let tracksLoaded = expectation(description: "The server's MP4 exposes actual native language options")
        let poll = Task {
            for _ in 0..<500 {
                if !model.isLoadingLocalTracks && model.localAudioTracks.count == 2 { tracksLoaded.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await fulfillment(of: [tracksLoaded], timeout: 6)
        poll.cancel()
        let french = try XCTUnwrap(model.localAudioTracks.first { PlaybackLanguage.matches($0.language, "fr") })
        model.selectLocalAudio(french.id)
        let playerItem = try XCTUnwrap(model.player.currentItem)
        let group = try await playerItem.asset.loadMediaSelectionGroup(for: .audible)
        let selected = try XCTUnwrap(playerItem.currentMediaSelection.selectedMediaOption(in: XCTUnwrap(group)))
        XCTAssertTrue(PlaybackLanguage.matches(selected.extendedLanguageTag, "fr"))
        model.togglePlayback()
        let advancing = expectation(description: "The actual server HDR and selected AC-3 track play in AVFoundation")
        let play = Task {
            for _ in 0..<500 {
                if model.currentTime > 0.5 { advancing.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await fulfillment(of: [advancing], timeout: 6)
        play.cancel()
        XCTAssertNil(model.errorMessage)
    }

    private func capabilities() throws -> ServerCapabilities {
        try JSONDecoder().decode(ServerCapabilities.self, from: Data(#"{"transcoding":true,"captions":true,"native_downloads":true,"quality_profiles":[{"id":"auto","label":"Auto","max_width":3840,"max_height":2160,"max_video_kbps":25000,"expected_bandwidth_kbps":25450,"automatic_fallback":false},{"id":"uhd_high","label":"4K","max_width":3840,"max_height":2160,"max_video_kbps":25000,"expected_bandwidth_kbps":25450,"automatic_fallback":false},{"id":"full_hd","label":"1080p","max_width":1920,"max_height":1080,"max_video_kbps":8000,"expected_bandwidth_kbps":8450,"automatic_fallback":false},{"id":"sd_480","label":"480p","max_width":854,"max_height":480,"max_video_kbps":1500,"expected_bandwidth_kbps":1880,"automatic_fallback":false}]}"#.utf8))
    }

    private func item(width: Int, height: Int, hdr: Bool = false) throws -> MediaItem {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)) as? [String: Any])
        var item = try XCTUnwrap(json["item"] as? [String: Any])
        item["width"] = width; item["height"] = height
        item["video_codec"] = hdr ? "hevc" : "h264"
        item["hdr"] = hdr ? "hdr10" : "sdr"
        item["prepared_video_outputs"] = hdr ? ["h264_sdr", "hevc_hdr10"] : ["h264_sdr"]
        json["item"] = item
        return try JSONDecoder().decode(ItemResponse.self, from: JSONSerialization.data(withJSONObject: json)).item
    }

    private func query(_ name: String, _ path: String) -> String? {
        URLComponents(string: path)?.queryItems?.first { $0.name == name }?.value
    }
}
