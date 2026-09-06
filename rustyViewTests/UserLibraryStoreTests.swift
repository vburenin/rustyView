import Foundation
import XCTest
@testable import rustyView

@MainActor
final class UserLibraryStoreTests: XCTestCase {
    func testShortMovieResumeSurvivesReopenAndUsesSamePolicyAsLegacyPlayer() async throws {
        let context = try LibraryTestContext()
        defer { context.remove() }
        let key = movieKey()
        let movie = syntheticMovie(duration: 20)
        let store = context.store()
        await store.waitUntilRestored()
        let view = UUID()
        store.record(activity(view, key: key, movie: movie, event: .started(position: 0.3, duration: 20)))
        XCTAssertNil(store.resumePosition(for: key))
        store.record(activity(view, key: key, movie: movie, event: .progress(position: 7, duration: 20)))
        try await store.flush()
        let reopened = context.store()
        await reopened.waitUntilRestored()
        XCTAssertEqual(reopened.resumePosition(for: key), 7)
        context.legacy.update(serverOrigin: key.serverIdentity, mediaID: key.mediaID,
                              position: 7, duration: 20, accountUsername: key.accountUsername)
        let adapter = LegacyPlaybackActivityAdapter(progressStore: context.legacy)
        XCTAssertEqual(adapter.resumePosition(for: key), reopened.resumePosition(for: key))
        store.record(activity(view, key: key, movie: movie, event: .progress(position: 19.4, duration: 20)))
        XCTAssertNil(store.resumePosition(for: key))
        XCTAssertNil(store.history.first?.completedAt, "Near-end trimming must not invent watched history.")
        try await store.flush()
    }

    func testLegacyMigrationPreservesUnknownAccountAndOriginalDefaultsWithoutReimportingStartOver() async throws {
        let context = try LibraryTestContext()
        defer { context.remove() }
        let legacy = PlaybackProgress(serverOrigin: "HTTPS://MEDIA.example.test:443/library/", mediaID: "42",
            position: 40, duration: 120, updatedAt: Date(timeIntervalSince1970: 100), accountUsername: nil)
        let bytes = try JSONEncoder().encode([legacy])
        context.defaults.set(bytes, forKey: "playbackProgress.v1")
        let store = context.store()
        await store.waitUntilRestored()
        let unknown = movieKey(account: nil)
        XCTAssertEqual(store.resumePosition(for: unknown), 40)
        XCTAssertNil(store.entry(for: movieKey(account: "viewer")))
        XCTAssertNil(store.entry(for: unknown)?.movie)
        XCTAssertEqual(context.defaults.data(forKey: "playbackProgress.v1"), bytes)
        let movie = syntheticMovie()
        store.upsertMetadata(movie, for: movieKey(account: "viewer"))
        XCTAssertNil(store.entry(for: unknown)?.movie)
        store.upsertMetadata(movie, for: unknown)
        XCTAssertEqual(store.entry(for: unknown)?.movie, movie)
        try await store.commit(activity(UUID(), key: unknown, movie: movie, event: .startedOver))
        let reopened = context.store()
        await reopened.waitUntilRestored()
        XCTAssertNil(reopened.resumePosition(for: unknown))
        XCTAssertEqual(reopened.entry(for: unknown)?.movie, movie)
        XCTAssertEqual(context.defaults.data(forKey: "playbackProgress.v1"), bytes)
        XCTAssertTrue(reopened.history.isEmpty, "Start Over is an intent, not evidence of watching.")
    }

    func testActualViewingAndFavoritesSurviveSourceDeletionAndStayWithinExactIdentity() async throws {
        let context = try LibraryTestContext()
        defer { context.remove() }
        let store = context.store()
        let key = movieKey(account: "first-viewer")
        let other = movieKey(account: "second-viewer")
        let movie = syntheticMovie()
        let offlineID = UUID()
        store.setFavorite(true, movie: movie, for: key)
        store.record(activity(UUID(), key: key, movie: movie, source: .offline(recordID: offlineID),
                              event: .started(position: 30, duration: 120)))
        store.setFavorite(true, movie: syntheticMovie(title: "The Paper Comet"), for: other)
        try await store.flush()
        let reopened = context.store()
        await reopened.waitUntilRestored()
        XCTAssertTrue(reopened.isFavorite(for: key))
        XCTAssertEqual(reopened.resumePosition(for: key), 30)
        XCTAssertNil(reopened.resumePosition(for: other))
        XCTAssertEqual(reopened.entry(for: other)?.movie?.title, "The Paper Comet")
        XCTAssertEqual(reopened.history.first?.source, .offline(recordID: offlineID))
        XCTAssertEqual(reopened.history.first?.movie, movie)
        XCTAssertNil(reopened.entry(for: movieKey(account: nil)))
        let differentLibrary = MovieLibraryKey(serverIdentity: "https://media.example.test/another-library", accountUsername: "first-viewer", mediaID: "42")
        XCTAssertNil(reopened.entry(for: differentLibrary))
    }

    func testStartOverIsDurableBeforeReturningAndOldViewingCannotResurrectProgress() async throws {
        let context = try LibraryTestContext()
        defer { context.remove() }
        let store = context.store()
        let key = movieKey(), movie = syntheticMovie()
        let old = UUID(), new = UUID()
        store.record(activity(old, key: key, movie: movie, event: .started(position: 45, duration: 120)))
        try await store.flush()
        try await store.commit(activity(new, key: key, movie: movie, event: .startedOver))
        store.record(activity(old, key: key, movie: movie, event: .progress(position: 80, duration: 120)))
        store.record(activity(old, key: key, movie: movie, event: .started(position: 80, duration: 120)))
        store.record(activity(old, key: key, movie: movie, event: .completed(position: 120, duration: 120)))
        XCTAssertNil(store.resumePosition(for: key))
        XCTAssertNil(store.entry(for: key)?.lastCompletedAt)
        XCTAssertEqual(store.history.count, 1)
        let reopened = context.store()
        await reopened.waitUntilRestored()
        XCTAssertNil(reopened.resumePosition(for: key))
        XCTAssertEqual(reopened.history.count, 1)
        store.record(activity(new, key: key, movie: movie, event: .started(position: 0.5, duration: 120)))
        store.record(activity(new, key: key, movie: movie, event: .progress(position: 25, duration: 120)))
        XCTAssertEqual(store.resumePosition(for: key), 25)
        XCTAssertEqual(store.history.count, 2)
        try await store.flush()
    }

    func testFailedStartOverRollsBackOnlyItsIntentWhileKeepingConcurrentFavorite() async throws {
        let context = try LibraryTestContext()
        defer { context.remove() }
        let files = LibraryWriteBarrier()
        let store = context.store(fileManager: files)
        let key = movieKey(), movie = syntheticMovie()
        let old = UUID()
        store.record(activity(old, key: key, movie: movie, event: .started(position: 45, duration: 120)))
        try await store.flush()
        let committedBytes = try Data(contentsOf: context.indexURL)

        files.arm(fail: true)
        let commit = Task { try await store.commit(activity(UUID(), key: key, movie: movie, event: .startedOver)) }
        let reached = await files.waitUntilBlocked()
        XCTAssertTrue(reached)
        XCTAssertNil(store.resumePosition(for: key), "The tentative owner must reject the old player while saving.")
        store.setFavorite(true, movie: movie, for: key)
        XCTAssertTrue(store.isFavorite(for: key), "The main actor must remain responsive during file I/O.")
        XCTAssertEqual(try Data(contentsOf: context.indexURL), committedBytes)
        files.release()
        switch await commit.result {
        case .success: XCTFail("The real write failure must fail the required transition.")
        case .failure: break
        }
        XCTAssertEqual(store.resumePosition(for: key), 45)
        XCTAssertTrue(store.isFavorite(for: key))
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(try Data(contentsOf: context.indexURL), committedBytes)
        try await store.flush()
        let reopened = context.store()
        await reopened.waitUntilRestored()
        XCTAssertEqual(reopened.resumePosition(for: key), 45)
        XCTAssertTrue(reopened.isFavorite(for: key))
        XCTAssertNil(store.persistenceError)
    }

    func testPendingStartOverRejectsOldProgressButPreservesLaterNewViewingOnFailure() async throws {
        let context = try LibraryTestContext()
        defer { context.remove() }
        let files = LibraryWriteBarrier()
        let store = context.store(fileManager: files)
        let key = movieKey(), movie = syntheticMovie()
        let old = UUID(), newer = UUID()
        store.record(activity(old, key: key, movie: movie, event: .started(position: 45, duration: 120)))
        try await store.flush()
        files.arm(fail: true)
        let commit = Task { try await store.commit(activity(UUID(), key: key, movie: movie, event: .startedOver)) }
        let reached = await files.waitUntilBlocked()
        XCTAssertTrue(reached)
        store.record(activity(old, key: key, movie: movie, event: .progress(position: 70, duration: 120)))
        XCTAssertNil(store.resumePosition(for: key))
        store.record(activity(newer, key: key, movie: movie, event: .started(position: 20, duration: 120)))
        files.release()
        _ = await commit.result
        XCTAssertEqual(store.resumePosition(for: key), 20, "A newer viewing owns progress after rollback.")
        try await store.flush()
        let reopened = context.store()
        await reopened.waitUntilRestored()
        XCTAssertEqual(reopened.resumePosition(for: key), 20)
        XCTAssertEqual(reopened.history.count, 2)
    }

    func testCorruptExistingIndexIsPreservedAndNeverReplacedByLegacyImportOrNewFavorite() async throws {
        let context = try LibraryTestContext()
        defer { context.remove() }
        let bytes = Data("{synthetic interrupted index".utf8)
        try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true)
        try bytes.write(to: context.indexURL)
        context.legacy.update(serverOrigin: movieKey().serverIdentity, mediaID: "42", position: 40, duration: 120, accountUsername: "viewer")
        let store = context.store()
        await store.waitUntilRestored()
        XCTAssertNotNil(store.persistenceError)
        XCTAssertTrue(store.entries.isEmpty)
        store.setFavorite(true, movie: syntheticMovie(), for: movieKey())
        do { try await store.flush(); XCTFail("An unreadable index must not be overwritten.") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: context.indexURL), bytes)
        XCTAssertTrue(store.isFavorite(for: movieKey()), "The unsaved action remains visible alongside its error.")
        XCTAssertNil(store.resumePosition(for: movieKey()))
    }

    func testHiddenContinueWatchingSurvivesSameViewingProgressAndNewViewingRestoresIt() async throws {
        let context = try LibraryTestContext()
        defer { context.remove() }
        let store = context.store()
        let key = movieKey(), movie = syntheticMovie(), view = UUID()
        store.record(activity(view, key: key, movie: movie, event: .started(position: 30, duration: 120)))
        store.removeFromContinueWatching(for: key)
        store.record(activity(view, key: key, movie: movie, event: .progress(position: 40, duration: 120)))
        XCTAssertTrue(store.entry(for: key)?.hiddenFromContinueWatching == true)
        XCTAssertEqual(store.resumePosition(for: key), 40)
        try await store.flush()
        let reopened = context.store()
        await reopened.waitUntilRestored()
        XCTAssertTrue(reopened.entry(for: key)?.hiddenFromContinueWatching == true)
        reopened.record(activity(UUID(), key: key, movie: movie, event: .started(position: 40, duration: 120)))
        XCTAssertFalse(reopened.entry(for: key)?.hiddenFromContinueWatching == true)
        try await reopened.flush()
    }

    func testRepeatedDetailsAndUnchangedFavoriteDoNotRewriteUserData() async throws {
        let context = try LibraryTestContext()
        defer { context.remove() }
        let store = context.store()
        await store.waitUntilRestored()
        let emptyIndex = try Data(contentsOf: context.indexURL)
        store.upsertMetadata(syntheticMovie(), for: movieKey())
        try await store.flush()
        XCTAssertEqual(try Data(contentsOf: context.indexURL), emptyIndex)
        XCTAssertTrue(store.entries.isEmpty, "Browse metadata belongs in its bounded cache until there is user state.")
        store.setFavorite(true, movie: syntheticMovie(), for: movieKey())
        try await store.flush()
        let saved = try Data(contentsOf: context.indexURL)
        for _ in 0..<20 {
            store.upsertMetadata(syntheticMovie(), for: movieKey())
            store.setFavorite(true, movie: syntheticMovie(), for: movieKey())
        }
        try await store.flush()
        XCTAssertEqual(try Data(contentsOf: context.indexURL), saved)
    }

    func testReadRetryLoadsRecoveredIndexAndKeepsActionAcceptedWhileUnreadable() async throws {
        let context = try LibraryTestContext()
        defer { context.remove() }
        let first = context.store()
        let key = movieKey(), movie = syntheticMovie()
        first.record(activity(UUID(), key: key, movie: movie, event: .started(position: 35, duration: 120)))
        try await first.flush()
        let intact = try Data(contentsOf: context.indexURL)
        try Data("{damaged synthetic index".utf8).write(to: context.indexURL)
        let reopened = context.store()
        await reopened.waitUntilRestored()
        XCTAssertNotNil(reopened.persistenceError)
        reopened.setFavorite(true, movie: movie, for: key)
        do { try await reopened.flush(); XCTFail("Unreadable saved data must block writes.") } catch { }
        try intact.write(to: context.indexURL, options: .atomic)
        try await reopened.flush()
        XCTAssertNil(reopened.persistenceError)
        XCTAssertEqual(reopened.resumePosition(for: key), 35)
        XCTAssertTrue(reopened.isFavorite(for: key))
        let final = context.store()
        await final.waitUntilRestored()
        XCTAssertEqual(final.resumePosition(for: key), 35)
        XCTAssertTrue(final.isFavorite(for: key))
    }

    func testCorruptLegacyProgressDoesNotCreateEmptyIndexAndCanBeRetriedAfterRecovery() async throws {
        let context = try LibraryTestContext()
        defer { context.remove() }
        let damaged = Data("{damaged synthetic old progress".utf8)
        context.defaults.set(damaged, forKey: "playbackProgress.v1")
        let store = context.store()
        await store.waitUntilRestored()
        XCTAssertNotNil(store.persistenceError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.indexURL.path))
        XCTAssertEqual(context.defaults.data(forKey: "playbackProgress.v1"), damaged)
        let recovered = PlaybackProgress(serverOrigin: movieKey().serverIdentity, mediaID: "42", position: 32,
            duration: 120, updatedAt: Date(), accountUsername: "viewer")
        context.defaults.set(try JSONEncoder().encode([recovered]), forKey: "playbackProgress.v1")
        try await store.flush()
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(store.resumePosition(for: movieKey()), 32)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.indexURL.path))
    }

    func testCompletionKeepsHistoryAndLateCallbacksCannotCreateResumeAgain() async throws {
        let context = try LibraryTestContext()
        defer { context.remove() }
        let store = context.store()
        let key = movieKey(), movie = syntheticMovie(), view = UUID()
        store.record(activity(view, key: key, movie: movie, event: .started(position: 30, duration: 120)))
        store.record(activity(view, key: key, movie: movie, event: .completed(position: 120, duration: 120)))
        store.record(activity(view, key: key, movie: movie, event: .progress(position: 40, duration: 120)))
        store.record(activity(view, key: key, movie: movie, event: .started(position: 40, duration: 120)))
        try await store.flush()
        let reopened = context.store()
        await reopened.waitUntilRestored()
        XCTAssertNil(reopened.resumePosition(for: key))
        XCTAssertEqual(reopened.history.count, 1)
        XCTAssertNotNil(reopened.history.first?.completedAt)
        XCTAssertNotNil(reopened.entry(for: key)?.lastCompletedAt)
    }

    func testActualStartAndEndAreRecordedEvenWhenSourceRuntimeIsStillUnknown() async throws {
        let context = try LibraryTestContext()
        defer { context.remove() }
        let key = movieKey(), movie = syntheticMovie(), view = UUID()
        context.legacy.update(serverOrigin: key.serverIdentity, mediaID: key.mediaID,
                              position: 40, duration: 120, accountUsername: key.accountUsername)
        let store = context.store()
        await store.waitUntilRestored()
        store.record(activity(view, key: key, movie: movie, event: .started(position: 40.5, duration: 0)))
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.resumePosition(for: key), 40, "Unknown runtime must not erase an existing usable resume point.")
        store.record(activity(view, key: key, movie: movie, event: .completed(position: 100, duration: 0)))
        try await store.flush()
        let reopened = context.store()
        await reopened.waitUntilRestored()
        XCTAssertNil(reopened.resumePosition(for: key))
        XCTAssertEqual(reopened.history.first?.lastPosition, 100)
        XCTAssertNotNil(reopened.history.first?.completedAt)
    }

    func testRestoreReplaysNewActionsAndBoundsHistoryWithoutRemovingFavorites() async throws {
        let context = try LibraryTestContext()
        defer { context.remove() }
        let first = context.store()
        first.setFavorite(true, movie: syntheticMovie(), for: movieKey())
        try await first.flush()
        let reopened = context.store(maximumHistory: 2, maximumEntries: 2)
        reopened.setFavorite(false, movie: syntheticMovie(), for: movieKey())
        for index in 0..<4 {
            let key = MovieLibraryKey(serverIdentity: "https://media.example.test/library", accountUsername: "viewer", mediaID: String(100 + index))
            let movie = MovieMetadata(mediaID: key.mediaID, title: "Synthetic Lantern \(index)", durationSeconds: 120)
            reopened.setFavorite(true, movie: movie, for: key)
            reopened.record(activity(UUID(), key: key, movie: movie, event: .started(position: 30, duration: 120)))
        }
        try await reopened.flush()
        XCTAssertFalse(reopened.isFavorite(for: movieKey()))
        XCTAssertEqual(reopened.entries.values.filter(\.isFavorite).count, 4)
        XCTAssertEqual(reopened.history.count, 2)
        let final = context.store(maximumHistory: 2, maximumEntries: 2)
        await final.waitUntilRestored()
        XCTAssertEqual(final.entries.values.filter(\.isFavorite).count, 4)
        XCTAssertEqual(final.history.count, 2)
    }

    private func movieKey(account: String? = "viewer") -> MovieLibraryKey {
        MovieLibraryKey(serverIdentity: "https://media.example.test/library", accountUsername: account, mediaID: "42")
    }
    private func syntheticMovie(title: String = "The Tin Observatory", duration: Double = 120) -> MovieMetadata {
        MovieMetadata(mediaID: "42", title: title, durationSeconds: duration)
    }
    private func activity(_ view: UUID, key: MovieLibraryKey, movie: MovieMetadata,
                          source: PlaybackActivity.Source = .online, event: PlaybackActivity.Event) -> PlaybackActivity {
        PlaybackActivity(viewingID: view, key: key, movie: movie, source: source, event: event)
    }
}

@MainActor
private struct LibraryTestContext {
    let directory: URL
    let defaults: UserDefaults
    let legacy: PlaybackProgressStore
    private let suite: String
    var indexURL: URL { directory.appendingPathComponent("library.json") }

    init() throws {
        suite = "user-library-\(UUID().uuidString)"
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        legacy = PlaybackProgressStore(defaults: defaults)
    }
    func store(fileManager: FileManager = .default, maximumHistory: Int = 500, maximumEntries: Int = 500) -> UserLibraryStore {
        UserLibraryStore(directory: directory, legacyProgressStore: legacy, fileManager: fileManager,
                         maximumHistory: maximumHistory, maximumEntries: maximumEntries)
    }
    func remove() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class LibraryWriteBarrier: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var fail = false
    private let entered = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)

    func arm(fail: Bool) {
        lock.lock()
        armed = true
        self.fail = fail
        lock.unlock()
    }
    func waitUntilBlocked() async -> Bool {
        await Task.detached { self.entered.wait(timeout: .now() + 5) == .success }.value
    }
    func release() { proceed.signal() }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        lock.lock()
        let block = armed, fail = self.fail
        armed = false
        lock.unlock()
        if block {
            entered.signal()
            guard proceed.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileWriteUnknown) }
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
