import AVFoundation
import XCTest
@testable import rustyView

@MainActor
final class PlaybackActivityIntegrationTests: XCTestCase {
    func testFirstOldAssetAdvancementCannotClaimAStartOverThatIsStillCommitting() async throws {
        let (record, url) = try fixture()
        let store = HeldPlaybackActivityStore()
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral), activityStore: store)
        defer { model.stop() }
        model.playLocal(record: record, url: url, preservingIntent: .paused)
        await waitFor("The old asset is ready without having begun a viewing") { model.player.currentItem?.status == .readyToPlay }
        let oldAsset = try XCTUnwrap(model.player.currentItem)
        model.play(.offline(record: record, url: url, start: .startOver))
        await waitFor("Start Over owns a pending durable commit") { store.pendingCommit != nil }
        model.togglePlayback()
        await waitFor("The retained old asset actually advances while disk is held") { model.player.currentTime().seconds >= 0.8 }
        XCTAssertTrue(model.player.currentItem === oldAsset)
        XCTAssertTrue(store.events.isEmpty,
                      "An unseen old viewing ID must not claim ownership over a pending Start Over")
        store.finishCommit(error: CocoaError(.fileWriteOutOfSpace))
        await waitFor("After failure the still-playing old asset can record its first actual viewing") { store.starts.count == 1 }
        XCTAssertTrue(model.player.currentItem === oldAsset)
        let oldID = try XCTUnwrap(store.starts.first?.viewingID)
        model.play(.offline(record: record, url: url, start: .startOver))
        await waitFor("Another Start Over reaches storage") { store.pendingCommit != nil }
        let newID = try XCTUnwrap(store.pendingCommit?.viewingID)
        store.finishCommit()
        await waitFor("Successful commit starts the new viewing from the beginning") { store.starts.count == 2 }
        XCTAssertNotEqual(newID, oldID)
        XCTAssertEqual(store.starts.last?.viewingID, newID)
        XCTAssertLessThan(model.currentTime, 1.5)
    }

    func testResumeWaitsForRestoredPositionBeforeCreatingAssetOrHistory() async throws {
        let (record, url) = try fixture()
        let store = HeldPlaybackActivityStore()
        store.isRestoring = true
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral), activityStore: store)
        defer { model.stop() }
        model.play(.offline(record: record, url: url))
        await waitFor("Resume reaches the storage restoration boundary") { store.waitingForRestore }
        XCTAssertTrue(model.isLoadingSavedPosition)
        XCTAssertNil(model.player.currentItem, "Starting at zero before restoration would overwrite the saved position")
        XCTAssertTrue(store.events.isEmpty)
        store.finishRestore(position: 2)
        await waitFor("Playback uses and advances the restored position") { store.starts.count == 1 && model.currentTime >= 2.5 }
        if case .started(let position, _) = try XCTUnwrap(store.starts.first).event {
            XCTAssertGreaterThanOrEqual(position, 2)
        }
        XCTAssertFalse(model.isLoadingSavedPosition)
    }

    func testFailedPlaybackDoesNotCreateViewingHistory() async throws {
        let (record, _) = try fixture()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).mp4")
        let store = HeldPlaybackActivityStore()
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral), activityStore: store)
        defer { model.stop() }
        model.play(.offline(record: record, url: missing))
        await waitFor("Missing media reaches an actionable player error") { model.errorMessage != nil }
        XCTAssertTrue(store.events.isEmpty, "A Watch tap without decoded advancement must not appear as a viewing")
    }

    func testStartOverWaitsForDurableCommitAndFailurePreservesActualPausedAsset() async throws {
        let (record, url) = try fixture()
        let store = HeldPlaybackActivityStore()
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral), activityStore: store)
        defer { model.stop() }
        model.play(.offline(record: record, url: url))
        await waitFor("First history event follows real media advancement") { store.starts.count == 1 && model.currentTime >= 0.75 }
        model.togglePlayback()
        let asset = try XCTUnwrap(model.player.currentItem)
        let position = model.player.currentTime().seconds
        let firstID = try XCTUnwrap(store.starts.first?.viewingID)

        model.play(.offline(record: record, url: url, start: .startOver))
        await waitFor("Durable Start Over is held at the storage boundary") { store.pendingCommit != nil }
        XCTAssertTrue(model.isSavingStartOver)
        XCTAssertTrue(model.player.currentItem === asset)
        XCTAssertEqual(model.player.currentTime().seconds, position, accuracy: 0.1)
        XCTAssertEqual(store.starts.count, 1, "A tap and a pending write must not create viewing history")
        store.finishCommit(error: CocoaError(.fileWriteOutOfSpace))
        await waitFor("Failed commit has a useful recovery state") { model.requestError != nil && !model.isSavingStartOver }
        XCTAssertTrue(model.player.currentItem === asset, "Failed Start Over must leave the playable asset intact")
        XCTAssertEqual(model.player.currentTime().seconds, position, accuracy: 0.1)
        XCTAssertEqual(model.transport.intent, .paused)

        model.play(.offline(record: record, url: url, start: .startOver))
        await waitFor("Second Start Over reaches storage") { store.pendingCommit != nil }
        store.finishCommit()
        await waitFor("Successful commit starts a distinct real viewing") { store.starts.count == 2 }
        XCTAssertFalse(model.player.currentItem === asset)
        XCTAssertNotEqual(store.starts.last?.viewingID, firstID)
        XCTAssertEqual(store.committed.count, 1)
        XCTAssertLessThan(model.currentTime, position + 0.5)
    }

    func testCancelledPendingStartCannotReplaceNewerPlayback() async throws {
        let (record, url) = try fixture()
        let store = HeldPlaybackActivityStore()
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral), activityStore: store)
        defer { model.stop() }
        model.play(.offline(record: record, url: url, start: .startOver))
        await waitFor("Start Over is waiting for disk") { store.pendingCommit != nil }
        model.play(.offline(record: record, url: url, start: .position(2)))
        let newerItem = try XCTUnwrap(model.player.currentItem)
        store.finishCommit()
        await waitFor("Newer request advances from its chosen chapter") { model.currentTime >= 2.5 }
        XCTAssertTrue(model.player.currentItem === newerItem, "A late storage completion cannot replace a newer request")
        XCTAssertFalse(model.isSavingStartOver)
        XCTAssertEqual(store.starts.count, 1)
    }

    func testPauseSeekAndRetryDoNotCreateHistoryButActualReplayDoes() async throws {
        let (record, url) = try fixture()
        let store = HeldPlaybackActivityStore()
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral), activityStore: store)
        defer { model.stop() }
        model.playLocal(record: record, url: url, startAt: 1, preservingIntent: .paused)
        await waitFor("Paused initial seek is actually applied") { model.player.currentItem?.status == .readyToPlay && model.player.currentTime().seconds >= 0.95 }
        model.seek(toGlobalTime: 2)
        await waitFor("User seek completes without playback") { model.player.currentTime().seconds >= 1.95 }
        XCTAssertTrue(store.starts.isEmpty, "Ready status and seek jumps are not a viewing")
        model.togglePlayback()
        await waitFor("Actual playback creates history") { store.starts.count == 1 }
        let firstID = try XCTUnwrap(store.starts.first?.viewingID)
        model.retryCurrentPlayback()
        await waitFor("Retry advances the replacement asset") { model.player.currentTime().seconds >= 3 }
        XCTAssertEqual(store.starts.count, 1, "Retry belongs to the same viewing")
        model.seek(toGlobalTime: 5.5)
        await waitFor("Actual AV end records completion") { model.hasEnded && store.completions.count == 1 }
        XCTAssertEqual(store.completions.first?.viewingID, firstID)
        model.togglePlayback()
        await waitFor("Replay creates a new history viewing after advancement") { store.starts.count == 2 }
        XCTAssertNotEqual(store.starts.last?.viewingID, firstID)
        XCTAssertLessThan(model.currentTime, 2)
    }

    private func fixture() throws -> (DownloadRecord, URL) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-native-tracks", withExtension: "mp4"))
        return (DownloadRecord(id: UUID(), serverOrigin: "https://history.example.test", mediaID: "73001",
            title: "The Glass Compass", kind: .original, fileName: url.lastPathComponent,
            byteCount: Int64(try Data(contentsOf: url).count), completedAt: Date(), durationSeconds: 6,
            resolution: "320x180", artworkPath: nil), url)
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

/// Keeps the real asynchronous commit boundary controllable while AVPlayer
/// reads a real local asset. Central-store tests cover the atomic disk write.
@MainActor
private final class HeldPlaybackActivityStore: PlaybackActivityStore {
    var events: [PlaybackActivity] = []
    var committed: [PlaybackActivity] = []
    var pendingCommit: PlaybackActivity?
    private var continuation: CheckedContinuation<Void, Error>?
    var isRestoring = false
    var waitingForRestore = false
    private var restoredPosition: Double?
    private var restoration: CheckedContinuation<Void, Never>?
    var starts: [PlaybackActivity] { events.filter { if case .started = $0.event { return true }; return false } }
    var completions: [PlaybackActivity] { events.filter { if case .completed = $0.event { return true }; return false } }
    func resumePosition(for key: MovieLibraryKey) -> Double? { restoredPosition }
    func waitUntilRestored() async {
        guard isRestoring else { return }
        waitingForRestore = true
        await withCheckedContinuation { restoration = $0 }
    }
    func finishRestore(position: Double) {
        restoredPosition = position
        isRestoring = false
        restoration?.resume()
        restoration = nil
    }
    func record(_ activity: PlaybackActivity) { events.append(activity) }
    func flush() async throws { }
    func commit(_ activity: PlaybackActivity) async throws {
        pendingCommit = activity
        try await withCheckedThrowingContinuation { continuation = $0 }
        committed.append(activity)
    }
    func finishCommit(error: Error? = nil) {
        let pending = continuation
        continuation = nil
        pendingCommit = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
