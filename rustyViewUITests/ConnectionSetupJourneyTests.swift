import Network
import XCTest

@MainActor
final class ConnectionSetupJourneyTests: XCTestCase {
    private var app: XCUIApplication!
    private var server: SetupHTTPServer?

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment = ["RUSTYVIEW_TEST_NAMESPACE": "setup-\(UUID().uuidString.lowercased())"]
        app.launch()
        XCTAssertTrue(app.buttons["connection-submit"].waitForExistence(timeout: 10))
    }

    override func tearDown() {
        app?.terminate()
        server?.stop()
        server = nil
        app = nil
    }

    func testFieldValidationAndKeyboardProgressionDoNotSubmitInvalidCredentials() {
        app.buttons["connection-submit"].tap()
        for field in ["server", "username", "password"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "connection-\(field)-error").firstMatch.exists)
        }
        let address = app.textFields["connection-server"]
        address.tap()
        address.typeText("http://insecure.example.test\n")
        app.typeText("viewer\n")
        app.typeText("synthetic-password")
        XCTAssertEqual(app.textFields["connection-username"].value as? String, "viewer",
                       "Next must advance from the address through username to Password")
        XCTAssertTrue(app.keyboards.buttons["Go"].exists)
        app.keyboards.buttons["Go"].tap()
        let error = app.descendants(matching: .any).matching(identifier: "connection-server-error").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 2))
        XCTAssertTrue(error.label.contains("HTTPS"))
        XCTAssertTrue(app.buttons["connection-submit"].isEnabled)
        XCTAssertFalse(app.buttons["connection-cancel-attempt"].exists)
    }

    func testCancelHeldProbeThenConnectAndRelaunchWithTheSameSavedAccount() throws {
        let fixture = try SetupHTTPServer()
        server = fixture
        let address = app.textFields["connection-server"]
        address.tap()
        address.typeText(fixture.address + "\n")
        app.typeText("viewer\n")
        app.typeText("synthetic-password")
        app.keyboards.buttons["Go"].tap()
        let cancel = app.buttons["connection-cancel-attempt"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        let requested = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in fixture.authorizedRequests == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [requested], timeout: 3), .completed)
        XCTAssertFalse(app.buttons["connection-submit"].isEnabled)
        cancel.tap()
        XCTAssertTrue(app.buttons["connection-submit"].isEnabled)
        XCTAssertFalse(cancel.exists)
        fixture.releaseAndReplyImmediately()
        let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in fixture.repliesAttempted >= 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [released], timeout: 3), .completed)
        XCTAssertTrue(app.buttons["connection-submit"].exists, "A cancelled probe's late response must not commit the connection")

        app.buttons["connection-submit"].tap()
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["connection-submit"])
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 8), .completed)
        XCTAssertEqual(fixture.authorizedRequests, 2)
        XCTAssertEqual(fixture.unauthorizedRequests, 0)
        XCTAssertTrue(app.tabBars.buttons["Library"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["connection-submit"].exists,
                       "The same isolated test namespace must restore its saved Keychain account after relaunch")
    }
}

private final class SetupHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "setup-ui.http")
    private let lock = NSLock()
    private var authorized = 0
    private var unauthorized = 0
    private var attempted = 0
    private var repliesImmediately = false
    private var pending: [NWConnection] = []
    private var connections: [NWConnection] = []
    private(set) var address = ""

    var authorizedRequests: Int { lock.lock(); defer { lock.unlock() }; return authorized }
    var unauthorizedRequests: Int { lock.lock(); defer { lock.unlock() }; return unauthorized }
    var repliesAttempted: Int { lock.lock(); defer { lock.unlock() }; return attempted }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): startupError = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.read(connection, accumulated: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success else { throw NSError(domain: "SyntheticSetup", code: 1) }
        if let startupError { throw startupError }
        guard let port = listener.port else { throw NSError(domain: "SyntheticSetup", code: 2) }
        address = "http://127.0.0.1:\(port.rawValue)"
    }

    func releaseAndReplyImmediately() {
        queue.async { [self] in
            repliesImmediately = true
            let held = pending
            pending = []
            for connection in held { reply(connection, authorized: true) }
        }
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in
            for connection in connections { connection.cancel() }
            connections = []
            pending = []
        }
    }

    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, ended, error in
            guard let self else { connection.cancel(); return }
            var data = accumulated
            if let bytes { data.append(bytes) }
            if let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") {
                let expected = "Basic " + Data("viewer:synthetic-password".utf8).base64EncodedString()
                let authorized = text.components(separatedBy: "\r\n").contains {
                    $0.lowercased().hasPrefix("authorization:") && $0.split(separator: ":", maxSplits: 1).last?
                        .trimmingCharacters(in: .whitespaces) == expected
                }
                self.lock.lock()
                if authorized { self.authorized += 1 } else { self.unauthorized += 1 }
                self.lock.unlock()
                if !authorized || self.repliesImmediately { self.reply(connection, authorized: authorized) }
                else { self.pending.append(connection) }
            } else if ended || error != nil || data.count > 65_536 {
                connection.cancel()
            } else { self.read(connection, accumulated: data) }
        }
    }

    private func reply(_ connection: NWConnection, authorized: Bool) {
        lock.lock(); attempted += 1; lock.unlock()
        let body = Data((authorized ? Self.emptyLibrary : "{}").utf8)
        let header = "HTTP/1.1 \(authorized ? 200 : 401) Synthetic\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static let emptyLibrary = #"""
    {"schema_version":2,"generation":1,"server_name":"Synthetic Setup Library","root_folder_id":"root",
     "capabilities":{"transcoding":true,"captions":true,"quality_profiles":[]},"library_state":"ready",
     "view":"library","folder":null,"breadcrumbs":[],"offset":0,"limit":60,"total":0,"has_more":false,
     "query":"","sort":"title","entries":[]}
    """#
}
