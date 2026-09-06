import Foundation
import Security
import XCTest
@testable import rustyView

@MainActor
final class ConnectionRecoveryTests: XCTestCase {
    override func tearDown() {
        RecoveryHTTPProtocol.handler = nil
        RecoveryHTTPProtocol.onStop = nil
        super.tearDown()
    }

    func testMissingAndUnavailableCredentialsRemainDistinctWithoutDeletingConnectionIntent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let saved = try fixture.settings.save(serverAddress: "https://media.example.test", username: "viewer", password: "synthetic-secret")
        fixture.secrets.value = nil
        let missing = AppSettings(defaults: fixture.defaults, secrets: fixture.secrets)
        XCTAssertNil(try missing.savedConnection())
        XCTAssertEqual(missing.credentialAvailability, .missing)
        XCTAssertEqual(missing.serverAddress, saved.baseURL.absoluteString)

        fixture.secrets.readError = KeychainError.unexpectedStatus(errSecInteractionNotAllowed)
        let unavailable = AppSettings(defaults: fixture.defaults, secrets: fixture.secrets)
        XCTAssertThrowsError(try unavailable.savedConnection()) { error in
            XCTAssertEqual(UserFacingError(error).category, .credentialsUnavailable)
        }
        XCTAssertEqual(unavailable.credentialAvailability, .unavailable)
        XCTAssertEqual(unavailable.username, saved.username)
        XCTAssertEqual(fixture.defaults.string(forKey: "serverAddress"), saved.baseURL.absoluteString)
        let reads = fixture.secrets.readCount
        for _ in 0..<20 {
            XCTAssertFalse(unavailable.hasSavedConnection)
            XCTAssertFalse(unavailable.canReuseSavedPassword(serverAddress: saved.baseURL.absoluteString, username: saved.username))
        }
        XCTAssertEqual(fixture.secrets.readCount, reads, "Rendering connection properties must not repeatedly query Keychain")
        fixture.secrets.readError = nil
        fixture.secrets.value = saved.password
        XCTAssertEqual(try unavailable.savedConnection(), saved)
        XCTAssertEqual(unavailable.credentialAvailability, .available)
        XCTAssertTrue(unavailable.canReuseSavedPassword(serverAddress: "https://MEDIA.example.test:443/", username: "viewer"))
        XCTAssertFalse(unavailable.canReuseSavedPassword(serverAddress: "https://different.example.test", username: "viewer"))
        XCTAssertFalse(unavailable.canReuseSavedPassword(serverAddress: saved.baseURL.absoluteString, username: "another"))
    }

    func testUnavailableSavedPasswordStopsTheProbeBeforeAnyHTTPOrConnectionCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let saved = try fixture.settings.save(serverAddress: "https://media.example.test", username: "viewer", password: "synthetic-secret")
        let model = await fixture.model()
        fixture.secrets.readError = KeychainError.unexpectedStatus(errSecNotAvailable)
        let forbidden = expectation(description: "No blank-password probe")
        forbidden.isInverted = true
        RecoveryHTTPProtocol.handler = { _, _ in forbidden.fulfill() }
        let writes = fixture.secrets.writeCount
        let connected = await model.connect(serverAddress: saved.baseURL.absoluteString, username: saved.username, password: "")
        XCTAssertFalse(connected)
        await fulfillment(of: [forbidden], timeout: 0.1)
        XCTAssertEqual(model.connectionError?.category, .credentialsUnavailable)
        XCTAssertEqual(model.client.connection, saved)
        XCTAssertTrue(model.isConfigured)
        XCTAssertEqual(fixture.secrets.writeCount, writes)
        XCTAssertEqual(fixture.settings.serverAddress, saved.baseURL.absoluteString)
    }

    func testEmptyPasswordIsAFieldErrorBeforeAnyNetworkProbe() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = await fixture.model()
        let forbidden = expectation(description: "No empty-password probe")
        forbidden.isInverted = true
        RecoveryHTTPProtocol.handler = { _, _ in forbidden.fulfill() }
        let connected = await model.connect(serverAddress: "https://media.example.test", username: "viewer", password: "")
        XCTAssertFalse(connected)
        await fulfillment(of: [forbidden], timeout: 0.1)
        XCTAssertEqual(model.connectionError?.category, .invalidInput)
        XCTAssertEqual(model.connectionError?.field, .password)
        XCTAssertNil(model.client.connection)
        XCTAssertEqual(fixture.secrets.writeCount, 0)
    }

    func testFailedForgetPreservesLiveLibraryAccountAndPasswordUntilDeletionSucceeds() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let saved = try fixture.settings.save(serverAddress: "https://media.example.test", username: "viewer", password: "synthetic-secret")
        let model = await fixture.model()
        RecoveryHTTPProtocol.handler = { _, reply in reply(.success((200, Data(ServerModelDecodingTests.libraryJSONForHTTP.utf8)))) }
        try await model.library.reload()
        let entries = model.library.entries
        XCTAssertFalse(entries.isEmpty)
        fixture.secrets.removeError = KeychainError.unexpectedStatus(errSecInteractionNotAllowed)
        model.disconnect()
        XCTAssertTrue(model.isConfigured)
        XCTAssertEqual(model.client.connection, saved)
        XCTAssertEqual(model.library.entries, entries)
        XCTAssertEqual(try fixture.settings.savedConnection(), saved)
        XCTAssertEqual(model.presentedError?.category, .credentialsUnavailable)
        fixture.secrets.removeError = nil
        model.disconnect()
        XCTAssertFalse(model.isConfigured)
        XCTAssertNil(model.client.connection)
        XCTAssertTrue(model.library.entries.isEmpty)
        XCTAssertNil(try fixture.settings.savedConnection())
        XCTAssertEqual(fixture.settings.credentialAvailability, .missing)
    }

    func testCancellingAnInFlightProbeCannotSaveItsLateReplyOrClearANewerConnection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = await fixture.model()
        let requested = expectation(description: "First probe started")
        let stopped = expectation(description: "URLSession cancelled first probe")
        var replyLater: RecoveryHTTPProtocol.Reply?
        RecoveryHTTPProtocol.handler = { _, reply in
            Task { @MainActor in
                replyLater = reply
                requested.fulfill()
            }
        }
        RecoveryHTTPProtocol.onStop = { stopped.fulfill() }
        let first = Task { await model.connect(serverAddress: "https://first.example.test", username: "viewer", password: "first-secret") }
        await fulfillment(of: [requested], timeout: 2)
        model.cancelConnectionAttempt()
        first.cancel()
        await fulfillment(of: [stopped], timeout: 2)
        let firstConnected = await first.value
        XCTAssertFalse(firstConnected)
        XCTAssertNil(model.connectionError)
        XCTAssertEqual(fixture.secrets.writeCount, 0)
        RecoveryHTTPProtocol.onStop = nil
        RecoveryHTTPProtocol.handler = { _, reply in reply(.success((200, Data(ServerModelDecodingTests.libraryJSONForHTTP.utf8)))) }
        let secondConnected = await model.connect(serverAddress: "https://second.example.test", username: "another", password: "second-secret")
        XCTAssertTrue(secondConnected)
        replyLater?(.success((200, Data(ServerModelDecodingTests.libraryJSONForHTTP.utf8))))
        XCTAssertEqual(model.client.connection?.baseURL.host, "second.example.test")
        XCTAssertEqual(model.client.connection?.username, "another")
        XCTAssertEqual(fixture.secrets.value, "second-secret")
        XCTAssertEqual(fixture.secrets.writeCount, 1)
        XCTAssertNil(model.connectionError)
    }

    func testHTTPAndTransportFailuresExposeDistinctRecoveryAfterRealClientDecoding() async throws {
        let client = Self.client()
        client.configure(try ServerConnection(serverAddress: "https://media.example.test", username: "viewer", password: "synthetic-secret"))
        let cases: [(Result<(Int, Data), Error>, UserFacingError.Category, RecoveryAction)] = [
            (.success((401, Data())), .authentication, .editConnection),
            (.success((503, Data())), .transient, .retry),
            (.success((200, Data(#"{"schema_version":99,"incompatible_shape":true}"#.utf8))), .incompatibleServer, .compatibilityHelp),
            (.failure(URLError(.notConnectedToInternet)), .offline, .watchDownloads),
            (.failure(URLError(.serverCertificateUntrusted)), .transportSecurity, .editConnection),
        ]
        for (response, category, action) in cases {
            RecoveryHTTPProtocol.handler = { _, reply in reply(response) }
            do {
                _ = try await client.library(LibraryRequest())
                XCTFail("The fixture must fail at the actual URL loading/decoding boundary")
            } catch {
                let failure = UserFacingError(error)
                XCTAssertEqual(failure.category, category)
                XCTAssertTrue(failure.recoveryActions(hasDownloads: true).contains(action))
                if category == .authentication || category == .transportSecurity || category == .incompatibleServer {
                    XCTAssertFalse(failure.recoveryActions().contains(.retry))
                }
            }
        }
    }

    private static func client() -> RustyDLNAClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryHTTPProtocol.self]
        return RustyDLNAClient(configuration: configuration)
    }

    @MainActor private struct Fixture {
        let suite = "ConnectionRecovery.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("connection-recovery-\(UUID().uuidString)")
        let defaults: UserDefaults
        let secrets = RecoverySecrets()
        let settings: AppSettings

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            settings = AppSettings(defaults: defaults, secrets: secrets)
        }

        func model() async -> AppModel {
            let downloads = DownloadManager(store: DownloadManifestStore(rootDirectory: root),
                                            sessionIdentifier: "recovery-tests.\(UUID().uuidString)", sessionConfiguration: .ephemeral)
            let model = AppModel(settings: settings, client: ConnectionRecoveryTests.client(), downloads: downloads,
                                 movieCache: MovieMetadataCache(directory: root.appendingPathComponent("metadata")))
            await downloads.waitForPendingOperations()
            return model
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class RecoverySecrets: SecretStoring {
    var value: String?
    var readError: Error?
    var removeError: Error?
    var readCount = 0
    var writeCount = 0
    func read(account: String) throws -> String? {
        readCount += 1
        if let readError { throw readError }
        return value
    }
    func write(_ value: String, account: String) throws { writeCount += 1; self.value = value }
    func remove(account: String) throws {
        if let removeError { throw removeError }
        value = nil
    }
}

private final class RecoveryHTTPProtocol: URLProtocol, @unchecked Sendable {
    typealias Reply = (Result<(Int, Data), Error>) -> Void
    static var handler: ((URLRequest, @escaping Reply) -> Void)?
    static var onStop: (() -> Void)?
    private let lock = NSRecursiveLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.handler?(request) { [self] result in
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else { return }
            switch result {
            case .success(let (status, body)):
                guard let url = request.url,
                      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }
    override func stopLoading() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        Self.onStop?()
    }
}
