import AVFoundation
import XCTest
@testable import rustyView

@MainActor
final class ViewingExperienceTests: XCTestCase {
    func testSubtitleLanguageSurvivesPlayerAndPreferenceRestorationAndOffIsRemembered() async throws {
        let suite = "subtitle-preference-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (record, url) = try fixture()
        let first = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral),
                                  preferences: PlaybackPreferences(defaults: defaults))
        first.playLocal(record: record, url: url, preservingIntent: .paused)
        await waitFor { !first.isLoadingLocalTracks && !first.localSubtitleTracks.isEmpty }
        let track = try XCTUnwrap(first.localSubtitleTracks.first { !$0.isForced })
        await first.selectLocalSubtitle(track.id)
        XCTAssertNotNil(first.subtitleSelection.active)
        first.stop()

        let restored = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral),
                                     preferences: PlaybackPreferences(defaults: defaults))
        defer { restored.stop() }
        restored.playLocal(record: record, url: url, preservingIntent: .paused)
        await waitFor { !restored.isLoadingLocalTracks && !restored.localSubtitleTracks.isEmpty }
        XCTAssertNotNil(restored.subtitleSelection.active, "A new player must restore the selected language, not reset captions to Off")
        let playerItem = try XCTUnwrap(restored.player.currentItem)
        let loaded = try await playerItem.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loaded)
        XCTAssertNotNil(playerItem.currentMediaSelection.selectedMediaOption(in: group))
        restored.turnSubtitlesOff()
        restored.stop()

        let off = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral),
                               preferences: PlaybackPreferences(defaults: defaults))
        defer { off.stop() }
        off.playLocal(record: record, url: url, preservingIntent: .paused)
        await waitFor { !off.isLoadingLocalTracks && !off.localSubtitleTracks.isEmpty }
        XCTAssertEqual(off.subtitleSelection, .off, "An explicit Off must also survive relaunch")
    }

    func testProgressWriteFailureDoesNotRequestModalOverPlayingVideo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UserLibraryStore(directory: root)
        await store.waitUntilRestored()
        let index = root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        let (record, url) = try fixture()
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral), activityStore: store)
        defer { model.stop() }
        model.playLocal(record: record, url: url)
        await waitFor { store.persistenceError != nil && model.currentTime > 0.8 }
        XCTAssertNil(model.requestError, "Ordinary bookmark failures must not use the modal required-action error channel")
        XCTAssertNotNil(model.progressSaveNotice)
        XCTAssertEqual(model.transport.intent, .playing)
        model.togglePlayback()
        try? await store.flush()
        XCTAssertNil(model.requestError, "Another failed save must not re-open the alert")
        try FileManager.default.removeItem(at: index)
        await model.retrySavingProgress()
        XCTAssertNil(model.progressSaveNotice)
        let reopened = UserLibraryStore(directory: root)
        await reopened.waitUntilRestored()
        XCTAssertFalse(reopened.history.isEmpty, "Recovery must commit unsaved viewing activity")
    }

    private func fixture() throws -> (DownloadRecord, URL) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-native-tracks", withExtension: "mp4"))
        return (DownloadRecord(id: UUID(), serverOrigin: "https://viewing.example.test", mediaID: "78001",
            title: "The Amber Observatory", kind: .original, fileName: url.lastPathComponent,
            byteCount: Int64(try Data(contentsOf: url).count), completedAt: Date(), durationSeconds: 6,
            resolution: "320x180", artworkPath: nil), url)
    }

    private func waitFor(_ condition: @escaping () -> Bool) async {
        let ready = expectation(description: "Real media or storage transition completes")
        let poll = Task {
            for _ in 0..<600 {
                if condition() { ready.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await fulfillment(of: [ready], timeout: 7)
        poll.cancel()
    }
}
