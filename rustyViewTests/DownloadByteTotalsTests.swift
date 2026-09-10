import Foundation
import Network
import Combine
import SwiftUI
import XCTest
@testable import rustyView

@MainActor
final class DownloadByteTotalsTests: XCTestCase {
    func testRenderedDownloadProgressProfile() async throws {
        let fixture = try ByteTotalsFixture(paddingBytes: 24 * 1_024 * 1_024)
        addTeardownBlock { await fixture.cleanUp() }
        let namespace = "energy-rendering-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace) }
        let app = AppModel(settings: AppSettings(defaults: defaults, secrets: KeychainStore(service: namespace)),
            downloads: fixture.manager,
            movieCache: MovieMetadataCache(directory: fixture.root.appendingPathComponent("metadata")),
            userLibrary: UserLibraryStore(directory: fixture.root.appendingPathComponent("library"),
                                         legacyProgressStore: PlaybackProgressStore(defaults: defaults)),
            playbackPreferences: PlaybackPreferences(defaults: defaults))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { DownloadsView().environmentObject(app) })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await fixture.start()
        try await eventually("The rendered download has received its first media prefix") {
            guard case .downloading(_, let received, _) = fixture.manager.active.first?.phase else { return false }
            return received >= Int64(fixture.payload.count / 3)
        }
        try await Task.sleep(for: .milliseconds(500))
        // A profiling-only hold lets Instruments attach to this isolated test
        // host before the measured burst. Normal regression runs never wait.
        if ProcessInfo.processInfo.environment["RUSTYVIEW_ENERGY_TRACE_HOLD"] == "1" {
            try await Task.sleep(for: .seconds(12))
        }
        var publications = 0
        let observation = app.objectWillChange.sink { _ in publications += 1 }
        defer { observation.cancel() }
        var before = rusage()
        getrusage(RUSAGE_SELF, &before)
        fixture.http.sendProgressBurst()
        try await Task.sleep(for: .seconds(2.5))
        var after = rusage()
        getrusage(RUSAGE_SELF, &after)
        let cpu = Double(after.ru_utime.tv_sec + after.ru_stime.tv_sec - before.ru_utime.tv_sec - before.ru_stime.tv_sec)
            + Double(after.ru_utime.tv_usec + after.ru_stime.tv_usec - before.ru_utime.tv_usec - before.ru_stime.tv_usec) / 1_000_000
        print("DOWNLOAD_ENERGY_PROFILE rendered_burst publications=\(publications) process_cpu_seconds=\(cpu)")
        XCTAssertNotNil(window.rootViewController?.view.window)
        guard case .downloading(_, let received, _) = fixture.manager.active.first?.phase else { return XCTFail("Missing rendered transfer") }
        XCTAssertGreaterThan(received, Int64(fixture.payload.count * 3 / 5))
    }

    func testCompletedPreparationStopsStatusRequestsWhileBytesAreStillDownloading() async throws {
        let fixture = try ByteTotalsFixture()
        addTeardownBlock { await fixture.cleanUp() }
        fixture.http.setReady()
        try await fixture.start()
        try await eventually("The finalized output size is learned") {
            guard case .downloading(_, _, let expected) = fixture.manager.active.first?.phase else { return false }
            return expected == Int64(fixture.payload.count)
        }
        let requests = fixture.http.requests(method: "GET").filter { $0.target.hasPrefix("/api/web/transcode/") }.count
        try await Task.sleep(for: .seconds(7))
        XCTAssertEqual(fixture.http.requests(method: "GET").filter { $0.target.hasPrefix("/api/web/transcode/") }.count,
                       requests, "Preparation is terminal; continued transfer must not repeatedly poll it")
        XCTAssertEqual(fixture.http.requests(method: "HEAD").count, 1)
        XCTAssertFalse(fixture.manager.active.isEmpty)
    }

    func testNativeProgressBurstHasBoundedUIWorkAndKeepsAdvancing() async throws {
        let fixture = try ByteTotalsFixture(paddingBytes: 24 * 1_024 * 1_024)
        addTeardownBlock { await fixture.cleanUp() }
        try await fixture.start()
        try await eventually("The first real media prefix has reached URLSession") {
            guard case .downloading(_, let received, _) = fixture.manager.active.first?.phase else { return false }
            return received >= Int64(fixture.payload.count / 3)
        }
        var publications = 0
        let observation = fixture.manager.$active.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        var before = rusage()
        getrusage(RUSAGE_SELF, &before)
        fixture.http.sendProgressBurst()
        try await Task.sleep(for: .seconds(2.5))
        var after = rusage()
        getrusage(RUSAGE_SELF, &after)
        let cpu = Double(after.ru_utime.tv_sec + after.ru_stime.tv_sec - before.ru_utime.tv_sec - before.ru_stime.tv_sec)
            + Double(after.ru_utime.tv_usec + after.ru_stime.tv_usec - before.ru_utime.tv_usec - before.ru_stime.tv_usec) / 1_000_000
        print("DOWNLOAD_ENERGY_PROFILE native_burst publications=\(publications) process_cpu_seconds=\(cpu)")
        XCTAssertGreaterThan(publications, 0)
        XCTAssertLessThanOrEqual(publications, 12, "Progress should update at most four times a second, including a final trailing update")
        guard case .downloading(_, let received, _) = fixture.manager.active.first?.phase else {
            return XCTFail("The held transfer must remain active")
        }
        // URLSession may retain a partial native write buffer while the tail
        // is held. Assert substantial real advancement, not server-sent bytes.
        XCTAssertGreaterThan(received, Int64(fixture.payload.count * 3 / 5))
    }

    func testBackgroundDownloadKeepsTransferButSuspendsOptionalProgressWork() async throws {
        let fixture = try ByteTotalsFixture(paddingBytes: 24 * 1_024 * 1_024)
        addTeardownBlock { await fixture.cleanUp() }
        try await fixture.start()
        try await eventually("Both native bytes and preparation status are available") {
            guard case .downloading(_, let received, _) = fixture.manager.active.first?.phase else { return false }
            return received >= Int64(fixture.payload.count / 3) && !fixture.manager.preparationProgress.isEmpty
        }
        fixture.manager.setApplicationInForeground(false)
        let statusRequests = fixture.http.requests(method: "GET").filter { $0.target.hasPrefix("/api/web/transcode/") }.count
        var publications = 0
        let observation = fixture.manager.$active.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        fixture.http.sendProgressBurst()
        try await Task.sleep(for: .seconds(3.5))
        XCTAssertEqual(publications, 0, "Background file delivery must not schedule invisible UI progress")
        XCTAssertEqual(fixture.http.requests(method: "GET").filter { $0.target.hasPrefix("/api/web/transcode/") }.count, statusRequests)
        fixture.http.setReady()
        fixture.manager.setApplicationInForeground(true)
        try await eventually("Foreground restores current bytes and discovers the completed size") {
            guard case .downloading(_, let received, let expected) = fixture.manager.active.first?.phase else { return false }
            return received > Int64(fixture.payload.count * 3 / 5) && expected == Int64(fixture.payload.count)
        }
        XCTAssertEqual(fixture.http.requests(method: "GET").filter { $0.target.hasPrefix("/web/media/") }.count, 1,
                       "The existing transfer must keep receiving bytes through the lifecycle change")
    }

    func testTwoRenditionsOfOneMovieKeepTheirPreparationStatusSeparate() async throws {
        let fixture = try ByteTotalsFixture(requestScopedStatus: true)
        addTeardownBlock { await fixture.cleanUp() }
        try await fixture.start()
        try await fixture.startSecondRendition()
        try await eventually("Both real media requests receive bytes") {
            fixture.manager.active.count == 2 && fixture.manager.active.allSatisfy {
                guard case .downloading(_, let received, _) = $0.phase else { return false }
                return received > 0
            }
        }
        // Match the server's request-number status lookup: the first rendition
        // is still producing and the second is complete. A reused request=1
        // makes both status queries resolve to the first producer.
        fixture.http.setReady()
        try await eventually("The completed rendition learns its own size while the first is still producing") {
            guard let second = fixture.manager.active.first(where: { $0.metadata.qualityID == "480p" }),
                  case .downloading(_, _, let expected) = second.phase else { return false }
            return expected == Int64(fixture.payload.count)
        }
        let first = try XCTUnwrap(fixture.manager.active.first { $0.metadata.qualityID == "auto" })
        guard case .downloading(_, _, let expected) = first.phase else { return XCTFail("The first transfer must remain active") }
        XCTAssertNil(expected)
        XCTAssertEqual(fixture.manager.preparationProgress[first.id]?.isComplete, false)
        XCTAssertEqual(fixture.http.requests(method: "GET").filter { $0.target.hasPrefix("/web/media/") }.count, 2)
    }

    func testUnavailableStatusStillDiscoversCompletedOutputWithoutRestartingTransfer() async throws {
        let fixture = try ByteTotalsFixture(statusUnavailable: true)
        addTeardownBlock { await fixture.cleanUp() }
        try await fixture.start()
        try await eventually("The growing response delivers bytes without preparation metadata") {
            guard case .downloading(_, let received, let expected) = fixture.manager.active.first?.phase else { return false }
            return received > 0 && expected == nil
        }
        fixture.http.setReady()
        try await eventually("Final headers remain discoverable when the optional status endpoint is unavailable", timeout: 20) {
            guard case .downloading(_, let received, let expected) = fixture.manager.active.first?.phase else { return false }
            return received > 0 && expected == Int64(fixture.payload.count)
        }
        XCTAssertEqual(fixture.http.requests(method: "GET").filter { $0.target.hasPrefix("/web/media/") }.count, 1)
        XCTAssertEqual(fixture.http.requests(method: "GET").filter { $0.target.hasPrefix("/api/web/transcode/") }.count, 1)
        XCTAssertEqual(fixture.http.requests(method: "HEAD").count, 1)
        fixture.http.sendSecondChunk()
        try await eventually("Native progress retains the discovered total") {
            guard case .downloading(_, let received, let expected) = fixture.manager.active.first?.phase else { return false }
            return received > Int64(fixture.payload.count / 3) && expected == Int64(fixture.payload.count)
        }
    }

    func testAlreadyQueuedByteCallbackCannotUndoAnAcceptedPause() async throws {
        let fixture = try ByteTotalsFixture()
        addTeardownBlock { await fixture.cleanUp() }
        try await fixture.start()
        try await eventually("Real HTTP bytes reach the running media task") {
            guard case .downloading(_, let received, _) = fixture.manager.active.first?.phase else { return false }
            return received > 0
        }
        let row = try XCTUnwrap(fixture.manager.active.first)
        let entry = try XCTUnwrap(DownloadQueueStore(rootDirectory: fixture.root).load().entries.first)
        let resource = try XCTUnwrap(entry.resources?.first { $0.resource.kind == .media })
        guard case .downloading(_, let received, let expected) = row.phase else { return XCTFail("Missing native progress") }
        fixture.manager.pause(row)
        // URLSession delegates deliver asynchronously to MainActor. A callback
        // queued before the tap can arrive before the durable pause operation.
        fixture.manager.resourceProgress(DownloadTaskEnvelope(metadata: entry.metadata, resource: resource),
                                         received: received, expected: expected)
        XCTAssertEqual(fixture.manager.active.first?.phase, .pausing)
        await fixture.manager.waitForPendingOperations()
        guard case .paused = fixture.manager.active.first?.phase else { return XCTFail("One pause must settle") }
    }

    func testFailedPauseOrCancelCommitRestoresTheSameLiveTransfer() async throws {
        for cancel in [false, true] {
            let files = ByteTotalsSaveFailureFileManager()
            let fixture = try ByteTotalsFixture(fileManager: files)
            addTeardownBlock { await fixture.cleanUp() }
            try await fixture.start()
            try await eventually("The native transfer has received its first prefix") {
                guard case .downloading(_, let received, _) = fixture.manager.active.first?.phase else { return false }
                return received > 0
            }
            let row = try XCTUnwrap(fixture.manager.active.first)
            files.rejectNextSave()
            if cancel { fixture.manager.cancel(row) }
            else { fixture.manager.pause(row) }
            await fixture.manager.waitForPendingOperations()
            XCTAssertNotNil(fixture.manager.errorMessage)
            XCTAssertEqual(fixture.manager.active.first?.id, row.id)
            XCTAssertEqual(try DownloadQueueStore(rootDirectory: fixture.root).load().entries.first?.state, .running)
            // Rejected persistence must resume the task suspended by the tap,
            // preserving the original HTTP response and its already-owned bytes.
            fixture.http.sendSecondChunk()
            try await eventually("More real bytes arrive after the storage error") {
                guard case .downloading(_, let received, _) = fixture.manager.active.first?.phase else { return false }
                return received > Int64(fixture.payload.count / 3)
            }
            fixture.http.setReady()
            try await eventually("A rejected pause or cancellation must also resume optional preparation updates") {
                guard case .downloading(_, _, let expected) = fixture.manager.active.first?.phase else { return false }
                return expected == Int64(fixture.payload.count)
            }
            XCTAssertEqual(fixture.http.requests(method: "GET").filter { $0.target.hasPrefix("/web/media/") }.count, 1)
            fixture.manager.cancel(try XCTUnwrap(fixture.manager.active.first))
            await fixture.manager.waitForPendingOperations()
            XCTAssertTrue(fixture.manager.active.isEmpty)
            XCTAssertEqual(try DownloadQueueStore(rootDirectory: fixture.root).load().entries.first?.state, .cancelled)
        }
    }

    func testReadyOutputAddsFinalLengthToAnAlreadyRunningChunkedTransfer() async throws {
        let fixture = try ByteTotalsFixture()
        addTeardownBlock { await fixture.cleanUp() }
        try await fixture.start()
        try await eventually("The growing response delivers real bytes without a total") {
            guard case .downloading(_, let received, let expected) = fixture.manager.active.first?.phase else { return false }
            return received > 0 && expected == nil && fixture.manager.preparationProgress.values.first != nil
        }
        let row = try XCTUnwrap(fixture.manager.active.first)
        let path = try XCTUnwrap(row.metadata.serverPath)
        XCTAssertEqual(fixture.manager.preparationProgress[row.id]?.fraction, 1)
        XCTAssertEqual(fixture.manager.preparationProgress[row.id]?.isComplete, false)
        XCTAssertTrue(fixture.http.requests(method: "HEAD").isEmpty,
                      "Reaching the catalog runtime does not establish an immutable output size")

        // A real ready response can report slightly less than a stale catalog
        // duration. Its state still ends preparation and enables the size probe.
        fixture.http.setReady()
        try await eventually("HEAD discovers the finished file while the original GET remains open") {
            guard case .downloading(_, let received, let expected) = fixture.manager.active.first?.phase else { return false }
            return received > 0 && received < Int64(fixture.payload.count) && expected == Int64(fixture.payload.count)
        }
        XCTAssertEqual(fixture.manager.preparationProgress[row.id]?.isComplete, true)
        XCTAssertLessThan(try XCTUnwrap(fixture.manager.preparationProgress[row.id]?.fraction), 1)
        guard case .downloading(_, let firstReceived, _) = try XCTUnwrap(fixture.manager.active.first?.phase) else {
            return XCTFail("The original transfer must remain visible")
        }
        fixture.http.sendSecondChunk()
        try await eventually("Later native byte callbacks retain the learned total") {
            guard case .downloading(_, let received, let expected) = fixture.manager.active.first?.phase else { return false }
            return received > firstReceived && expected == Int64(fixture.payload.count)
        }
        let heads = fixture.http.requests(method: "HEAD")
        let gets = fixture.http.requests(method: "GET").filter { $0.target.hasPrefix("/web/media/") }
        XCTAssertEqual(heads.count, 1)
        XCTAssertEqual(gets.count, 1, "Learning a size must not create a second transfer or generation")
        XCTAssertEqual(heads.first?.target, path)
        XCTAssertEqual(gets.first?.target, path)
        XCTAssertEqual(heads.first?.authorization, fixture.owner?.authorizationHeader())
        XCTAssertEqual(gets.first?.authorization, fixture.owner?.authorizationHeader())

        fixture.http.finishMedia()
        try await eventually("The original chunked response installs the complete inspected movie") {
            fixture.manager.completed.first?.isReadyToWatch == true
        }
        XCTAssertTrue(fixture.manager.active.isEmpty)
        XCTAssertEqual(fixture.manager.completed.first?.byteCount, Int64(fixture.payload.count))
        XCTAssertEqual(fixture.http.requests(method: "HEAD").count, 1)
    }

    func testReadyWithoutProducedSecondsEndsCachedPartialPreparation() async throws {
        let fixture = try ByteTotalsFixture(producingSeconds: 15, readySeconds: nil)
        addTeardownBlock { await fixture.cleanUp() }
        try await fixture.start()
        try await eventually("A real partial preparation response precedes readiness") {
            guard case .downloading(_, let received, let expected) = fixture.manager.active.first?.phase else { return false }
            let progress = fixture.manager.preparationProgress.values.first
            return received > 0 && expected == nil && progress?.producedSeconds == 15 && progress?.isComplete == false
        }
        let row = try XCTUnwrap(fixture.manager.active.first)
        fixture.http.setReady()
        try await eventually("Ready without the optional timestamp still discovers the transfer total") {
            guard case .downloading(_, let received, let expected) = fixture.manager.active.first?.phase else { return false }
            return received > 0 && received < Int64(fixture.payload.count) && expected == Int64(fixture.payload.count)
        }
        let preparation = try XCTUnwrap(fixture.manager.preparationProgress[row.id])
        XCTAssertTrue(preparation.isComplete,
                      "A cached 25% preparation must not mask byte progress after a ready response omits produced_seconds")
        XCTAssertEqual(preparation.producedSeconds, 15, "Do not invent a final prepared timestamp")
        XCTAssertEqual(fixture.http.requests(method: "HEAD").count, 1)
        XCTAssertEqual(fixture.http.requests(method: "GET").filter { $0.target.hasPrefix("/web/media/") }.count, 1)
        XCTAssertTrue(fixture.manager.completed.isEmpty, "Readiness describes server output, while this media response remains open")
    }

    func testFinalSizeResponseDuringInspectionCannotReplaceSavingWithZeroByteProgress() async throws {
        let files = ByteTotalsInspectionFileManager()
        let fixture = try ByteTotalsFixture(headBehavior: .held, fileManager: files)
        addTeardownBlock { files.releaseInspection(); await fixture.cleanUp() }
        fixture.http.setReady()
        try await fixture.start()
        try await eventually("The final-size HEAD is held while media is still transferring") {
            fixture.http.requests(method: "HEAD").count == 1
        }
        fixture.http.finishMedia()
        try await eventually("The actual received file enters local inspection") {
            files.isInspecting && fixture.manager.active.first?.phase == .finishing
        }
        var phasesAfterEOF: [DownloadPhase] = []
        let observation = fixture.manager.$active.sink { rows in
            if let phase = rows.first?.phase { phasesAfterEOF.append(phase) }
        }
        defer { observation.cancel() }
        fixture.http.releaseHead()
        try await eventually("The held HEAD response reaches the socket") { fixture.http.headResponsesSent == 1 }
        // Span a complete shared-poller tick while real file inspection stays
        // blocked. The old callback publishes downloading(received: 0) here.
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(fixture.manager.active.first?.phase, .finishing)
        XCTAssertTrue(phasesAfterEOF.allSatisfy { $0 == .finishing },
                      "Metadata cannot restart transfer presentation after URLSession delivered EOF")
        XCTAssertEqual(fixture.http.requests(method: "HEAD").count, 1,
                       "Verification must not launch another final-size request")
        files.releaseInspection()
        try await eventually("The same received file completes inspection and installation") {
            fixture.manager.completed.first?.isReadyToWatch == true
        }
        XCTAssertEqual(fixture.manager.completed.first?.byteCount, Int64(fixture.payload.count))
        XCTAssertEqual(fixture.http.requests(method: "GET").filter { $0.target.hasPrefix("/web/media/") }.count, 1)
    }

    func testResumedGrowingRangeWaitsForAWholeFileTotalFromHEAD() async throws {
        let fixture = try ByteTotalsFixture(growingRangeOnResume: true)
        addTeardownBlock { await fixture.cleanUp() }
        try await fixture.start()
        try await eventually("The initial validator-backed response supplies resumable native bytes") {
            guard case .downloading(_, let received, let expected) = fixture.manager.active.first?.phase else { return false }
            return received > 0 && expected == Int64(fixture.payload.count)
        }
        fixture.manager.pause(try XCTUnwrap(fixture.manager.active.first))
        await fixture.manager.waitForPendingOperations()
        let paused = try XCTUnwrap(fixture.manager.active.first)
        XCTAssertEqual(paused.phase, .paused(canResume: true))
        fixture.manager.resume(paused)
        try await eventually("A real resumed 206 with unknown whole-file length shows received bytes only") {
            guard case .downloading(_, let received, let expected) = fixture.manager.active.first?.phase else { return false }
            return received > 0 && expected == nil && fixture.http.requests(method: "GET").contains { ($0.rangeStart ?? 0) > 0 }
        }
        XCTAssertTrue(fixture.http.requests(method: "HEAD").isEmpty)
        fixture.http.setReady()
        try await eventually("The segment's positive Content-Length does not prevent whole-file HEAD discovery") {
            guard case .downloading(_, let received, let expected) = fixture.manager.active.first?.phase else { return false }
            return received > 0 && received < Int64(fixture.payload.count) && expected == Int64(fixture.payload.count)
        }
        let gets = fixture.http.requests(method: "GET").filter { $0.target.hasPrefix("/web/media/") }
        XCTAssertEqual(gets.count, 2, "Only the original and native resume GET may transfer movie bytes")
        let resumed = try XCTUnwrap(gets.last)
        XCTAssertGreaterThan(try XCTUnwrap(resumed.rangeStart), 0)
        let head = try XCTUnwrap(fixture.http.requests(method: "HEAD").first)
        XCTAssertEqual(head.target, resumed.target)
        XCTAssertEqual(head.authorization, resumed.authorization)
        XCTAssertEqual(fixture.http.requests(method: "HEAD").count, 1)
        XCTAssertTrue(fixture.manager.completed.isEmpty)
    }

    func testUnusableFinalSizeResponsesAreBoundedAndNeverFailTheMediaTransfer() async throws {
        let fixture = try ByteTotalsFixture(headBehavior: .unusable)
        addTeardownBlock { await fixture.cleanUp() }
        fixture.http.setReady()
        try await fixture.start()
        try await eventually("All three optional metadata attempts complete", timeout: 12) {
            fixture.http.requests(method: "HEAD").count == 3
        }
        try await Task.sleep(for: .milliseconds(3_300))
        XCTAssertEqual(fixture.http.requests(method: "HEAD").count, 3)
        XCTAssertEqual(fixture.http.requests(method: "GET").filter { $0.target.hasPrefix("/web/media/") }.count, 1)
        guard case .downloading(_, let received, let expected) = try XCTUnwrap(fixture.manager.active.first?.phase) else {
            return XCTFail("Optional metadata must not replace a working media transfer with a failure")
        }
        XCTAssertGreaterThan(received, 0)
        XCTAssertNil(expected, "Missing length, HTML, and encoded responses are not a trustworthy movie size")
        let journal = try DownloadQueueStore(rootDirectory: fixture.root).load()
        XCTAssertEqual(journal.entries.first?.state, .running)
        XCTAssertNil(journal.entries.first?.failure)
        XCTAssertEqual(journal.entries.first?.metadata.retryAttempt, 0)
    }

    func testCancelledTransferIgnoresAnOutstandingFinalSizeResponse() async throws {
        let fixture = try ByteTotalsFixture(headBehavior: .held)
        addTeardownBlock { await fixture.cleanUp() }
        fixture.http.setReady()
        try await fixture.start()
        try await eventually("The metadata request is held at the HTTP boundary") {
            fixture.http.requests(method: "HEAD").count == 1
        }
        let row = try XCTUnwrap(fixture.manager.active.first)
        fixture.manager.cancel(row)
        XCTAssertEqual(fixture.manager.active.first?.phase, .cancelling, "A cancel tap must be acknowledged before asynchronous cleanup")
        await fixture.manager.waitForPendingOperations()
        fixture.http.releaseHead()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(fixture.manager.active.isEmpty)
        XCTAssertTrue(fixture.manager.preparationProgress.isEmpty)
        XCTAssertTrue(fixture.manager.completed.isEmpty)
        XCTAssertEqual(try DownloadQueueStore(rootDirectory: fixture.root).load().entries.first?.state, .cancelled)
        XCTAssertEqual(fixture.http.requests(method: "HEAD").count, 1)
    }

    private func eventually(_ description: String, timeout: TimeInterval = 9,
                            condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        guard condition() else {
            XCTFail(description)
            throw URLError(.timedOut)
        }
    }
}

@MainActor
private final class ByteTotalsFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("byte-totals-\(UUID().uuidString)")
    let payload: Data
    let http: ByteTotalsHTTP
    let manager: DownloadManager
    private(set) var owner: ServerConnection?
    private var movie: MediaItem?

    init(headBehavior: ByteTotalsHTTP.HeadBehavior = .valid, producingSeconds: Double = 60,
         readySeconds: Double? = 59.5, fileManager: FileManager = .default,
         growingRangeOnResume: Bool = false, statusUnavailable: Bool = false, requestScopedStatus: Bool = false,
         paddingBytes: Int = 0) throws {
        // Large enough to cross URLSession's native file-write buffering before
        // the next chunk; every byte belongs to a real generated MP4 fixture.
        let url = try XCTUnwrap(Bundle(for: DownloadByteTotalsTests.self).url(forResource: "synthetic-native-tracks", withExtension: "mp4"))
        var data = try Data(contentsOf: url)
        if paddingBytes > 0 {
            var size = UInt32(paddingBytes + 8).bigEndian
            withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
            data.append(Data("free".utf8))
            data.append(Data(count: paddingBytes))
        }
        payload = data
        http = try ByteTotalsHTTP(payload: payload, headBehavior: headBehavior,
                                 producingSeconds: producingSeconds, readySeconds: readySeconds,
                                 growingRangeOnResume: growingRangeOnResume, statusUnavailable: statusUnavailable,
                                 requestScopedStatus: requestScopedStatus)
        manager = DownloadManager(store: DownloadManifestStore(rootDirectory: root, fileManager: fileManager),
            sessionIdentifier: "byte-totals.\(UUID().uuidString)", sessionConfiguration: .ephemeral)
    }

    func start() async throws {
        let connection = try ServerConnection(serverAddress: try await http.start(), username: "byte-viewer", password: "synthetic-byte-secret")
        owner = connection
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(connection)
        var response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)) as? [String: Any])
        var item = try XCTUnwrap(response["item"] as? [String: Any])
        item["duration_seconds"] = 60
        item["captions"] = []
        item["art_url"] = NSNull()
        response["item"] = item
        let movie = try JSONDecoder().decode(ItemResponse.self, from: JSONSerialization.data(withJSONObject: response)).item
        self.movie = movie
        manager.configure(connection: connection, statusClient: client)
        await manager.waitForPendingOperations()
        try manager.start(item: movie, kind: .compatible, client: client, quality: "auto", audioIndex: 1)
        await manager.waitForPendingOperations()
        // The caller may change accounts; runtime metadata requests retain the
        // same immutable owner as the original media task.
        client.configure(nil)
    }

    func startSecondRendition() async throws {
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(try XCTUnwrap(owner))
        try manager.start(item: try XCTUnwrap(movie), kind: .compatible, client: client, quality: "480p", audioIndex: 1)
        await manager.waitForPendingOperations()
    }

    func cleanUp() async {
        manager.configure(connection: nil)
        for row in manager.active { manager.cancel(row) }
        await manager.waitForPendingOperations()
        http.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

/// Real chunked HTTP keeps GET headers immutable while a later HEAD exposes the
/// finalized file. The listener never synthesizes a delegate progress event.
private final class ByteTotalsHTTP: @unchecked Sendable {
    enum HeadBehavior { case valid, unusable, held }
    struct Request {
        let method: String
        let target: String
        let authorization: String?
        let rangeStart: Int?
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "byte-totals.http")
    private let lock = NSLock()
    private let payload: Data
    private let headBehavior: HeadBehavior
    private let producingSeconds: Double
    private let readySeconds: Double?
    private let growingRangeOnResume: Bool
    private let statusUnavailable: Bool
    private let requestScopedStatus: Bool
    private var ready = false
    private var captured: [Request] = []
    private var sentHeads = 0
    private var connections: [NWConnection] = []
    private var media: NWConnection?
    private var heldHead: NWConnection?
    private var chunkEnd = 0
    private var expectedAuthorization: String { "Basic " + Data("byte-viewer:synthetic-byte-secret".utf8).base64EncodedString() }

    init(payload: Data, headBehavior: HeadBehavior, producingSeconds: Double, readySeconds: Double?,
         growingRangeOnResume: Bool, statusUnavailable: Bool, requestScopedStatus: Bool) throws {
        self.payload = payload
        self.headBehavior = headBehavior
        self.producingSeconds = producingSeconds
        self.readySeconds = readySeconds
        self.growingRangeOnResume = growingRangeOnResume
        self.statusUnavailable = statusUnavailable
        self.requestScopedStatus = requestScopedStatus
        listener = try NWListener(using: .tcp, on: .any)
    }
    func requests(method: String) -> [Request] {
        lock.lock(); defer { lock.unlock() }
        return captured.filter { $0.method == method }
    }
    var headResponsesSent: Int { lock.lock(); defer { lock.unlock() }; return sentHeads }
    func setReady() { lock.lock(); ready = true; lock.unlock() }
    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, let port = self.listener.port else { return }
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: "http://127.0.0.1:\(port.rawValue)")
                case .failed(let error):
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }
    func sendSecondChunk() {
        queue.async { [self] in
            guard let media else { return }
            let next = chunkEnd + (payload.count - chunkEnd) / 2
            sendChunk(payload.subdata(in: chunkEnd..<next), to: media)
            chunkEnd = next
        }
    }
    func sendProgressBurst() {
        queue.async { [self] in
            let start = chunkEnd
            let end = payload.count * 2 / 3
            for index in 1...60 {
                queue.asyncAfter(deadline: .now() + Double(index) * 0.025) { [self] in
                    guard let media else { return }
                    let next = start + (end - start) * index / 60
                    sendChunk(payload.subdata(in: chunkEnd..<next), to: media)
                    chunkEnd = next
                }
            }
        }
    }
    func finishMedia() {
        queue.async { [self] in
            guard let media else { return }
            sendChunk(payload.subdata(in: chunkEnd..<payload.count), to: media)
            media.send(content: growingRangeOnResume ? nil : Data("0\r\n\r\n".utf8),
                       completion: .contentProcessed { _ in media.cancel() })
            self.media = nil
        }
    }
    func releaseHead() {
        queue.async { [self] in
            guard let heldHead else { return }
            sendHead(heldHead, extra: "Content-Length: \(payload.count)\r\n")
            self.heldHead = nil
        }
    }
    func stop() {
        listener.cancel()
        queue.async { [self] in connections.forEach { $0.cancel() }; connections.removeAll() }
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            if let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") {
                self.respond(connection, text: text)
            } else if complete || error != nil || bytes.count > 65_536 { connection.cancel() }
            else { self.receive(connection, accumulated: bytes) }
        }
    }
    private func respond(_ connection: NWConnection, text: String) {
        let lines = text.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { connection.cancel(); return }
        let range = lines.first { $0.lowercased().hasPrefix("range: bytes=") }?
            .split(separator: "=", maxSplits: 1).last?.split(separator: "-", maxSplits: 1).first.flatMap { Int($0) }
        let request = Request(method: String(first[0]), target: String(first[1]), authorization:
            lines.first { $0.lowercased().hasPrefix("authorization:") }?
                .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), rangeStart: range)
        lock.lock()
        captured.append(request)
        var isReady = ready
        let headNumber = captured.filter { $0.method == "HEAD" }.count
        if requestScopedStatus, request.target.hasPrefix("/api/web/transcode/") {
            let generation = URLComponents(string: request.target)?.queryItems?.first { $0.name == "request" }?.value
            let producer = captured.first {
                $0.method == "GET" && $0.target.hasPrefix("/web/media/") &&
                URLComponents(string: $0.target)?.queryItems?.first { $0.name == "request" }?.value == generation
            }
            isReady = ready && URLComponents(string: producer?.target ?? "")?.queryItems?.first { $0.name == "quality" }?.value == "480p"
        }
        lock.unlock()
        guard request.authorization == expectedAuthorization else {
            respondJSON(connection, status: 401, body: "{}")
            return
        }
        if request.method == "HEAD" {
            guard isReady else { sendHead(connection, extra: ""); return }
            switch headBehavior {
            case .held: heldHead = connection
            case .valid: sendHead(connection, extra: "Content-Length: \(payload.count)\r\n")
            case .unusable:
                if headNumber == 1 { sendHead(connection, extra: "") }
                else if headNumber == 2 { sendHead(connection, type: "text/html", extra: "Content-Length: \(payload.count)\r\n") }
                else { sendHead(connection, extra: "Content-Length: \(payload.count)\r\nContent-Encoding: gzip\r\n") }
            }
        } else if request.target.hasPrefix("/api/web/transcode/") {
            if statusUnavailable, request.method == "GET" {
                respondJSON(connection, status: 404, body: "{}")
                return
            }
            let url = URLComponents(string: request.target)
            let generation = url?.queryItems?.first { $0.name == "request" }?.value ?? "0"
            let id = url?.path.split(separator: "/").last.map(String.init) ?? "42001"
            let state = request.method == "DELETE" ? "cancelled" : isReady ? "ready" : "producing"
            let produced = isReady ? readySeconds : producingSeconds
            let progressField = produced.map { ",\"produced_seconds\":\($0)" } ?? ""
            respondJSON(connection, status: 200, body: "{\"schema_version\":2,\"item_id\":\"\(id)\",\"request_id\":\(generation),\"state\":\"\(state)\"\(progressField)}")
        } else if request.target.hasPrefix("/web/media/"), request.method == "GET" {
            media = connection
            let start = growingRangeOnResume ? min(payload.count - 1, max(0, request.rangeStart ?? 0)) : 0
            chunkEnd = growingRangeOnResume && request.rangeStart == nil
                ? payload.count * 2 / 3 : start + (payload.count - start) / 3
            let ranged = growingRangeOnResume && request.rangeStart != nil
            let length = growingRangeOnResume
                ? "Content-Length: \(payload.count - start)\r\nAccept-Ranges: bytes\r\nETag: \"synthetic-byte-v1\"\r\n"
                : "Transfer-Encoding: chunked\r\n"
            let rangeHeader = ranged ? "Content-Range: bytes \(start)-\(payload.count - 1)/*\r\n" : ""
            let header = "HTTP/1.1 \(ranged ? 206 : 200) OK\r\nContent-Type: video/mp4\r\n\(length)\(rangeHeader)Connection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
            sendChunk(payload.subdata(in: start..<chunkEnd), to: connection)
        } else { respondJSON(connection, status: 404, body: "{}") }
    }
    private func sendChunk(_ bytes: Data, to connection: NWConnection) {
        if growingRangeOnResume {
            connection.send(content: bytes, completion: .contentProcessed { _ in })
            return
        }
        var encoded = Data("\(String(bytes.count, radix: 16))\r\n".utf8)
        encoded.append(bytes)
        encoded.append(Data("\r\n".utf8))
        connection.send(content: encoded, completion: .contentProcessed { _ in })
    }
    private func sendHead(_ connection: NWConnection, type: String = "video/mp4", extra: String) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\n\(extra)Connection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { connection.cancel(); return }
            self.lock.lock()
            self.sentHeads += 1
            self.lock.unlock()
            connection.cancel()
        })
    }
    private func respondJSON(_ connection: NWConnection, status: Int, body: String) {
        let bytes = Data(body.utf8)
        var response = Data("HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(bytes)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class ByteTotalsInspectionFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var entered = false
    var isInspecting: Bool { lock.lock(); defer { lock.unlock() }; return entered }

    override func fileExists(atPath path: String) -> Bool {
        lock.lock()
        let shouldHold = !entered && URL(fileURLWithPath: path).lastPathComponent == "payload"
        if shouldHold { entered = true }
        lock.unlock()
        if shouldHold, release.wait(timeout: .now() + 12) == .timedOut { return false }
        return super.fileExists(atPath: path)
    }

    func releaseInspection() { release.signal() }
}

private final class ByteTotalsSaveFailureFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var rejectSave = false
    func rejectNextSave() { lock.lock(); rejectSave = true; lock.unlock() }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        lock.lock()
        let reject = rejectSave && url.lastPathComponent.hasPrefix("byte-totals-")
        if reject { rejectSave = false }
        lock.unlock()
        if reject { throw CocoaError(.fileWriteOutOfSpace) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
