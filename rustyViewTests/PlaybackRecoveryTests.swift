import AVFoundation
import Network
import XCTest
@testable import rustyView

/// Prepared-stream recovery against a real HTTP server, the app's relay and
/// AVFoundation. Playing streams use real H.264/AAC MPEG-TS segments; the
/// server's cancellation and failure responses mirror rustyDLNA's.
@MainActor
final class PlaybackRecoveryTests: XCTestCase {
    func testScrubbingPastThePreparedWindowDoesNotChargeTheReplacedStreamToItsFormat() async throws {
        let fixture = try await PreparedRecoveryFixture.make()
        defer { fixture.stop() }
        // The first stream is still loading when the scrub starts; the
        // server fails its playlist once the scrub cancels that generation.
        fixture.server.respond { _ in .hold }
        let model = fixture.model()
        defer { model.stop() }
        model.play(fixture.item, startAt: 0)
        await waitFor("The first copied stream is requested") { fixture.server.requests.contains { $0.generation == 1 } }

        // Scrub the way a remote does: new targets faster than the restart
        // debounce, so the replaced stream fails while no restart has begun.
        var target = 3_000.0
        var replacedStreamFailedWhileScrubbing = false
        for _ in 0..<60 {
            model.seek(toGlobalTime: target)
            if model.player.currentItem?.status == .failed { replacedStreamFailedWhileScrubbing = true; break }
            if fixture.server.requests.contains(where: { $0.generation > 1 }) { break }
            target += 30
            try await Task.sleep(for: .milliseconds(100))
        }
        await waitFor("The scrub restarts the stream") { fixture.server.requests.contains { $0.generation > 1 } }
        let restarts = fixture.server.requests.filter { $0.generation > 1 }
        XCTAssertEqual(restarts.map(\.format), restarts.map { _ in .copy },
                       "Cancelling the replaced stream is not a reason to re-encode or drop HDR: \(restarts)")
        XCTAssertTrue(replacedStreamFailedWhileScrubbing,
                      "The replaced stream must actually fail during the scrub for this check to mean anything")
        XCTAssertEqual(Set(restarts.map(\.generation)).count, 1, "One restart serves the final scrub target")
        XCTAssertEqual(restarts.first?.start, Int(target))
        XCTAssertNil(model.errorMessage)
    }

    func testHDRThatAlreadyPlayedIsRetriedAndNeverAutomaticallyDropsToSDR() async throws {
        let fixture = try await PreparedRecoveryFixture.make()
        defer { fixture.stop() }
        let model = fixture.model()
        defer { model.stop() }
        model.play(fixture.item, startAt: 0)
        await waitFor("The copied HDR stream actually plays", timeout: 10) { model.transport.progressed }

        fixture.server.respond { _ in .fail }
        model.seek(toGlobalTime: 3_000)
        await waitFor("Recovery ends", timeout: 20) { model.errorMessage != nil }

        let formats = fixture.server.formatsByGeneration
        XCTAssertEqual(formats.first, .copy)
        XCTAssertEqual(Array(formats.dropFirst()), Array(repeating: .copy, count: 6) + Array(repeating: .hdr10, count: 3),
                       "A format that played gets six attempts; the HDR10 encode gets three before giving up")
        XCTAssertFalse(formats.contains(.sdr), "Automatic recovery must not convert HDR that already played to SDR")
        XCTAssertTrue(model.errorMessage?.contains("instead of switching to SDR") == true, model.errorMessage ?? "")
        XCTAssertEqual(model.currentTime, 3_000)
        XCTAssertFalse(model.isPreparing)

        // The person can still choose SDR explicitly.
        XCTAssertEqual(model.retryLabel, "Try Maximum Compatibility")
        fixture.server.respond { _ in .hold }
        model.retryCompatible()
        await waitFor("An explicit choice may use SDR") { fixture.server.formatsByGeneration.last == .sdr }
    }

    func testAFormatThatNeverPlayedIsRetriedBeforeEachStepDown() async throws {
        let fixture = try await PreparedRecoveryFixture.make()
        defer { fixture.stop() }
        fixture.server.respond { _ in .fail }
        let model = fixture.model()
        defer { model.stop() }
        model.play(fixture.item, startAt: 45)
        await waitFor("Recovery ends", timeout: 20) { model.errorMessage != nil }

        XCTAssertEqual(fixture.server.formatsByGeneration,
                       Array(repeating: .copy, count: 3) + Array(repeating: .hdr10, count: 3) + Array(repeating: .sdr, count: 3),
                       "Each format gets three attempts before recovery moves on; SDR is allowed because HDR never played")
        XCTAssertEqual(Set(fixture.server.requests.map(\.session)).count, 1)
        XCTAssertTrue(fixture.server.requests.allSatisfy { $0.start == 45 })
        XCTAssertNotNil(model.streamFormatNotice)
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
        let done = expectation(description: description)
        let task = Task {
            while !Task.isCancelled {
                if condition() { done.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await fulfillment(of: [done], timeout: timeout)
        task.cancel()
    }
}

@MainActor
private struct PreparedRecoveryFixture {
    let server: PreparedRecoveryHTTPServer
    let client: RustyDLNAClient
    let item: MediaItem

    static func make() async throws -> Self {
        let segments = try (0..<3).map { index in
            let url = try XCTUnwrap(Bundle(for: PlaybackRecoveryTests.self).url(forResource: "synthetic-stall-\(index)", withExtension: "ts"))
            return try Data(contentsOf: url)
        }
        let server = try PreparedRecoveryHTTPServer(segments: segments)
        let address = try await server.start()
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(try ServerConnection(serverAddress: address, username: "viewer", password: "synthetic-recovery-secret"))
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)) as? [String: Any])
        var item = try XCTUnwrap(envelope["item"] as? [String: Any])
        item["id"] = PreparedRecoveryHTTPServer.mediaID
        item["title"] = "The Lantern Ferry"
        item["source_url"] = "/web/media/\(PreparedRecoveryHTTPServer.mediaID).mp4?mode=direct"
        item["fallback_url"] = "/web/media/\(PreparedRecoveryHTTPServer.mediaID).mp4"
        item["prepared_video_outputs"] = ["h264_sdr", "hevc_hdr10"]
        item["captions"] = []
        envelope["item"] = item
        let decoded = try JSONDecoder().decode(ItemResponse.self, from: JSONSerialization.data(withJSONObject: envelope)).item
        XCTAssertEqual(decoded.hdr, "hdr10")
        XCTAssertEqual(decoded.transcodeLikely, true)
        return Self(server: server, client: client, item: decoded)
    }

    func model() -> PlaybackModel {
        PlaybackModel(client: client, progressTimeout: 10, watchdogInterval: .milliseconds(50),
                      recoveryPolicy: PlaybackRecoveryPolicy(retryDelays: [.milliseconds(20)]))
    }

    func stop() { server.stop() }
}

/// A Basic-authenticated rustyDLNA stand-in for prepared HLS. Cancelled
/// generations answer 409 `transcode_cancelled`, including requests held
/// when the DELETE arrives, as the real server does.
final class PreparedRecoveryHTTPServer: @unchecked Sendable {
    static let mediaID = "76101"

    enum Format: Equatable { case copy, hdr10, sdr }
    enum Response { case play, fail, hold }
    struct Request: Equatable {
        let session: UInt64
        let generation: UInt64
        let start: Int
        let format: Format
    }

    private let queue = DispatchQueue(label: "synthetic.recovery.http")
    private let listener: NWListener
    private let segments: [Data]
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var recorded: [Request] = []
    private var cancelled: Set<UInt64> = []
    private var held: [(generation: UInt64, connection: NWConnection)] = []
    private var policy: (Request) -> Response = { _ in .play }
    private var startup: CheckedContinuation<String, Error>?

    init(segments: [Data]) throws {
        self.segments = segments
        listener = try NWListener(using: .tcp, on: .any)
    }

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }

    /// The format of each prepared generation, in request order.
    var formatsByGeneration: [Format] {
        var seen = Set<UInt64>()
        return requests.filter { seen.insert($0.generation).inserted }.map(\.format)
    }

    func respond(_ policy: @escaping (Request) -> Response) { lock.lock(); self.policy = policy; lock.unlock() }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); startup = continuation; lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                let result: Result<String, Error>
                switch state {
                case .ready: guard let port = listener.port else { return }; result = .success("http://127.0.0.1:\(port.rawValue)")
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
        lock.lock(); let open = connections; connections.removeAll(); held.removeAll(); lock.unlock()
        open.forEach { $0.cancel() }
    }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, ended, error in
            guard let self, error == nil else { connection.cancel(); return }
            var bytes = bytes
            if let data { bytes.append(data) }
            guard bytes.count <= 65_536 else { connection.cancel(); return }
            guard let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") else {
                if ended { connection.cancel() } else { receive(connection, bytes: bytes) }
                return
            }
            handle(text, connection: connection)
        }
    }

    private func handle(_ text: String, connection: NWConnection) {
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2, let components = URLComponents(string: String(first[1])) else { connection.cancel(); return }
        let method = String(first[0])
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }?
            .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        guard authorization == "Basic " + Data("viewer:synthetic-recovery-secret".utf8).base64EncodedString() else {
            send(connection, status: 401, body: Data(), type: "text/plain", extra: "WWW-Authenticate: Basic realm=\"Synthetic recovery\"\r\n")
            return
        }
        let generation = query["request"].flatMap(UInt64.init) ?? 0
        let id = Self.mediaID
        switch (method, components.path) {
        case ("DELETE", "/api/web/transcode/\(id)"):
            lock.lock()
            cancelled.insert(generation)
            let released = held.filter { $0.generation == generation }.map(\.connection)
            held.removeAll { $0.generation == generation }
            lock.unlock()
            released.forEach { sendCancelled($0) }
            sendStatus(connection, generation: generation, state: "cancelled")
        case ("GET", "/api/web/transcode/\(id)"):
            sendStatus(connection, generation: generation, state: "running")
        case ("GET", "/web/media/\(id).m3u8"):
            let request = Request(
                session: query["session"].flatMap(UInt64.init) ?? 0, generation: generation,
                start: query["start"].flatMap(Int.init) ?? -1,
                format: query["video_mode"] != "transcode" ? .copy : (query["video_output"] == "hevc_hdr10" ? .hdr10 : .sdr))
            lock.lock()
            recorded.append(request)
            let isCancelled = cancelled.contains(generation)
            let response = policy(request)
            if !isCancelled, response == .hold { held.append((generation, connection)) }
            lock.unlock()
            if isCancelled { sendCancelled(connection); return }
            switch response {
            case .hold: return
            case .fail:
                send(connection, status: 500, body: Data(#"{"schema_version":2,"error":{"code":"transcode_failed","message":"Synthetic preparation failed.","recoverable":true,"action":"retry_media"}}"#.utf8),
                     type: "application/json")
            case .play:
                let identity = "session=\(request.session)&request=\(generation)"
                let durations = ["2.021333", "2.080000", "2.074666"]
                let entries = durations.enumerated().map { "#EXTINF:\($1),\n/web/media/\(id)-segment-\($0).ts?\(identity)" }
                let playlist = (["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:3", "#EXT-X-MEDIA-SEQUENCE:0",
                                 "#EXT-X-PLAYLIST-TYPE:EVENT", "#EXT-X-START:TIME-OFFSET=0,PRECISE=YES"] + entries)
                    .joined(separator: "\n") + "\n"
                send(connection, status: 200, body: Data(playlist.utf8), type: "application/vnd.apple.mpegurl")
            }
        default:
            let prefix = "/web/media/\(id)-segment-"
            if method == "GET", components.path.hasPrefix(prefix), components.path.hasSuffix(".ts"),
               let index = Int(components.path.dropFirst(prefix.count).dropLast(3)), segments.indices.contains(index) {
                lock.lock(); let isCancelled = cancelled.contains(generation); lock.unlock()
                if isCancelled { sendCancelled(connection) } else { send(connection, status: 200, body: segments[index], type: "video/mp2t") }
            } else {
                send(connection, status: 404, body: Data(), type: "text/plain")
            }
        }
    }

    private func sendCancelled(_ connection: NWConnection) {
        send(connection, status: 409, body: Data(#"{"schema_version":2,"error":{"code":"transcode_cancelled","message":"Preparing this title was cancelled.","recoverable":true,"action":"retry_media"}}"#.utf8),
             type: "application/json")
    }

    private func sendStatus(_ connection: NWConnection, generation: UInt64, state: String) {
        let body = #"{"schema_version":2,"item_id":"\#(Self.mediaID)","request_id":\#(generation),"state":"\#(state)"}"#
        send(connection, status: 200, body: Data(body.utf8), type: "application/json")
    }

    private func send(_ connection: NWConnection, status: Int, body: Data, type: String, extra: String = "") {
        var response = Data("HTTP/1.1 \(status) Synthetic\r\nConnection: close\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n\(extra)\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
