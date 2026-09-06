import AVFoundation
import XCTest
@testable import rustyView

@MainActor
final class OfflinePlaybackTracksTests: XCTestCase {
    func testSavedAssetAudioNativeAndSidecarCaptionsAndChapterUseActualLocalSelections() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-native-tracks", withExtension: "mp4"))
        let captionURL = FileManager.default.temporaryDirectory.appendingPathComponent("owned-\(UUID().uuidString).vtt")
        try Data("WEBVTT\n\n00:00:00.000 --> 00:00:06.000\nOwned moon dial cue\n".utf8).write(to: captionURL)
        defer { try? FileManager.default.removeItem(at: captionURL) }
        var record = DownloadRecord(id: UUID(), serverOrigin: "https://offline.example.test", mediaID: "72001",
                                    title: "The Paper Lantern", kind: .original, fileName: url.lastPathComponent,
                                    byteCount: Int64(try Data(contentsOf: url).count), completedAt: Date(),
                                    durationSeconds: 6, resolution: "320x180", artworkPath: nil)
        var movie = MovieMetadata(mediaID: record.mediaID, title: record.title, durationSeconds: 6)
        movie.chapters = [MovieChapter(id: 91, title: "Lantern turns", startSeconds: 2, endSeconds: 6)]
        record.movie = movie
        let caption = OfflineCaption(id: UUID(), label: "Owned English", language: "eng", isDefault: false,
                                     isForced: false, fileName: captionURL.lastPathComponent)
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral))
        defer { model.stop() }
        // No configured connection exists; the request must remain wholly local.
        model.play(.offline(record: record, url: url, captionSources: [.init(caption: caption, url: captionURL)], start: .startOver))
        await waitFor("Native groups and the owned sidecar are available") {
            !model.isLoadingLocalTracks && model.localAudioTracks.count == 2
                && model.localSubtitleTracks.contains { $0.id == caption.id.uuidString }
                && model.localSubtitleTracks.contains { $0.id != caption.id.uuidString && !$0.isForced }
        }
        let french = try XCTUnwrap(model.localAudioTracks.first { $0.language?.hasPrefix("fr") == true })
        model.selectLocalAudio(french.id)
        let playerItem = try XCTUnwrap(model.player.currentItem)
        let loadedAudioGroup = try await playerItem.asset.loadMediaSelectionGroup(for: .audible)
        let audioGroup = try XCTUnwrap(loadedAudioGroup)
        let actualAudio = try XCTUnwrap(playerItem.currentMediaSelection.selectedMediaOption(in: audioGroup))
        XCTAssertTrue(actualAudio.extendedLanguageTag?.hasPrefix("fr") == true)
        XCTAssertEqual(model.selectedLocalAudioID, french.id)

        let embedded = try XCTUnwrap(model.localSubtitleTracks.first { $0.id != caption.id.uuidString && !$0.isForced })
        await model.selectLocalSubtitle(embedded.id)
        let loadedLegibleGroup = try await playerItem.asset.loadMediaSelectionGroup(for: .legible)
        let legible = try XCTUnwrap(loadedLegibleGroup)
        XCTAssertNotNil(playerItem.currentMediaSelection.selectedMediaOption(in: legible),
                        "Selecting native subtitles must reach AVPlayerItem, not merely mark a menu row")
        await model.selectLocalSubtitle(caption.id.uuidString)
        XCTAssertNil(playerItem.currentMediaSelection.selectedMediaOption(in: legible),
                     "Selecting a sidecar must disable native captions to avoid duplicate rendering")
        model.seek(toGlobalTime: try XCTUnwrap(model.chapters.first).startSeconds)
        await waitFor("Chapter seek advances real video while the owned sidecar renders") {
            model.player.currentTime().seconds >= 2.1 && model.currentSubtitle == "Owned moon dial cue"
        }
        XCTAssertEqual(model.currentChapterIndex, 91)
        XCTAssertNil(model.item)
        XCTAssertEqual(model.movieMetadata?.title, "The Paper Lantern")
        await model.selectLocalSubtitle(nil)
        XCTAssertNil(model.currentSubtitle)
        XCTAssertNil(playerItem.currentMediaSelection.selectedMediaOption(in: legible))
        XCTAssertNil(model.errorMessage)
    }

    func testOnlineRequestCannotAdoptAChangedAccount() throws {
        let first = try ServerConnection(serverAddress: "https://offline.example.test", username: "first", password: "synthetic")
        let second = try ServerConnection(serverAddress: "https://offline.example.test", username: "second", password: "synthetic")
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(first)
        let item = try JSONDecoder().decode(ItemResponse.self, from: Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)).item
        let request = PlaybackRequest.online(item: item, connection: first, quality: "full_hd", audioIndex: 0)
        client.configure(second)
        let model = PlaybackModel(client: client)
        defer { model.stop() }
        model.play(request)
        XCTAssertNil(model.player.currentItem, "A request prepared for another account must never create an AVAsset")
        XCTAssertFalse(model.isPresented)
        XCTAssertNotNil(model.errorMessage)
    }

    func testOfflineRequestRejectsNetworkURLBeforeCreatingMediaAsset() throws {
        let record = DownloadRecord(id: UUID(), serverOrigin: "https://offline.example.test", mediaID: "72001",
                                    title: "The Paper Lantern", kind: .original, fileName: "owned.mp4", byteCount: 100,
                                    completedAt: Date(), durationSeconds: 6, resolution: nil, artworkPath: nil)
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral))
        defer { model.stop() }
        model.play(.offline(record: record, url: try XCTUnwrap(URL(string: "https://offline.example.test/owned.mp4"))))
        XCTAssertNil(model.player.currentItem, "An offline request must reject HTTP even when the source is on the original server")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.transport.actionLabel, "Retry Current Playback")
    }

    func testOfflineResumeRejectsAnOnlinePositionBeyondTheInspectedFile() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-native-tracks", withExtension: "mp4"))
        let inspection = await Task.detached { DownloadAssetInspector.inspect(url) }.value
        let suite = "offline-resume-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let progress = PlaybackProgressStore(defaults: defaults)
        progress.update(serverOrigin: "https://offline.example.test", mediaID: "72001", position: 2400, duration: 5528)
        let record = DownloadRecord(id: UUID(), serverOrigin: "https://offline.example.test", mediaID: "72001",
                                    title: "The Paper Lantern", kind: .original, fileName: url.lastPathComponent,
                                    byteCount: Int64(try Data(contentsOf: url).count), completedAt: Date(),
                                    durationSeconds: 5528, resolution: nil, artworkPath: nil, assetInspection: inspection)
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral), progressStore: progress)
        defer { model.stop() }
        XCTAssertEqual(progress.resumePosition(serverOrigin: record.serverOrigin, mediaID: record.mediaID), 2400,
                       "The saved online position remains available for the actual long source")
        XCTAssertNil(model.resumePosition(for: record), "Offline details must not offer a timestamp beyond their inspected file")
        model.play(.offline(record: record, url: url))
        XCTAssertEqual(model.currentTime, 0)
        await waitFor("The shorter downloaded file starts and actually advances") {
            model.player.currentTime().seconds >= 0.5 && model.player.currentTime().seconds < 3
        }
        XCTAssertNil(model.errorMessage)
    }

    private func waitFor(_ description: String, _ condition: @escaping () -> Bool) async {
        let reached = expectation(description: description)
        let poll = Task {
            for _ in 0..<500 {
                if condition() { reached.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await fulfillment(of: [reached], timeout: 6)
        poll.cancel()
    }
}
