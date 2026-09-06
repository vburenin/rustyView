import AVFoundation
import XCTest
@testable import rustyView

@MainActor
final class PlaybackPreferencesTests: XCTestCase {
    func testUnavailableQualityNoticeFollowsViewingRecoveryUntilExplicitApply() async throws {
        let suite = "playback-notice-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackPreferences(defaults: defaults)
        preferences.preferredQualityID = "full_hd"
        let profiles = [profile("low", "Save Data")]
        let resolution = preferences.quality(in: profiles)
        let http = try await CaptionHTTPFixture.make()
        defer { http.stop() }
        http.server.holdMediaRequests()
        let client = http.client
        let connection = try XCTUnwrap(client.connection)
        let model = PlaybackModel(client: client, preferences: preferences)
        defer { model.stop() }
        let item = try fixture()
        model.play(.online(item: item, connection: connection, start: .position(123),
                           quality: resolution.qualityID, qualityNotice: resolution.notice, qualityProfiles: profiles))
        model.togglePlayback()
        await waitForAsset(model)
        let initialAsset = try XCTUnwrap(model.player.currentItem)
        XCTAssertNotNil(model.qualityNotice)
        XCTAssertEqual(model.qualityProfiles?.map(\.id), ["low"])
        model.retryCompatible()
        await waitForAsset(model)
        XCTAssertFalse(model.player.currentItem === initialAsset)
        XCTAssertEqual(model.qualityNotice, resolution.notice, "Recovery cannot hide why the saved preference was unavailable")
        model.retryCurrentPlayback()
        await waitForAsset(model)
        XCTAssertEqual(model.qualityNotice, resolution.notice)
        XCTAssertEqual(preferences.preferredQualityID, "full_hd", "Automatic recovery cannot erase the saved preference")

        let recovered = model.player.currentItem
        var draft = StreamingSettingsDraft(mode: model.mode, quality: model.selectedQuality)
        draft.selectQuality("low")
        XCTAssertEqual(model.qualityNotice, resolution.notice, "Draft edits do not commit a new choice")
        XCTAssertTrue(model.player.currentItem === recovered)
        XCTAssertTrue(model.applyStreamingChanges(draft, profiles: profiles))
        await waitForAsset(model)
        XCTAssertNil(model.qualityNotice)
        XCTAssertEqual(model.transport.intent, .paused)
        let url = try XCTUnwrap(model.currentSourceURL)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "quality" }?.value, "low")
        XCTAssertEqual(preferences.preferredQualityID, "low")

        model.play(.online(item: item, connection: connection, quality: "auto"))
        XCTAssertNil(model.qualityNotice, "A new viewing cannot inherit another request's notice")
        XCTAssertNil(model.qualityProfiles)
    }

    func testDraftCancelLeavesAssetUntouchedAndApplyCommitsConsistentPausedSelection() async throws {
        let suite = "playback-draft-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackPreferences(defaults: defaults)
        let http = try await CaptionHTTPFixture.make()
        defer { http.stop() }
        http.server.holdMediaRequests()
        let client = http.client
        let model = PlaybackModel(client: client, preferences: preferences)
        defer { model.stop() }
        model.play(try fixture(), mode: .portable, quality: "full_hd", audioIndex: 0, startAt: 123)
        model.togglePlayback()
        await waitForAsset(model)
        let asset = try XCTUnwrap(model.player.currentItem)
        var abandoned = StreamingSettingsDraft(mode: model.mode, quality: model.selectedQuality)
        abandoned.selectMode(.original)
        XCTAssertEqual(abandoned.quality, "auto")
        XCTAssertTrue(model.player.currentItem === asset, "Draft selection cannot restart the active stream")
        XCTAssertEqual(model.mode, .portable)
        XCTAssertEqual(model.selectedQuality, "full_hd")
        XCTAssertEqual(preferences.preferredQualityID, "auto", "Discarding a draft must not persist it")

        var applied = StreamingSettingsDraft(mode: .original, quality: "auto")
        applied.selectQuality("full_hd")
        XCTAssertEqual(applied.mode, .compatible, "The draft must reveal the route required by explicit quality")
        let profiles = [profile("full_hd", "Full HD")]
        XCTAssertTrue(model.applyStreamingChanges(applied, profiles: profiles))
        await waitForAsset(model)
        XCTAssertFalse(model.player.currentItem === asset)
        XCTAssertEqual(model.transport.intent, .paused)
        XCTAssertEqual(model.currentTime, 123)
        XCTAssertEqual(model.mode, .compatible)
        let url = try XCTUnwrap(model.currentSourceURL)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "quality" }?.value, "full_hd")
        XCTAssertEqual(PlaybackPreferences(defaults: defaults).preferredQualityID, "full_hd")

        let current = model.player.currentItem
        var unavailable = applied
        unavailable.selectQuality("missing_profile")
        XCTAssertFalse(model.applyStreamingChanges(unavailable, profiles: profiles))
        XCTAssertTrue(model.player.currentItem === current, "Unavailable quality cannot be silently applied as Auto")
        XCTAssertEqual(preferences.preferredQualityID, "full_hd")
    }

    func testPreferredQualitySurvivesRelaunchAndMissingServerProfileHasHonestEffectiveValue() throws {
        let suite = "playback-quality-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        PlaybackPreferences(defaults: defaults).preferredQualityID = "full_hd"
        let restored = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(restored.quality(in: [profile("full_hd", "Full HD")]).qualityID, "full_hd")
        let missing = restored.quality(in: [profile("auto", "Auto"), profile("low", "Save Data")])
        XCTAssertEqual(missing.qualityID, "auto")
        XCTAssertEqual(missing.displayLabel, "Auto")
        XCTAssertNotNil(missing.notice)
        XCTAssertEqual(restored.preferredQualityID, "full_hd", "Visiting a less capable server cannot erase the preferred quality")
        restored.preferredQualityID = "low"
        XCTAssertNil(restored.quality(in: [profile("low", "Save Data")]).notice)
    }

    func testSavedLanguageSelectsActualNativeTrackAndUsesNewServerIndexAfterRelaunch() async throws {
        let suite = "playback-language-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        PlaybackPreferences(defaults: defaults).preferredAudioLanguage = "fr-FR"
        let restored = PlaybackPreferences(defaults: defaults)
        let data = Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var item = try XCTUnwrap(json["item"] as? [String: Any])
        var tracks = try XCTUnwrap(item["audio_tracks"] as? [[String: Any]])
        tracks[0]["language"] = "fra"
        tracks[0]["index"] = 37
        tracks[1]["language"] = "eng"
        tracks[1]["index"] = 2
        item["audio_tracks"] = tracks.reversed().map { $0 }
        item["default_audio_index"] = 2
        json["item"] = item
        let changed = try JSONDecoder().decode(ItemResponse.self, from: JSONSerialization.data(withJSONObject: json)).item
        XCTAssertEqual(restored.audioIndex(in: changed), 37, "Language must resolve to this item's index, even after reordering")

        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-native-tracks", withExtension: "mp4"))
        let record = DownloadRecord(id: UUID(), serverOrigin: "https://preferences.example.test", mediaID: "74001",
            title: "The Copper Moon", kind: .original, fileName: url.lastPathComponent,
            byteCount: Int64(try Data(contentsOf: url).count), completedAt: Date(), durationSeconds: 6,
            resolution: "320x180", artworkPath: nil)
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral), preferences: restored)
        defer { model.stop() }
        model.playLocal(record: record, url: url, preservingIntent: .paused)
        let ready = expectation(description: "Actual local selection groups have loaded")
        let poll = Task {
            for _ in 0..<500 {
                if !model.isLoadingLocalTracks && model.localAudioTracks.count == 2 { ready.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await fulfillment(of: [ready], timeout: 6)
        poll.cancel()
        let playerItem = try XCTUnwrap(model.player.currentItem)
        let loaded = try await playerItem.asset.loadMediaSelectionGroup(for: .audible)
        let group = try XCTUnwrap(loaded)
        let selected = try XCTUnwrap(playerItem.currentMediaSelection.selectedMediaOption(in: group))
        XCTAssertTrue(PlaybackLanguage.matches(selected.extendedLanguageTag, "fr"),
                      "A remembered language must reach the native player, not only its menu selection")
    }

    private func fixture() throws -> MediaItem {
        try JSONDecoder().decode(ItemResponse.self, from: Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)).item
    }
    private func waitForAsset(_ model: PlaybackModel) async {
        let attached = expectation(description: "The owned asynchronous asset factory attaches its actual AVPlayerItem")
        let poll = Task {
            for _ in 0..<300 {
                if model.player.currentItem != nil { attached.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await fulfillment(of: [attached], timeout: 4)
        poll.cancel()
    }
    private func profile(_ id: String, _ label: String) -> QualityProfile {
        QualityProfile(id: id, label: label, maxWidth: 1920, maxHeight: 1080, expectedBandwidthKbps: 8000, automaticFallback: false)
    }
}
