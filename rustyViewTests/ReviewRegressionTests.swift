import Combine
import Foundation
import UIKit
import XCTest
@testable import rustyView

@MainActor
final class ReviewRegressionTests: XCTestCase {
    override func tearDown() {
        ReviewHTTPProtocol.handler = nil
        super.tearDown()
    }

    func testConnectionRejectsCredentialsInAddresses() throws {
        var address = try XCTUnwrap(URLComponents(string: "https://media.example.test"))
        address.user = "viewer"
        address.password = "synthetic-secret"
        XCTAssertThrowsError(try ServerConnection(
            serverAddress: try XCTUnwrap(address.string),
            username: "viewer", password: "secret"
        ))
        let connection = try connection()
        address.path = "/art.jpg"
        XCTAssertThrowsError(try connection.resolve(serverPath: try XCTUnwrap(address.string)))
    }

    func testSavedPasswordIsReusedOnlyForSameOriginAndAccount() throws {
        let suite = "ReviewSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, secrets: ReviewSecrets())
        _ = try settings.save(serverAddress: "https://media.example.test", username: "viewer", password: "saved-secret")
        XCTAssertEqual(try settings.passwordForConnection(serverAddress: "https://media.example.test:443/", username: "viewer", enteredPassword: ""), "saved-secret")
        XCTAssertEqual(try settings.passwordForConnection(serverAddress: "https://second.example.test", username: "viewer", enteredPassword: ""), "")
        XCTAssertEqual(try settings.passwordForConnection(serverAddress: "https://media.example.test", username: "another", enteredPassword: ""), "")
    }

    func testKeychainFailureDoesNotCommitCandidateConnectionOrLibrary() async throws {
        let suite = "ReviewConnection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = ReviewSecrets()
        let settings = AppSettings(defaults: defaults, secrets: secrets)
        let saved = try settings.save(serverAddress: "https://media.example.test", username: "viewer", password: "saved-secret")
        secrets.failWrites = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = DownloadManager(store: DownloadManifestStore(rootDirectory: root), sessionIdentifier: "review.\(UUID().uuidString)")
        let model = AppModel(settings: settings, client: try client(), downloads: downloads)
        ReviewHTTPProtocol.handler = { _, respond in
            respond(200, Data(ServerModelDecodingTests.libraryJSONForHTTP.utf8))
        }
        try await model.library.reload()
        let previousEntries = model.library.entries
        let succeeded = await model.connect(serverAddress: "https://second.example.test", username: "another", password: "new-secret")
        XCTAssertFalse(succeeded)
        XCTAssertNotNil(model.connectionError)
        XCTAssertEqual(model.client.connection, saved)
        XCTAssertEqual(model.library.entries, previousEntries)
        XCTAssertEqual(try settings.connection(), saved)
        secrets.failWrites = false
        let retrySucceeded = await model.connect(serverAddress: "https://second.example.test", username: "another", password: "new-secret")
        XCTAssertTrue(retrySucceeded)
        XCTAssertNil(model.connectionError)
        XCTAssertEqual(model.client.connection?.baseURL.host, "second.example.test")
        XCTAssertEqual(model.library.entries, previousEntries, "The verified first page should be available immediately after connection commit")
        XCTAssertFalse(model.library.isLoading)
    }

    func testClosingUnstartedOfflinePlaybackPreservesResumePosition() throws {
        let suite = "ReviewResume.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let progress = PlaybackProgressStore(defaults: defaults)
        let record = DownloadRecord(id: UUID(), serverOrigin: "https://media.example.test", mediaID: "42", title: "The Tin Comet", kind: .compatible, fileName: "missing.mp4", byteCount: 100, completedAt: Date(), durationSeconds: 3600, resolution: nil, artworkPath: nil)
        progress.update(serverOrigin: record.serverOrigin, mediaID: record.mediaID, position: 905, duration: 3600)
        let player = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral), progressStore: progress)
        player.playLocal(record: record, url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        player.stop()
        player.stop()
        XCTAssertEqual(progress.resumePosition(serverOrigin: record.serverOrigin, mediaID: record.mediaID), 905)
    }

    func testCancelledDownloadCannotBeInstalledOrPublishedByLateCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        let delegate = DownloadSessionDelegate(store: store)
        let metadata = DownloadTaskMetadata(recordID: UUID(), serverOrigin: "https://media.example.test", mediaID: "42", title: "The Tin Comet", kind: .compatible, fileExtension: "mp4", durationSeconds: 300, resolution: nil)
        let incoming = root.appendingPathComponent("incoming")
        try OfflineMediaFixture.validData().write(to: incoming)
        try delegate.discard(taskIdentifier: 1)
        XCTAssertNil(try delegate.install(temporaryURL: incoming, metadata: metadata, taskIdentifier: 1))
        XCTAssertTrue(try store.load().records.isEmpty)

        _ = try delegate.install(temporaryURL: incoming, metadata: metadata, taskIdentifier: 2)
        try delegate.discard(taskIdentifier: 2)
        XCTAssertFalse(delegate.acceptCompletion(taskIdentifier: 2))
        XCTAssertTrue(try store.load().records.isEmpty)
    }

    func testFailedManifestDeletionRestoresPlayableFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileManager = ReviewFileManager()
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"), fileManager: fileManager)
        let incoming = root.appendingPathComponent("incoming")
        let payload = try OfflineMediaFixture.validData()
        try payload.write(to: incoming)
        let metadata = DownloadTaskMetadata(recordID: UUID(), serverOrigin: "https://media.example.test", mediaID: "42", title: "The Tin Comet", kind: .compatible, fileExtension: "mp4", durationSeconds: 300, resolution: nil)
        let record = try store.install(temporaryURL: incoming, metadata: metadata)
        fileManager.failDirectoryPreparation = true
        XCTAssertThrowsError(try store.delete(record))
        XCTAssertEqual(try store.load().records, [record])
        XCTAssertEqual(try Data(contentsOf: store.localURL(for: record)), payload)
    }

    func testUnknownSchemaIsReportedBeforeDecodingChangedFields() async throws {
        let client = try client()
        ReviewHTTPProtocol.handler = { request, respond in
            respond(200, Data(#"{"schema_version":99,"replacement_catalog":[]}"#.utf8))
        }
        do {
            _ = try await client.library(LibraryRequest())
            XCTFail("An incompatible API must fail")
        } catch {
            XCTAssertEqual(error as? RustyDLNAError, .schemaMismatch(99))
        }
    }

    func testOldSearchFailureCannotOverwriteNewSearchSuccess() async throws {
        let model = LibraryModel(client: try client())
        let started = expectation(description: "Old request reached transport")
        var release: ((Int, Data) -> Void)?
        ReviewHTTPProtocol.handler = { request, respond in
            if URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "q" })?.value == "old" {
                Task { @MainActor in release = respond; started.fulfill() }
            } else {
                respond(200, Data(ServerModelDecodingTests.libraryJSONForHTTP.utf8))
            }
        }
        model.query = "old"
        let old = Task { await model.reloadReportingErrors() }
        await fulfillment(of: [started], timeout: 3)
        model.query = "new"
        await model.reloadReportingErrors()
        release?(503, Data())
        await old.value
        XCTAssertEqual(model.entries.first?.id, "42001")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testClearingLibraryInvalidatesInFlightLoadingState() async throws {
        let model = LibraryModel(client: try client())
        let started = expectation(description: "Request reached transport")
        var release: ((Int, Data) -> Void)?
        ReviewHTTPProtocol.handler = { _, respond in
            Task { @MainActor in release = respond; started.fulfill() }
        }
        let pending = Task { await model.reloadReportingErrors() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(model.isLoading)
        model.clear()
        release?(200, Data(ServerModelDecodingTests.libraryJSONForHTTP.utf8))
        await pending.value
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testCatalogChangeDuringPagingIsVisibleWithoutDiscardingLoadedMovies() async throws {
        let model = LibraryModel(client: try client())
        ReviewHTTPProtocol.handler = { request, respond in
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "offset" })?.value
            if offset == "0" {
                respond(200, Data(ServerModelDecodingTests.libraryJSONForHTTP.utf8))
            } else {
                respond(409, Data(#"{"schema_version":2,"error":{"code":"catalog_changed","message":"Refresh the library.","recoverable":true}}"#.utf8))
            }
        }
        try await model.reload()
        await model.loadMoreIfNeeded(after: try XCTUnwrap(model.entries.last))
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testArtworkWithSamePathOnDifferentServersLoadsDifferentBytes() async throws {
        let client = try client()
        let path = "/art/\(UUID().uuidString).png"
        let red = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let blue = UIGraphicsImageRenderer(size: CGSize(width: 3, height: 3)).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        }
        ReviewHTTPProtocol.handler = { request, respond in
            respond(200, request.url?.host == "media.example.test" ? red : blue)
        }
        let first = ArtworkModel()
        let firstLoaded = expectation(description: "First artwork loaded")
        let firstObserver = first.$image.compactMap { $0 }.prefix(1).sink { _ in firstLoaded.fulfill() }
        first.load(path: path, client: client)
        await fulfillment(of: [firstLoaded], timeout: 3)
        client.configure(try connection(address: "https://second.example.test"))
        let second = ArtworkModel()
        let secondLoaded = expectation(description: "Second artwork loaded")
        let secondObserver = second.$image.compactMap { $0 }.prefix(1).sink { _ in secondLoaded.fulfill() }
        second.load(path: path, client: client)
        await fulfillment(of: [secondLoaded], timeout: 3)
        XCTAssertNotEqual(first.image?.size, second.image?.size)
        withExtendedLifetime([firstObserver, secondObserver]) {}
    }

    func testCaptionOffWinsOverDelayedCaptionResponse() async throws {
        let client = RustyDLNAClient(configuration: configuration())
        let player = PlaybackModel(client: client)
        let item = try JSONDecoder().decode(ItemResponse.self, from: Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)).item
        // An unconfigured client makes asset creation fail before AVFoundation can access the network.
        player.play(item)
        client.configure(try connection())
        let started = expectation(description: "Caption request reached transport")
        var release: ((Int, Data) -> Void)?
        ReviewHTTPProtocol.handler = { _, respond in
            Task { @MainActor in release = respond; started.fulfill() }
        }
        let pending = Task { await player.selectCaption(0) }
        await fulfillment(of: [started], timeout: 3)
        await player.selectCaption(nil)
        release?(200, Data("WEBVTT\n\n00:00.000 --> 00:10.000\nInvented caption\n".utf8))
        await pending.value
        XCTAssertNil(player.selectedCaptionIndex)
        XCTAssertNil(player.currentSubtitle)
        player.stop()
    }

    func testManifestDoesNotAcceptSymbolicLinksAsOfflineMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let incoming = root.appendingPathComponent("incoming")
        try OfflineMediaFixture.validData().write(to: incoming)
        let metadata = DownloadTaskMetadata(recordID: UUID(), serverOrigin: "https://media.example.test", mediaID: "42", title: "The Tin Comet", kind: .compatible, fileExtension: "mp4", durationSeconds: 300, resolution: nil)
        let record = try store.install(temporaryURL: incoming, metadata: metadata)
        let installed = store.localURL(for: record)
        try FileManager.default.removeItem(at: installed)
        // Match the link's own size so size-only validation cannot accidentally pass this test.
        let outside = root.appendingPathComponent("outside")
        try Data(repeating: 9, count: 64).write(to: outside)
        try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: outside)
        let size = (try FileManager.default.attributesOfItem(atPath: installed.path)[.size] as! NSNumber).int64Value
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: store.stateStore.stateURL)) as! [String: Any]
        var records = manifest["records"] as! [[String: Any]]
        records[0]["byteCount"] = size
        manifest["records"] = records
        try JSONSerialization.data(withJSONObject: manifest).write(to: store.stateStore.stateURL)
        XCTAssertTrue(try store.loadValidated().records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside), Data(repeating: 9, count: 64))
    }

    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewHTTPProtocol.self]
        return configuration
    }

    private func client() throws -> RustyDLNAClient {
        let client = RustyDLNAClient(configuration: configuration())
        client.configure(try connection())
        return client
    }

    private func connection(address: String = "https://media.example.test") throws -> ServerConnection {
        try ServerConnection(serverAddress: address, username: "viewer", password: "synthetic-secret")
    }
}

private final class ReviewSecrets: SecretStoring {
    var value: String?
    var failWrites = false
    func read(account: String) throws -> String? { value }
    func write(_ value: String, account: String) throws {
        if failWrites { throw KeychainError.invalidData }
        self.value = value
    }
    func remove(account: String) throws { value = nil }
}

private final class ReviewFileManager: FileManager, @unchecked Sendable {
    var failDirectoryPreparation = false
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil) throws {
        if failDirectoryPreparation { throw CocoaError(.fileWriteNoPermission) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

private final class ReviewHTTPProtocol: URLProtocol {
    static var handler: ((URLRequest, @escaping (Int, Data) -> Void) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.handler?(request) { [self] status, data in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
