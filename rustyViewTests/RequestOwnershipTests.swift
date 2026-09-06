import Foundation
import Network
import XCTest
@testable import rustyView

@MainActor
final class RequestOwnershipTests: XCTestCase {
    /// The previous mutable session delegate answered a delayed 401 with the
    /// newly configured account. This exercises that challenge over real HTTP.
    func testDelayedAuthenticationKeepsTheAccountThatStartedTheRequest() async throws {
        let server = try OwnershipHTTPServer()
        let address = try await server.start()
        defer { server.stop() }
        let original = try ServerConnection(serverAddress: address, username: "first-viewer", password: "first-synthetic")
        let replacement = try ServerConnection(serverAddress: address, username: "second-viewer", password: "second-synthetic")
        let challenged = expectation(description: "Unauthenticated request reached the server")
        let release = OwnershipResponseGate()
        server.handler = { request, respond in
            if request.authorization == nil {
                release.store(respond)
                challenged.fulfill()
            } else {
                respond(.init(status: 200, body: Data("synthetic bytes".utf8)))
            }
        }
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(original)
        let request = URLRequest(url: try original.resolve(serverPath: "/captions/42001.vtt"))
        let pending = Task { try await client.data(for: request) }
        await fulfillment(of: [challenged], timeout: 3)
        client.configure(replacement)
        release.respond(.init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"synthetic-library\""]))
        let bytes = try await pending.value
        XCTAssertEqual(bytes, Data("synthetic bytes".utf8))
        let authenticated = server.requests.filter { $0.authorization != nil }
        XCTAssertEqual(authenticated.count, 1)
        XCTAssertTrue(authenticated.allSatisfy { $0.authorization == original.authorizationHeader() },
                      "The challenge must keep the account that started this request")
        _ = try await client.data(serverPath: "/art/42002.jpg")
        XCTAssertTrue(server.requests.last?.authorization == replacement.authorizationHeader())
    }

    /// Redirect rejection is checked at URL loading, including another port on
    /// the same host. The hostile listener must receive no request at all.
    func testRedirectCannotReachAnotherOriginAndDirectRequestsAreConfined() async throws {
        let trusted = try OwnershipHTTPServer()
        let hostile = try OwnershipHTTPServer()
        let trustedAddress = try await trusted.start()
        let hostileAddress = try await hostile.start()
        defer { trusted.stop(); hostile.stop() }
        trusted.handler = { _, respond in
            respond(.init(status: 302, headers: ["Location": hostileAddress + "/stolen"]))
        }
        hostile.handler = { _, respond in respond(.init(status: 200)) }
        let connection = try ServerConnection(serverAddress: trustedAddress, username: "viewer", password: "synthetic-secret")
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(connection)
        do {
            _ = try await client.data(serverPath: "/redirect")
            XCTFail("A rejected redirect must not become a successful response")
        } catch {
            XCTAssertEqual(error as? RustyDLNAError, .untrustedURL)
        }
        var forged = URLRequest(url: try XCTUnwrap(URL(string: hostileAddress + "/direct")))
        forged.setValue(connection.authorizationHeader(), forHTTPHeaderField: "Authorization")
        do {
            _ = try await client.data(for: forged)
            XCTFail("Caller-supplied requests must respect origin confinement")
        } catch {
            XCTAssertEqual(error as? RustyDLNAError, .untrustedURL)
        }
        XCTAssertEqual(trusted.requests.count, 1)
        XCTAssertTrue(hostile.requests.isEmpty)
    }

    func testRequestWaitingForTransportCannotAdoptAChangedAccount() async throws {
        let server = try OwnershipHTTPServer()
        let address = try await server.start()
        defer { server.stop() }
        server.handler = { _, respond in respond(.init(status: 200)) }
        let first = try ServerConnection(serverAddress: address, username: "first-viewer", password: "synthetic-one")
        let second = try ServerConnection(serverAddress: address, username: "second-viewer", password: "synthetic-two")
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(first)
        let waiting = try client.authorizedRequest(serverPath: "/art/42001.jpg")
        client.configure(second)
        do {
            _ = try await client.data(for: waiting)
            XCTFail("An old queued request must be cancelled")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testRejectedCredentialsProduceAuthenticationRecoveryInsteadOfCancellation() async throws {
        let server = try OwnershipHTTPServer()
        let address = try await server.start()
        defer { server.stop() }
        server.handler = { _, respond in
            respond(.init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"synthetic-library\""]))
        }
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(try ServerConnection(serverAddress: address, username: "viewer", password: "incorrect-synthetic"))
        do {
            _ = try await client.data(serverPath: "/art/42001.jpg")
            XCTFail("Rejected credentials must fail with an actionable category")
        } catch {
            XCTAssertEqual(error as? RustyDLNAError, .authenticationFailed)
        }
        XCTAssertLessThanOrEqual(server.requests.count, 2, "Authentication retries must be bounded")
    }
}

private final class OwnershipResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((OwnershipHTTPServer.Response) -> Void)?
    func store(_ callback: @escaping (OwnershipHTTPServer.Response) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.callback = callback
    }
    func respond(_ response: OwnershipHTTPServer.Response) {
        lock.lock()
        let callback = callback
        self.callback = nil
        lock.unlock()
        callback?(response)
    }
}

/// A synthetic origin with actual HTTP authentication and redirects. No URL
/// protocol interception or direct delegate invocation substitutes for loading.
private final class OwnershipHTTPServer: @unchecked Sendable {
    struct Request {
        let target: String
        let authorization: String?
    }
    struct Response {
        let status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }
    typealias Handler = (Request, @escaping (Response) -> Void) -> Void
    private let listener: NWListener
    private let queue = DispatchQueue(label: "synthetic.request-ownership.http")
    private let lock = NSLock()
    private var captured: [Request] = []
    private var callback: Handler?
    private var connections: [NWConnection] = []
    private var startup: CheckedContinuation<String, Error>?

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }
    var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return callback }
        set { lock.lock(); defer { lock.unlock() }; callback = newValue }
    }

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            startup = continuation
            lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                let result: Result<String, Error>
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    result = .success("http://127.0.0.1:\(port.rawValue)")
                case .failed(let error):
                    result = .failure(error)
                default: return
                }
                lock.lock()
                let continuation = startup
                startup = nil
                lock.unlock()
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
        lock.lock()
        let active = connections
        connections.removeAll()
        lock.unlock()
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
                .split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces)
            let request = Request(target: target, authorization: authorization)
            lock.lock()
            captured.append(request)
            let handler = callback
            lock.unlock()
            let send: (Response) -> Void = { response in
                var headers = response.headers
                headers["Content-Length"] = String(response.body.count)
                headers["Connection"] = "close"
                var bytes = Data("HTTP/1.1 \(response.status) Synthetic\r\n".utf8)
                for (key, value) in headers { bytes.append(Data("\(key): \(value)\r\n".utf8)) }
                bytes.append(Data("\r\n".utf8))
                bytes.append(response.body)
                connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
            }
            if let handler { handler(request, send) } else { send(.init(status: 404)) }
        }
    }
}
