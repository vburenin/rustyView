import AVFoundation
import Network
import XCTest
@testable import rustyView

@MainActor
final class SavedCollectionIntegrationTests: XCTestCase {
    func testHistoryShowsLatestMovieOnceAfterRealRepeatedPlaybackAndReopen() async throws {
        let fixture = try SavedCollectionFixture()
        addTeardownBlock { await fixture.cleanUp() }
        let address = try await fixture.server.start()
        let record = try await fixture.install(address: address, account: "first-viewer")
        let app = try await fixture.app(address: address, account: "first-viewer")
        let key = app.key(for: record)

        try await app.playSaved(key, start: .position(0))
        await waitFor("The first real playback advances and records a viewing") {
            app.player.player.currentTime().seconds >= 0.5 && app.userLibrary.history.count == 1
        }
        app.player.stop()
        try await app.userLibrary.flush()
        let firstID = try XCTUnwrap(app.userLibrary.history.first?.id)

        try await app.playSaved(key, start: .startOver)
        await waitFor("A second actual playback creates a distinct viewing of the same movie") {
            app.player.player.currentTime().seconds >= 0.5 && app.userLibrary.history.count == 2
        }
        app.player.stop()
        try await app.userLibrary.flush()
        let latest = try XCTUnwrap(app.userLibrary.history.first)
        XCTAssertNotEqual(latest.id, firstID)
        XCTAssertEqual(app.savedHistory().map(\.id), [latest.id],
                       "History must display the movie once, even when two actual viewings were recorded")
        XCTAssertEqual(app.savedHistory(offlineOnly: true).map(\.key), [key])

        let reopened = try await fixture.app(address: address, account: "first-viewer")
        XCTAssertEqual(reopened.userLibrary.history.count, 2,
                       "Deduplicating the visible collection must preserve its underlying viewing records")
        XCTAssertEqual(reopened.savedHistory().map(\.id), [latest.id])
        XCTAssertEqual(reopened.savedHistory(offlineOnly: true).map(\.id), [latest.id])
        XCTAssertTrue(fixture.server.requests.isEmpty,
                      "Repeated local playback and restored History must not refresh the server")
    }

    func testHistoryCanonicalDedupKeepsOtherAccountsServersAndUnassignedMoviesAfterReopen() async throws {
        let fixture = try SavedCollectionFixture()
        addTeardownBlock { await fixture.cleanUp() }
        let address = try await fixture.server.start()
        let app = try await fixture.app(address: address, account: "first-viewer")
        let canonical = MovieLibraryKey(serverIdentity: "https://history.example.test/library", accountUsername: "first-viewer", mediaID: "73001")
        let equivalent = MovieLibraryKey(serverIdentity: "HTTPS://HISTORY.example.test:443/library/", accountUsername: "first-viewer", mediaID: "73001")
        let otherAccount = MovieLibraryKey(serverIdentity: canonical.serverIdentity, accountUsername: "second-viewer", mediaID: "73001")
        let otherServer = MovieLibraryKey(serverIdentity: "https://other-history.example.test/library", accountUsername: "first-viewer", mediaID: "73001")
        let unassigned = MovieLibraryKey(serverIdentity: canonical.serverIdentity, accountUsername: nil, mediaID: "73001")
        let movie = MovieMetadata(mediaID: "73001", title: "The Glass Compass", durationSeconds: 60)
        let keys = [canonical, otherAccount, otherServer, unassigned, equivalent]
        var viewingIDs: [UUID] = []
        for (index, key) in keys.enumerated() {
            let id = UUID()
            viewingIDs.append(id)
            let date = Date(timeIntervalSince1970: 1_000 + Double(index))
            app.userLibrary.record(PlaybackActivity(viewingID: id, key: key, movie: movie, source: .online,
                event: .started(position: 5, duration: 60), occurredAt: date))
            if index == 0 {
                app.userLibrary.record(PlaybackActivity(viewingID: id, key: key, movie: movie, source: .online,
                    event: .completed(position: 60, duration: 60), occurredAt: date.addingTimeInterval(0.5)))
            }
        }
        try await app.userLibrary.flush()
        let reopened = try await fixture.app(address: address, account: "first-viewer")
        let visible = reopened.savedHistory()
        XCTAssertEqual(reopened.userLibrary.history.count, 5)
        XCTAssertEqual(visible.map(\.id), [viewingIDs[4], viewingIDs[3], viewingIDs[2], viewingIDs[1]])
        XCTAssertEqual(Set(visible.map(\.key)), Set([canonical, otherAccount, otherServer, unassigned]),
                       "A matching title or media ID cannot merge another server, account, or unassigned movie")
        XCTAssertNil(visible.first?.completedAt,
                     "The newest viewing supplies its own status instead of inheriting an older completed watch")
        XCTAssertTrue(reopened.savedHistory(offlineOnly: true).isEmpty)
        XCTAssertTrue(fixture.server.requests.isEmpty)
    }

    func testSavedMovieResumesLocalFileAfterEmptyHTTPDirectoryAndForgottenAccountReopen() async throws {
        let fixture = try SavedCollectionFixture()
        addTeardownBlock { await fixture.cleanUp() }
        let address = try await fixture.server.start()
        let record = try await fixture.install(address: address, account: "first-viewer")
        let app = try await fixture.app(address: address, account: "first-viewer")
        let key = app.key(for: record)
        app.userLibrary.setFavorite(true, movie: record.movieMetadata, for: key)
        app.userLibrary.record(PlaybackActivity(viewingID: UUID(), key: key, movie: record.movieMetadata,
            source: .online, event: .started(position: 2, duration: 6)))
        try await app.userLibrary.flush()

        try await app.library.reload()
        XCTAssertTrue(app.library.entries.isEmpty)
        XCTAssertTrue(fixture.server.requests.contains { $0.target.hasPrefix("/api/web/library") && $0.authenticated })
        XCTAssertEqual(app.savedEntries(.favorites).map(\.key), [key])
        app.disconnect()
        XCTAssertNil(try fixture.settings.savedConnection())
        XCTAssertNil(app.client.connection)
        let reopened = try await fixture.app(address: address, account: nil)
        XCTAssertFalse(reopened.isConfigured)
        XCTAssertEqual(reopened.savedEntries(.continueWatching, offlineOnly: true).map(\.key), [key])
        XCTAssertEqual(reopened.bestReadyRecord(for: key)?.id, record.id)
        let requestsBeforePlayback = fixture.server.requests.count

        try await reopened.playSaved(key)
        await waitFor("Saved offline playback advances past the persisted two-second bookmark") {
            reopened.player.player.currentTime().seconds >= 2.5
                && reopened.userLibrary.history.contains { $0.source == .offline(recordID: record.id) }
        }
        let asset = try XCTUnwrap(reopened.player.player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(asset.url, reopened.downloads.localURL(for: record))
        XCTAssertTrue(asset.url.isFileURL)
        XCTAssertTrue(reopened.player.isOfflinePlayback)
        XCTAssertLessThan(reopened.player.player.currentTime().seconds, 5.5)
        XCTAssertEqual(reopened.player.duration, 6, accuracy: 0.15)
        XCTAssertEqual(fixture.server.requests.count, requestsBeforePlayback,
                       "The live HTTP listener must see no item, artwork, caption, or media request from offline playback.")
    }

    func testSameMediaIDForTwoAccountsNeverRetargetsASelectionToCurrentAccount() async throws {
        let fixture = try SavedCollectionFixture()
        addTeardownBlock { await fixture.cleanUp() }
        let address = try await fixture.server.start()
        let first = try await fixture.install(address: address, account: "first-viewer", title: "The Copper Moon")
        let second = try await fixture.install(address: address, account: "second-viewer", title: "The Paper Planet")
        let app = try await fixture.app(address: address, account: "second-viewer")
        let firstKey = app.key(for: first), secondKey = app.key(for: second)
        for (record, position) in [(first, 1.5), (second, 3.0)] {
            let key = app.key(for: record)
            app.userLibrary.setFavorite(true, movie: record.movieMetadata, for: key)
            app.userLibrary.record(PlaybackActivity(viewingID: UUID(), key: key, movie: record.movieMetadata,
                source: .offline(recordID: record.id), event: .started(position: position, duration: 6)))
        }
        try await app.userLibrary.flush()
        XCTAssertEqual(Set(app.savedEntries(.favorites).map(\.key)), Set([firstKey, secondKey]))
        XCTAssertFalse(app.owns(firstKey))
        XCTAssertTrue(app.owns(secondKey))
        XCTAssertEqual(app.savedResumePosition(for: firstKey), 1.5)
        XCTAssertEqual(app.savedResumePosition(for: secondKey), 3)

        try await app.playSaved(firstKey)
        await waitFor("The selected former account's own offline movie advances") { app.player.player.currentTime().seconds >= 2 }
        XCTAssertEqual((app.player.player.currentItem?.asset as? AVURLAsset)?.url, app.downloads.localURL(for: first))
        XCTAssertEqual(app.player.movieMetadata?.title, "The Copper Moon")
        try await app.playSaved(secondKey)
        await waitFor("The current account's distinct bookmark is applied") { app.player.player.currentTime().seconds >= 3.5 }
        let secondItem = try XCTUnwrap(app.player.player.currentItem)
        XCTAssertEqual((secondItem.asset as? AVURLAsset)?.url, app.downloads.localURL(for: second))
        XCTAssertEqual(app.player.movieMetadata?.title, "The Paper Planet")

        // Once that former account's local file is explicitly removed, its
        // saved row must not resolve the same decimal ID against this account.
        app.downloads.delete(first)
        await app.downloads.waitForPendingOperations()
        XCTAssertNil(app.bestReadyRecord(for: firstKey))
        do { try await app.playSaved(firstKey); XCTFail("A foreign account key cannot be routed online through the current login.") }
        catch { XCTAssertEqual(UserFacingError(error).category, .notConfigured) }
        XCTAssertTrue(app.player.player.currentItem === secondItem)
        XCTAssertTrue(app.userLibrary.isFavorite(for: firstKey))
        XCTAssertEqual(app.userLibrary.entry(for: firstKey)?.movie?.title, "The Copper Moon")
        XCTAssertTrue(fixture.server.requests.isEmpty, "Both local sources and the rejected account mismatch must avoid HTTP.")
    }

    func testSavedPresentationUsesInspectedDurationAndRejectsBookmarkBeyondActualLocalMovie() async throws {
        let fixture = try SavedCollectionFixture()
        addTeardownBlock { await fixture.cleanUp() }
        let address = try await fixture.server.start()
        let record = try await fixture.install(address: address, account: "first-viewer", catalogDuration: 7_200)
        let app = try await fixture.app(address: address, account: "first-viewer")
        let key = app.key(for: record)
        app.userLibrary.setFavorite(true, movie: record.movieMetadata, for: key)
        app.userLibrary.record(PlaybackActivity(viewingID: UUID(), key: key, movie: record.movieMetadata,
            source: .online, event: .started(position: 35, duration: 7_200)))
        try await app.userLibrary.flush()
        XCTAssertEqual(app.userLibrary.resumePosition(for: key), 35, "The online bookmark is usable against its original runtime.")
        XCTAssertEqual(try XCTUnwrap(app.savedDuration(for: key, fallback: 7_200)), 6, accuracy: 0.15)
        XCTAssertNil(app.savedResumePosition(for: key), "That position cannot be offered for this shorter inspected copy.")
        XCTAssertNil(app.timeRemaining(for: key, duration: 7_200))
        XCTAssertNil(app.timeRemaining(for: record))
        XCTAssertTrue(app.savedEntries(.continueWatching).isEmpty)
        XCTAssertEqual(app.savedEntries(.favorites).map(\.key), [key])

        try await app.playSaved(key)
        await waitFor("Invalid online bookmark falls back to real local playback from the beginning") {
            app.player.player.currentTime().seconds >= 0.75
                && app.userLibrary.history.contains { $0.source == .offline(recordID: record.id) }
        }
        XCTAssertLessThan(app.player.player.currentTime().seconds, 2)
        XCTAssertEqual(app.player.duration, 6, accuracy: 0.15)
        XCTAssertEqual((app.player.player.currentItem?.asset as? AVURLAsset)?.url, app.downloads.localURL(for: record))
        XCTAssertTrue(fixture.server.requests.isEmpty)
    }

    func testSavedRemoteMovieFetchesProfilesAndSendsPreferredQualityInActualPreparedRequest() async throws {
        let fixture = try SavedCollectionFixture()
        addTeardownBlock { await fixture.cleanUp() }
        try fixture.enableRemoteMovie(includeFullHD: true)
        let address = try await fixture.server.start()
        let app = try await fixture.app(address: address, account: "first-viewer")
        let connection = try XCTUnwrap(app.client.connection)
        let key = MovieLibraryKey(connection: connection, mediaID: "73001")
        app.userLibrary.setFavorite(true, movie: MovieMetadata(mediaID: key.mediaID, title: "The Glass Compass"), for: key)
        app.playbackPreferences.preferredQualityID = "full_hd"
        XCTAssertNil(app.library.capabilities)

        try await app.playSaved(key)
        await waitFor("AVFoundation sends the chosen prepared quality to the actual HTTP listener") {
            fixture.server.requests.contains { $0.target.hasPrefix("/web/media/73001.m3u8") && $0.authenticated }
        }
        let prepared = try XCTUnwrap(fixture.server.requests.first { $0.target.hasPrefix("/web/media/73001.m3u8") && $0.authenticated })
        let query = try XCTUnwrap(URLComponents(string: prepared.target)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "quality" }?.value, "full_hd")
        XCTAssertEqual(query.first { $0.name == "video_mode" }?.value, "transcode")
        XCTAssertEqual(prepared.account, "first-viewer")
        XCTAssertTrue(fixture.server.requests.contains { $0.target.hasPrefix("/api/web/library") && $0.target.contains("limit=1") && $0.account == "first-viewer" })
        XCTAssertTrue(fixture.server.requests.contains { $0.target == "/api/web/item/73001" && $0.account == "first-viewer" })
        XCTAssertEqual(app.player.selectedQuality, "full_hd")
        XCTAssertNil(app.player.qualityNotice)
        XCTAssertTrue(app.player.qualityProfiles?.contains { $0.id == "full_hd" } == true, "The active player's choices must reflect the profiles fetched for this saved request.")
        XCTAssertNil(app.library.capabilities, "A saved-row profile lookup must not replace the visible browse state.")
        XCTAssertEqual(PlaybackPreferences(defaults: fixture.defaults).preferredQualityID, "full_hd")
    }

    func testUnavailableSavedQualityDisclosesAutoInPlayerWithoutChangingPreference() async throws {
        let fixture = try SavedCollectionFixture()
        addTeardownBlock { await fixture.cleanUp() }
        try fixture.enableRemoteMovie(includeFullHD: false)
        let address = try await fixture.server.start()
        let app = try await fixture.app(address: address, account: "first-viewer")
        let key = MovieLibraryKey(connection: try XCTUnwrap(app.client.connection), mediaID: "73001")
        app.playbackPreferences.preferredQualityID = "full_hd"
        try await app.playSaved(key)
        await waitFor("Unavailable quality is resolved before the prepared HTTP request") {
            fixture.server.requests.contains { $0.target.hasPrefix("/web/media/73001.m3u8") && $0.authenticated }
        }
        let prepared = try XCTUnwrap(fixture.server.requests.first { $0.target.hasPrefix("/web/media/73001.m3u8") && $0.authenticated })
        XCTAssertEqual(URLComponents(string: prepared.target)?.queryItems?.first { $0.name == "quality" }?.value, "auto")
        XCTAssertEqual(app.player.selectedQuality, "auto")
        XCTAssertNotNil(app.player.qualityNotice, "The actual player must disclose why this request differs from the saved choice.")
        XCTAssertEqual(app.playbackPreferences.preferredQualityID, "full_hd")
        XCTAssertEqual(PlaybackPreferences(defaults: fixture.defaults).preferredQualityID, "full_hd")
        XCTAssertNil(app.library.capabilities)
    }

    func testAccountChangeDuringHeldSavedProfileLookupCannotFetchItemOrLaunchPlayback() async throws {
        let fixture = try SavedCollectionFixture()
        addTeardownBlock { await fixture.cleanUp() }
        try fixture.enableRemoteMovie(includeFullHD: true, holdProfileFor: "first-viewer")
        let address = try await fixture.server.start()
        let app = try await fixture.app(address: address, account: "first-viewer")
        let key = MovieLibraryKey(connection: try XCTUnwrap(app.client.connection), mediaID: "73001")
        app.playbackPreferences.preferredQualityID = "full_hd"
        let pending = Task { try await app.playSaved(key) }
        await waitFor("The first account's real profile response is held by the HTTP server") { fixture.server.heldProfileCount == 1 }
        let connected = await app.connect(serverAddress: address, username: "second-viewer", password: "synthetic-secret")
        XCTAssertTrue(connected)
        XCTAssertEqual(app.client.connection?.username, "second-viewer")
        fixture.server.releaseProfiles()
        try await pending.value
        XCTAssertNil(app.player.player.currentItem)
        XCTAssertFalse(app.player.isPresented)
        XCTAssertFalse(fixture.server.requests.contains { $0.target.hasPrefix("/api/web/item/") || $0.target.hasPrefix("/web/media/") })
        let profileRequests = fixture.server.requests.filter { $0.target.hasPrefix("/api/web/library") && $0.target.contains("limit=1") }
        XCTAssertFalse(profileRequests.isEmpty)
        XCTAssertTrue(profileRequests.allSatisfy { $0.account == "first-viewer" }, "A suspended saved request must never adopt replacement credentials.")
        XCTAssertTrue(fixture.server.requests.contains { $0.target.hasPrefix("/api/web/library") && $0.account == "second-viewer" },
                      "The replacement account must itself have completed a real authenticated connection probe.")
    }

    private func waitFor(_ description: String, _ condition: @escaping () -> Bool) async {
        let reached = expectation(description: description)
        let polling = Task {
            for _ in 0..<500 {
                if condition() { reached.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await fulfillment(of: [reached], timeout: 6)
        polling.cancel()
    }
}

@MainActor
private final class SavedCollectionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("saved-collections-\(UUID().uuidString)")
    let suite = "saved-collections.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: AppSettings
    let server: SavedCollectionHTTPServer
    private var apps: [AppModel] = []

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults, secrets: SavedCollectionSecrets())
        var page = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ServerModelDecodingTests.libraryJSONForHTTP.utf8)) as? [String: Any])
        page["entries"] = []
        page["total"] = 0
        page["has_more"] = false
        server = try SavedCollectionHTTPServer(emptyLibrary: JSONSerialization.data(withJSONObject: page))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func install(address: String, account: String, title: String = "The Glass Compass", catalogDuration: Int = 6) async throws -> DownloadRecord {
        let source = try XCTUnwrap(Bundle(for: SavedCollectionIntegrationTests.self).url(forResource: "synthetic-native-tracks", withExtension: "mp4"))
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("downloads"))
        let temporary = root.appendingPathComponent("incoming-\(UUID().uuidString).mp4")
        let metadata = DownloadTaskMetadata(recordID: UUID(), serverOrigin: address, mediaID: "73001", title: title,
            kind: .original, fileExtension: "mp4", durationSeconds: catalogDuration, resolution: "320x180",
            accountUsername: account, movie: MovieMetadata(mediaID: "73001", title: title, durationSeconds: Double(catalogDuration)))
        return try await Task.detached {
            try FileManager.default.copyItem(at: source, to: temporary)
            return try store.install(temporaryURL: temporary, metadata: metadata)
        }.value
    }

    func enableRemoteMovie(includeFullHD: Bool, holdProfileFor: String? = nil) throws {
        var page = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ServerModelDecodingTests.libraryJSONForHTTP.utf8)) as? [String: Any])
        var capabilities = try XCTUnwrap(page["capabilities"] as? [String: Any])
        var profiles = try XCTUnwrap(capabilities["quality_profiles"] as? [[String: Any]])
        if includeFullHD {
            profiles.append(["id": "full_hd", "label": "Full HD", "max_width": 1920,
                "max_height": 1080, "expected_bandwidth_kbps": 5000, "automatic_fallback": false])
        }
        capabilities["quality_profiles"] = profiles
        page["capabilities"] = capabilities
        page["entries"] = []
        page["total"] = 0
        page["has_more"] = false
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)) as? [String: Any])
        var item = try XCTUnwrap(envelope["item"] as? [String: Any])
        item["id"] = "73001"
        item["title"] = "The Glass Compass"
        item["duration_seconds"] = 6
        item["source_url"] = "/web/media/73001.mp4?mode=direct"
        item["fallback_url"] = "/web/media/73001.mp4"
        item["download_url"] = "/web/download/73001"
        item["art_url"] = NSNull()
        item["captions"] = []
        item["chapters"] = []
        envelope["id"] = "73001"
        envelope["item"] = item
        envelope["chapters"] = []
        server.configureRemote(library: try JSONSerialization.data(withJSONObject: page),
            item: try JSONSerialization.data(withJSONObject: envelope), holdProfileFor: holdProfileFor)
    }

    func app(address: String, account: String?) async throws -> AppModel {
        if let account { _ = try settings.save(serverAddress: address, username: account, password: "synthetic-secret") }
        let downloads = DownloadManager(store: DownloadManifestStore(rootDirectory: root.appendingPathComponent("downloads")),
            sessionIdentifier: "saved-collections.\(UUID().uuidString)", sessionConfiguration: .ephemeral)
        let app = AppModel(settings: settings, client: RustyDLNAClient(configuration: .ephemeral), downloads: downloads,
            movieCache: MovieMetadataCache(directory: root.appendingPathComponent("metadata")),
            userLibrary: UserLibraryStore(directory: root.appendingPathComponent("library"), legacyProgressStore: PlaybackProgressStore(defaults: defaults)),
            playbackPreferences: PlaybackPreferences(defaults: defaults))
        apps.append(app)
        await downloads.waitForPendingOperations()
        await app.userLibrary.waitUntilRestored()
        await app.movieCache.waitUntilRestored()
        return app
    }

    func cleanUp() async {
        for app in apps {
            app.player.stop()
            try? await app.userLibrary.flush()
            await app.movieCache.waitForPendingWrites()
            await app.downloads.waitForPendingOperations()
        }
        apps.removeAll()
        server.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class SavedCollectionSecrets: SecretStoring {
    private var values: [String: String] = [:]
    func read(account: String) throws -> String? { values[account] }
    func write(_ value: String, account: String) throws { values[account] = value }
    func remove(account: String) throws { values[account] = nil }
}

/// A real loopback listener observes all HTTP, including accidental AVPlayer
/// requests that would bypass a URLProtocol installed only on the API client.
private final class SavedCollectionHTTPServer: @unchecked Sendable {
    struct Request {
        let target: String
        let account: String?
        var authenticated: Bool { account != nil }
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "synthetic.saved-collections.http")
    private let lock = NSLock()
    private var library: Data
    private var item: Data?
    private var holdProfileAccount: String?
    private var heldProfiles: [() -> Void] = []
    private var captured: [Request] = []
    private var connections: [NWConnection] = []
    private var startup: CheckedContinuation<String, Error>?
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return captured }
    var heldProfileCount: Int { lock.lock(); defer { lock.unlock() }; return heldProfiles.count }

    init(emptyLibrary: Data) throws {
        library = emptyLibrary
        listener = try NWListener(using: .tcp, on: .any)
    }
    func configureRemote(library: Data, item: Data, holdProfileFor: String?) {
        lock.lock(); defer { lock.unlock() }
        self.library = library
        self.item = item
        holdProfileAccount = holdProfileFor
    }
    func releaseProfiles() {
        lock.lock()
        let responses = heldProfiles
        heldProfiles.removeAll()
        holdProfileAccount = nil
        lock.unlock()
        responses.forEach { $0() }
    }
    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); startup = continuation; lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                let result: Result<String, Error>
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    result = .success("http://127.0.0.1:\(port.rawValue)")
                case .failed(let error): result = .failure(error)
                default: return
                }
                lock.lock(); let continuation = startup; startup = nil; lock.unlock()
                continuation?.resume(with: result)
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                lock.lock(); connections.append(connection); lock.unlock()
                connection.start(queue: queue)
                receive(connection, bytes: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        listener.cancel()
        lock.lock(); let active = connections; connections.removeAll(); lock.unlock()
        active.forEach { $0.cancel() }
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, ended, error in
            guard let self, error == nil else { connection.cancel(); return }
            var bytes = bytes
            if let data { bytes.append(data) }
            guard bytes.count <= 64 * 1_024 else { connection.cancel(); return }
            guard let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") else {
                if ended { connection.cancel() } else { receive(connection, bytes: bytes) }
                return
            }
            let lines = text.components(separatedBy: "\r\n")
            let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }?
                .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
            let account = ["first-viewer", "second-viewer"].first {
                authorization == "Basic " + Data("\($0):synthetic-secret".utf8).base64EncodedString()
            }
            lock.lock()
            captured.append(Request(target: target, account: account))
            let library = self.library, item = self.item
            let holdProfile = account != nil && account == holdProfileAccount
                && target.hasPrefix("/api/web/library")
                && URLComponents(string: target)?.queryItems?.contains(where: { $0.name == "limit" && $0.value == "1" }) == true
            lock.unlock()
            let authenticated = account != nil
            let isLibrary = target.hasPrefix("/api/web/library")
            let isItem = target == "/api/web/item/73001" && item != nil
            // Hold a genuine prepared GET while the test observes its quality
            // decision. No fabricated playable response or decoder result is
            // supplied; teardown cancels the bounded in-flight connection.
            if authenticated, item != nil, target.hasPrefix("/web/media/73001.m3u8") { return }
            let status = authenticated ? (isLibrary || isItem ? 200 : 404) : 401
            let body = authenticated ? (isLibrary ? library : isItem ? item ?? Data() : Data()) : Data()
            var response = Data("HTTP/1.1 \(status) Synthetic\r\nContent-Length: \(body.count)\r\nConnection: close\r\nContent-Type: application/json\r\n".utf8)
            if !authenticated { response.append(Data("WWW-Authenticate: Basic realm=\"Synthetic Saved Library\"\r\n".utf8)) }
            response.append(Data("\r\n".utf8)); response.append(body)
            let send = { connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() }) }
            if holdProfile {
                lock.lock(); heldProfiles.append(send); lock.unlock()
            } else { send() }
        }
    }
}
