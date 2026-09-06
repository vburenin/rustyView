import AVFoundation
import MediaPlayer
import XCTest
@testable import rustyView

/// Staged for D16. The real player decodes the local fixture; only the system's
/// notification boundary is driven by the test. No fabricated player rate or
/// readiness is substituted for observed AVFoundation state.
@MainActor
final class PlaybackSystemTests: XCTestCase {
    private static var nextMediaID: UInt64 = 77_000
    func testMediaServicesResetWhileInitialResumeIsHeldReplacesAudioObjectsAndWaitsForPlay() async throws {
        let (_, record, url) = try fixture()
        let store = PendingSystemActivityStore()
        store.isRestoring = true
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral), activityStore: store)
        defer { model.stop() }
        model.play(.offline(record: record, url: url))
        await waitFor("Initial Resume waits at its storage boundary") { store.restorePending }
        let originalPlayer = model.player
        XCTAssertNil(originalPlayer.currentItem)
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance())
        await waitFor("The reset replaces even the pending request's unpresented AVPlayer") { model.player !== originalPlayer }
        XCTAssertTrue(store.restorePending)
        XCTAssertNil(model.player.currentItem)
        store.releaseRestore()
        await waitFor("Restored media attaches to the new player at its saved frame") {
            model.player.currentItem?.status == .readyToPlay && model.player.currentTime().seconds >= 1.9
        }
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertEqual(model.transport.intent, .paused)
        XCTAssertNotNil(model.systemPlaybackNotice)
        model.togglePlayback()
        await waitFor("Explicit Play advances the recreated real player") { model.player.currentTime().seconds >= 2.4 }
        XCTAssertNil(model.systemPlaybackNotice)
    }

    func testMediaServicesResetRetainsCurrentNativeAudioChoiceInsteadOfApplyingANewMovieDefault() async throws {
        let (_, record, url) = try fixture()
        let namespace = "system-audio-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace) }
        let preferences = PlaybackPreferences(defaults: defaults)
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral), preferences: preferences)
        defer { model.stop() }
        model.playLocal(record: record, url: url, startAt: 1, preservingIntent: .paused)
        await waitFor("Real native audio options are available") { !model.isLoadingLocalTracks && model.localAudioTracks.count == 2 }
        let french = try XCTUnwrap(model.localAudioTracks.first { PlaybackLanguage.matches($0.language, "fra") })
        model.selectLocalAudio(french.id)
        // Updating the preference for future movies must not replace the
        // current movie's actual selected stream when system objects rebuild.
        preferences.preferredAudioLanguage = "eng"
        let oldPlayer = model.player
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance())
        await waitFor("The new real player restores this viewing's selected track") {
            model.player !== oldPlayer && !model.isLoadingLocalTracks && model.selectedLocalAudioID == french.id
        }
        let item = try XCTUnwrap(model.player.currentItem)
        let loadedGroup = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let group = try XCTUnwrap(loadedGroup)
        let selected = try XCTUnwrap(item.currentMediaSelection.selectedMediaOption(in: group))
        XCTAssertTrue(PlaybackLanguage.matches(selected.extendedLanguageTag ?? selected.locale?.identifier, "fra"))
        XCTAssertEqual(model.player.rate, 0)
    }

    func testExplicitPlayAfterInterruptedPreparationRestoresBoundedStartupRecovery() async throws {
        let fixture = try await CaptionHTTPFixture.make()
        defer { fixture.stop() }
        fixture.server.holdMediaRequests()
        let model = PlaybackModel(client: fixture.client, progressTimeout: 0.35, watchdogInterval: .milliseconds(50))
        defer { model.stop() }
        model.play(fixture.item, mode: .original)
        postInterruption(.began)
        await waitFor("Interruption suspends the held original preparation") { model.isSystemInterrupted }
        postInterruption(.ended)
        await waitFor("An interruption without permission leaves preparation deliberately paused") {
            !model.isSystemInterrupted && model.transport.intent == .paused
        }
        XCTAssertNil(model.errorMessage)
        model.togglePlayback()
        await waitFor("Explicit Play restarts the watchdog and held HTTP media reaches its bounded terminal recovery") {
            model.errorMessage != nil
        }
        XCTAssertEqual(model.transport.recoveryAttempt, 1, "Only the existing single original retry is allowed")
        XCTAssertEqual(model.player.rate, 0)
    }

    func testHeldStartOverCannotStartDuringInterruptionOrBeResumedByOldViewingPermission() async throws {
        let (_, record, url) = try fixture()
        let store = PendingSystemActivityStore()
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral), activityStore: store)
        defer { model.stop() }
        model.play(.offline(record: record, url: url, start: .position(0)))
        await waitFor("Old viewing advances before requesting durable Start Over") { model.player.currentTime().seconds >= 0.4 }
        let oldItem = try XCTUnwrap(model.player.currentItem)
        model.play(.offline(record: record, url: url, start: .startOver))
        await waitFor("Start Over waits for its real asynchronous commit boundary") { store.commitPending }
        postInterruption(.began)
        await waitFor("System interruption is active while the commit remains held") { model.isSystemInterrupted && model.player.rate == 0 }
        store.releaseCommit()
        await waitFor("Committed replacement is prepared during the interruption") { model.player.currentItem !== oldItem && model.player.currentItem?.status == .readyToPlay }
        XCTAssertEqual(model.player.rate, 0, "A newly committed request must obey the existing system suspension")
        postInterruption(.ended, options: .shouldResume)
        await waitFor("The old interruption has ended") { !model.isSystemInterrupted }
        XCTAssertEqual(model.transport.intent, .paused)
        XCTAssertEqual(model.player.rate, 0, "Permission belonging to the old viewing cannot start the new viewing")
        model.togglePlayback()
        await waitFor("Explicit Play starts the committed viewing") { model.player.currentTime().seconds >= 0.4 }
    }

    func testHeldResumeRestorationCannotStartDuringAnAlreadyActiveInterruption() async throws {
        let (_, record, url) = try fixture()
        let store = PendingSystemActivityStore()
        store.isRestoring = true
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral), activityStore: store)
        defer { model.stop() }
        model.play(.offline(record: record, url: url))
        await waitFor("Resume is waiting for restored storage") { store.restorePending }
        XCTAssertNil(model.player.currentItem)
        postInterruption(.began)
        await waitFor("An interruption is tracked even before an AV item exists") { model.isSystemInterrupted }
        store.releaseRestore()
        await waitFor("Restored resume creates a ready paused asset") { model.player.currentItem?.status == .readyToPlay && model.player.currentTime().seconds >= 1.9 }
        XCTAssertEqual(model.player.rate, 0)
        postInterruption(.ended, options: .shouldResume)
        await waitFor("Interruption ended without a prior active viewing to resume") { !model.isSystemInterrupted }
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertEqual(model.transport.intent, .paused)
        model.togglePlayback()
        await waitFor("Explicit Play advances from the restored resume time") { model.player.currentTime().seconds >= 2.4 }
    }
    func testInterruptionPausesActualPlaybackThenPermissionResumesTheSameViewing() async throws {
        let (model, record, url) = try fixture()
        defer { model.stop() }
        model.play(.offline(record: record, url: url, start: .position(0)))
        await waitFor("Real movie starts before interruption") { model.player.currentTime().seconds >= 0.5 }
        let asset = try XCTUnwrap(model.player.currentItem)
        postInterruption(.began)
        await waitFor("The posted interruption pauses actual output") { model.player.rate == 0 }
        let pausedAt = model.player.currentTime().seconds
        XCTAssertTrue(model.player.currentItem === asset)
        XCTAssertEqual(nowPlayingDouble(MPNowPlayingInfoPropertyPlaybackRate), 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.player.currentTime().seconds, pausedAt, accuracy: 0.1)
        postInterruption(.ended, options: .shouldResume)
        await waitFor("Permission resumes real playback from the interruption point") { model.player.currentTime().seconds >= pausedAt + 0.4 }
        XCTAssertTrue(model.player.currentItem === asset, "Ordinary interruption must not create another viewing or stream")
        XCTAssertNil(model.errorMessage)
    }

    func testDeliberatePauseWinsBeforeAndDuringAnInterruption() async throws {
        let (model, record, url) = try fixture()
        defer { model.stop() }
        model.playLocal(record: record, url: url, startAt: 1, preservingIntent: .paused)
        await waitFor("Paused movie is ready at its saved frame") { model.player.currentItem?.status == .readyToPlay && model.player.currentTime().seconds >= 0.95 }
        postInterruption(.began)
        postInterruption(.ended, options: .shouldResume)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.player.rate, 0, "Permission to resume does not override a prior deliberate pause")
        XCTAssertEqual(model.transport.intent, .paused)

        model.togglePlayback()
        await waitFor("The user explicitly plays again") { model.player.currentTime().seconds >= 1.4 }
        postInterruption(.began)
        await waitFor("Interruption suspends the playing movie") { model.player.rate == 0 }
        model.togglePlayback() // Cancel the prior playing intention while interrupted.
        postInterruption(.ended, options: .shouldResume)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.transport.intent, .paused)
        XCTAssertEqual(model.player.rate, 0, "A Pause during interruption must invalidate its resume candidate")
    }

    func testHeadphoneRemovalPausesAndNewRouteDoesNotRestartTheMovie() async throws {
        let (model, record, url) = try fixture()
        defer { model.stop() }
        model.play(.offline(record: record, url: url, start: .position(0)))
        await waitFor("Movie actually advances before unplug") { model.player.currentTime().seconds >= 0.4 }
        postRoute(.oldDeviceUnavailable)
        await waitFor("Headphone removal pauses output") { model.player.rate == 0 && model.transport.intent == .paused }
        let position = model.player.currentTime().seconds
        XCTAssertNotNil(model.systemPlaybackNotice)
        postRoute(.newDeviceAvailable)
        postInterruption(.ended, options: .shouldResume)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.player.currentTime().seconds, position, accuracy: 0.1)
        XCTAssertEqual(model.player.rate, 0, "A newly available speaker cannot surprise the user by resuming")
        model.togglePlayback()
        await waitFor("Explicit Play resumes the retained movie") { model.player.currentTime().seconds >= position + 0.4 }
    }

    func testMediaServicesResetRebuildsPausedAndOldItemCallbacksCannotEndReplacement() async throws {
        let (model, record, url) = try fixture()
        defer { model.stop() }
        model.play(.offline(record: record, url: url, start: .position(1)))
        await waitFor("Movie is actually advancing before media services reset") { model.player.currentTime().seconds >= 1.5 }
        let originalPlayer = model.player
        let originalItem = try XCTUnwrap(model.player.currentItem)
        let position = model.player.currentTime().seconds
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance())
        await waitFor("Audio objects are rebuilt and the real replacement is ready") {
            model.player !== originalPlayer && model.player.currentItem !== originalItem
                && model.player.currentItem?.status == .readyToPlay
        }
        XCTAssertEqual(model.player.rate, 0, "Apple requires explicit user action after media services reset")
        XCTAssertEqual(model.transport.intent, .paused)
        XCTAssertNotNil(model.systemPlaybackNotice)
        await waitFor("Rebuilt asset retains the movie's actual position") { model.player.currentTime().seconds >= position - 0.2 }
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: originalItem)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.hasEnded, "A replaced audio object's late end callback cannot own the new player")
        model.togglePlayback()
        await waitFor("Explicit Play advances rebuilt output") { model.player.currentTime().seconds >= position + 0.4 }
        XCTAssertNil(model.errorMessage)
    }

    func testNowPlayingPublishesActualElapsedRateAndDurationThroughPauseSeekSpeedAndClose() async throws {
        let (model, record, url) = try fixture()
        defer { model.stop() }
        model.play(.offline(record: record, url: url, start: .position(1)))
        await waitFor("Movie is moving before Now Playing is assessed") { model.player.currentTime().seconds >= 1.4 }
        XCTAssertEqual(model.player.timeControlStatus, .playing)
        XCTAssertEqual(model.player.rate, 1)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, record.displayTitle)
        XCTAssertEqual(try XCTUnwrap(nowPlayingDouble(MPMediaItemPropertyPlaybackDuration)), 6, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(nowPlayingDouble(MPNowPlayingInfoPropertyElapsedPlaybackTime)), 1)
        XCTAssertEqual(nowPlayingDouble(MPNowPlayingInfoPropertyPlaybackRate), 1,
                       "Completing the initial resume seek must publish actual output rate without waiting for another elapsed-time tick")
        model.setPlaybackSpeed(1.5)
        await waitFor("Now Playing reflects the actual chosen playback rate") { self.nowPlayingDouble(MPNowPlayingInfoPropertyPlaybackRate) == 1.5 && model.player.rate == 1.5 }
        model.togglePlayback()
        await waitFor("Pause publishes zero rate") { self.nowPlayingDouble(MPNowPlayingInfoPropertyPlaybackRate) == 0 }
        model.seek(toGlobalTime: 3)
        await waitFor("Paused seek reaches the real asset and lock-screen elapsed value") {
            abs(model.player.currentTime().seconds - 3) < 0.1
                && abs((self.nowPlayingDouble(MPNowPlayingInfoPropertyElapsedPlaybackTime) ?? -1) - 3) < 0.1
        }
        XCTAssertEqual(nowPlayingDouble(MPNowPlayingInfoPropertyPlaybackRate), 0)
        model.stop()
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertFalse(MPRemoteCommandCenter.shared().playCommand.isEnabled)
        XCTAssertFalse(MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled)
    }

    func testStoppedModelsCannotClearANewerOwnerOrReviveAfterLateInterruptionEnd() async throws {
        let (old, oldRecord, url) = try fixture(title: "The Brass Cloud")
        let (new, newRecord, _) = try fixture(title: "The Copper Rain")
        defer { old.stop(); new.stop() }
        old.play(.offline(record: oldRecord, url: url, start: .position(0)))
        await waitFor("Old viewing actually begins") { old.player.currentTime().seconds >= 0.4 }
        postInterruption(.began)
        old.stop()
        new.playLocal(record: newRecord, url: url, startAt: 1, preservingIntent: .paused)
        await waitFor("New paused viewing owns the audio presentation") { new.player.currentItem?.status == .readyToPlay }
        let newAsset = try XCTUnwrap(new.player.currentItem)
        old.stop()
        postInterruption(.ended, options: .shouldResume)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(old.player.currentItem)
        XCTAssertTrue(new.player.currentItem === newAsset)
        XCTAssertEqual(new.player.rate, 0)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, newRecord.displayTitle,
                       "Late cleanup from an older owner cannot clear the current movie's Now Playing state")
        XCTAssertTrue(MPRemoteCommandCenter.shared().playCommand.isEnabled)
    }

    private func fixture(title: String = "The Lantern Current") throws -> (PlaybackModel, DownloadRecord, URL) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-native-tracks", withExtension: "mp4"))
        Self.nextMediaID += 1
        let record = DownloadRecord(id: UUID(), serverOrigin: "https://audio.example.test", mediaID: String(Self.nextMediaID),
                                    title: title, kind: .original, fileName: url.lastPathComponent,
                                    byteCount: Int64(try Data(contentsOf: url).count), completedAt: Date(), durationSeconds: 6,
                                    resolution: "320x180", artworkPath: nil)
        return (PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral)), record, url)
    }
    private func postInterruption(_ type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions = []) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue, AVAudioSessionInterruptionOptionKey: options.rawValue])
    }
    private func postRoute(_ reason: AVAudioSession.RouteChangeReason) {
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
    }
    private func nowPlayingDouble(_ key: String) -> Double? { (MPNowPlayingInfoCenter.default().nowPlayingInfo?[key] as? NSNumber)?.doubleValue }
    private func waitFor(_ description: String, _ condition: @escaping () -> Bool) async {
        let done = expectation(description: description)
        let task = Task { for _ in 0..<400 { if condition() { done.fulfill(); return }; try? await Task.sleep(for: .milliseconds(10)) } }
        await fulfillment(of: [done], timeout: 5)
        task.cancel()
    }
}

@MainActor
private final class PendingSystemActivityStore: PlaybackActivityStore {
    var isRestoring = false
    var commitPending: Bool { commitContinuation != nil }
    var restorePending: Bool { restoreContinuation != nil }
    private var commitContinuation: CheckedContinuation<Void, Error>?
    private var restoreContinuation: CheckedContinuation<Void, Never>?
    func resumePosition(for key: MovieLibraryKey) -> Double? { 2 }
    func record(_ activity: PlaybackActivity) {}
    func flush() async throws {}
    func commit(_ activity: PlaybackActivity) async throws {
        try await withCheckedThrowingContinuation { commitContinuation = $0 }
    }
    func waitUntilRestored() async {
        guard isRestoring else { return }
        await withCheckedContinuation { restoreContinuation = $0 }
    }
    func releaseCommit() { let pending = commitContinuation; commitContinuation = nil; pending?.resume() }
    func releaseRestore() { isRestoring = false; let pending = restoreContinuation; restoreContinuation = nil; pending?.resume() }
}
