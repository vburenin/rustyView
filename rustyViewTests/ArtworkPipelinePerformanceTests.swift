import AVFoundation
import Darwin
import ImageIO
import Network
import UIKit
import XCTest
@testable import rustyView

/// Run unchanged before and after the pipeline fix. The queued-cancellation
/// and retained-raster assertions intentionally expose the existing faults.
@MainActor
final class ArtworkPipelinePerformanceTests: XCTestCase {
    func testCancelledQueuedArtworkReleasesCapturedClientsBeforeAnyPermitOpens() async throws {
        let bytes = try await Task.detached { try ArtworkRasterFixture.jpeg(width: 128, height: 192) }.value
        let server = try ArtworkProbeServer(image: bytes, holdingResponses: true)
        let address = try await server.start()
        let client = try makeClient(address)
        let namespace = UUID().uuidString
        let active = (0..<4).map { _ in ArtworkModel() }
        for (index, model) in active.enumerated() {
            model.load(path: "/poster/\(namespace)/active-\(index).jpg", client: client)
        }
        var queued: [ArtworkModel] = []
        var clients: [WeakArtworkClient] = []
        addTeardownBlock {
            await MainActor.run { active.forEach { $0.cancel() }; queued.forEach { $0.cancel() } }
            server.releaseAll()
            await self.waitUntil(timeout: 3) { clients.allSatisfy { $0.value == nil } }
            server.stop()
        }
        let saturated = await waitUntil { server.heldResponseCount == 4 }
        XCTAssertTrue(saturated)
        for index in 0..<20 {
            let owner = try makeClient(address)
            clients.append(WeakArtworkClient(owner))
            let model = ArtworkModel()
            queued.append(model)
            model.load(path: "/poster/\(namespace)/queued-client-\(index).jpg", client: owner)
        }
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(30))
        queued.forEach { $0.cancel() }
        queued.removeAll()
        let released = await waitUntil(timeout: 0.5) { clients.allSatisfy { $0.value == nil } }
        XCTAssertTrue(released, "Weak model capture alone must not leave cancelled Tasks and their clients retained by the admission queue")
        XCTAssertEqual(server.heldResponseCount, 4)
        XCTAssertEqual(server.authenticatedRequestCount, 4)
    }

    func testQueuedArtworkDoesNotFetchAfterItsAccountChanges() async throws {
        let bytes = try await Task.detached { try ArtworkRasterFixture.jpeg(width: 128, height: 192) }.value
        let server = try ArtworkProbeServer(image: bytes, holdingResponses: true)
        let address = try await server.start()
        let activeClient = try makeClient(address)
        let pendingClient = try makeClient(address)
        let namespace = UUID().uuidString
        let active = (0..<4).map { _ in ArtworkModel() }
        let pending = ArtworkModel()
        addTeardownBlock {
            await MainActor.run { active.forEach { $0.cancel() }; pending.cancel() }
            server.releaseAll()
            server.stop()
        }
        for (index, model) in active.enumerated() {
            model.load(path: "/poster/\(namespace)/active-\(index).jpg", client: activeClient)
        }
        let saturated = await waitUntil { server.heldResponseCount == 4 }
        XCTAssertTrue(saturated)
        pending.load(path: "/poster/\(namespace)/changed-account.jpg", client: pendingClient)
        for _ in 0..<10 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(30))
        pendingClient.configure(try ServerConnection(serverAddress: address, username: "replacement-viewer", password: "replacement-synthetic-secret"))
        server.releaseAll()
        let activeLoaded = await waitUntil { active.allSatisfy { $0.image != nil } }
        XCTAssertTrue(activeLoaded)
        // A fresh admitted request proves the queue is moving after release.
        let sentinel = ArtworkModel()
        sentinel.load(path: "/poster/\(namespace)/sentinel.jpg", client: activeClient)
        let sentinelLoaded = await waitUntil { sentinel.image != nil }
        XCTAssertTrue(sentinelLoaded)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(server.totalRequestCount, 5, "Neither old nor replacement credentials may issue a queued request after its owner changes")
        XCTAssertNil(pending.image)
        XCTAssertFalse(pending.failed, "A stale owner's cancellation must not become the new account's artwork error")
    }

    func testLateFailedArtworkCannotReplaceANewerSuccessfulImage() async throws {
        let valid = try await Task.detached { try ArtworkRasterFixture.jpeg(width: 256, height: 384) }.value
        let oldServer = try ArtworkProbeServer(image: Data("not an image".utf8), holdingResponses: true)
        let newServer = try ArtworkProbeServer(image: valid)
        let oldClient = try makeClient(try await oldServer.start())
        let newClient = try makeClient(try await newServer.start())
        let model = ArtworkModel()
        addTeardownBlock {
            await MainActor.run { model.cancel() }
            oldServer.releaseAll()
            oldServer.stop(); newServer.stop()
        }
        let namespace = UUID().uuidString
        model.load(path: "/poster/\(namespace)/old.jpg", client: oldClient)
        let held = await waitUntil { oldServer.heldResponseCount == 1 }
        XCTAssertTrue(held)
        model.load(path: "/poster/\(namespace)/new.jpg", client: newClient)
        let loaded = await waitUntil { model.image != nil }
        XCTAssertTrue(loaded)
        let raster = try XCTUnwrap(model.image?.cgImage)
        oldServer.releaseAll()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.failed)
        XCTAssertTrue(model.image?.cgImage === raster, "Late bytes from the cancelled request must not replace the successful generation")
        let colors = try ArtworkRasterFixture.renderAndSample(try XCTUnwrap(model.image))
        XCTAssertGreaterThan(colors.leftBlue, colors.leftRed + 80)
        XCTAssertGreaterThan(colors.rightRed, colors.rightBlue + 80)
        XCTAssertEqual(newServer.authenticatedRequestCount, 1)
    }
    func testCancelledQueuedArtworkReleasesItsModelsWithoutWaitingForActiveHTTP() async throws {
        let bytes = try await Task.detached { try ArtworkRasterFixture.jpeg(width: 128, height: 192) }.value
        let server = try ArtworkProbeServer(image: bytes, holdingResponses: true)
        let address = try await server.start()
        let client = try makeClient(address)
        let namespace = UUID().uuidString
        let active = (0..<4).map { _ in ArtworkModel() }
        for (index, model) in active.enumerated() { model.load(path: "/poster/\(namespace)/active-\(index).jpg", client: client) }
        var queued: [ArtworkModel] = []
        var weakQueued: [WeakArtworkModel] = []
        addTeardownBlock {
            await MainActor.run { active.forEach { $0.cancel() } }
            server.releaseAll()
            // Cancellation must finish all permit owners before another test
            // uses the production singleton limiter.
            await self.waitUntil(timeout: 3) { weakQueued.allSatisfy { $0.value == nil } }
            server.stop()
        }
        let activeReached = await waitUntil { server.heldResponseCount == 4 }
        XCTAssertTrue(activeReached, "Four actual authenticated HTTP transfers establish the saturation boundary.")
        guard activeReached else { return }
        for index in 0..<20 {
            let model = ArtworkModel()
            queued.append(model)
            weakQueued.append(WeakArtworkModel(model))
            model.load(path: "/poster/\(namespace)/queued-\(index).jpg", client: client)
        }
        // Give every Task a turn to reach the permit boundary; no HTTP response
        // is released during this observation interval.
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(30))
        let capturedBeforeCancel = server.authenticatedRequestCount
        let began = ContinuousClock.now
        queued.forEach { $0.cancel() }
        queued.removeAll()
        let promptlyReleased = await waitUntil(timeout: 0.25) { weakQueued.allSatisfy { $0.value == nil } }
        let elapsed = seconds(began.duration(to: .now))
        let retained = weakQueued.filter { $0.value != nil }.count
        emitMetrics([
            "scenario": "queued_cancellation", "queued": 20, "retained_after_cancel": retained,
            "cancel_observation_seconds": elapsed, "active_held_responses": server.heldResponseCount,
            "authenticated_requests_before_cancel": capturedBeforeCancel,
            "authenticated_requests_after_cancel": server.authenticatedRequestCount,
            "peak_server_transfers": server.peakActiveTransfers,
        ])
        XCTAssertEqual(capturedBeforeCancel, 4, "Queued poster models must not start unbounded HTTP work.")
        XCTAssertEqual(server.authenticatedRequestCount, capturedBeforeCancel)
        XCTAssertEqual(server.heldResponseCount, 4, "No response may be released to make cancellation appear prompt.")
        XCTAssertTrue(promptlyReleased, "Cancelled queued models remain retained behind unrelated held HTTP transfers.")
    }

    func testLargePostersKeepABoundedRasterAndMeasureRealRenderingCost() async throws {
        let bytes = try await Task.detached { try ArtworkRasterFixture.jpeg(width: 2_048, height: 3_072) }.value
        let server = try ArtworkProbeServer(image: bytes)
        let address = try await server.start()
        let client = try makeClient(address)
        let models = (0..<6).map { _ in ArtworkModel() }
        addTeardownBlock {
            await MainActor.run { models.forEach { $0.cancel() } }
            server.releaseAll()
            server.stop()
        }
        let delay = ArtworkMainActorDelayProbe()
        let memory = ArtworkMemoryProbe()
        delay.start()
        memory.start()
        // Establish a real heartbeat sample before the measured workload.
        try await Task.sleep(for: .milliseconds(20))
        let began = ContinuousClock.now
        let namespace = UUID().uuidString
        for (index, model) in models.enumerated() {
            model.load(path: "/poster/\(namespace)/large-\(index).jpg", client: client)
        }
        let loaded = await waitUntil(timeout: 8) { models.allSatisfy { $0.image != nil } }
        let loadSeconds = seconds(began.duration(to: .now))
        XCTAssertTrue(loaded, "All six independent cache keys must load through real HTTP before measuring rasters.")
        let images = try models.map { try XCTUnwrap($0.image) }
        let rasters = try images.map { try XCTUnwrap($0.cgImage) }
        let rasterBytes = rasters.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        let largestEdge = rasters.map { max($0.width, $0.height) }.max() ?? 0
        let renderingBegan = ContinuousClock.now
        for image in images {
            let result = try autoreleasepool { try ArtworkRasterFixture.renderAndSample(image) }
            XCTAssertGreaterThan(result.leftBlue, result.leftRed + 80, "A real blue region must survive image loading and drawing.")
            XCTAssertGreaterThan(result.rightRed, result.rightBlue + 80, "A real red region must survive image loading and drawing.")
        }
        let renderSeconds = seconds(renderingBegan.duration(to: .now))
        // Let the heartbeat and memory sampler observe the completed render;
        // measuring UIImage(data:) alone can miss deferred JPEG decompression.
        try await Task.sleep(for: .milliseconds(30))
        await delay.stop()
        await memory.stop()
        let footprint = memory.snapshot()
        emitMetrics([
            "scenario": "large_posters", "poster_count": images.count,
            "source_width": 2_048, "source_height": 3_072, "compressed_bytes_each": bytes.count,
            "retained_raster_bytes": rasterBytes, "largest_raster_edge": largestEdge,
            "load_seconds": loadSeconds, "actual_raster_render_seconds": renderSeconds,
            "main_actor_max_gap_seconds": delay.maximumGap, "main_actor_samples": delay.samples,
            "physical_footprint_start": footprint.first, "physical_footprint_peak": footprint.peak,
            "physical_footprint_last": footprint.last, "physical_footprint_samples": footprint.samples,
            "authenticated_requests": server.authenticatedRequestCount,
            "peak_server_transfers": server.peakActiveTransfers,
        ])
        XCTAssertGreaterThan(delay.samples, 0)
        XCTAssertGreaterThan(footprint.samples, 0)
        XCTAssertEqual(server.authenticatedRequestCount, images.count)
        XCTAssertLessThanOrEqual(server.peakActiveTransfers, 4)
        // The app displays poster-sized images. This is a generous visual
        // bound, not an assertion of the future decoder's exact target size.
        XCTAssertLessThanOrEqual(largestEdge, 1_024,
                                "Poster models must not retain full 2048x3072 source rasters for small rendered cards.")
    }

    private func makeClient(_ address: String) throws -> RustyDLNAClient {
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(try ServerConnection(serverAddress: address, username: "artwork-viewer", password: "synthetic-artwork-secret"))
        return client
    }

    @discardableResult
    private func waitUntil(timeout: Double = 5, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while seconds(start.duration(to: .now)) < timeout {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func emitMetrics(_ values: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        print("ARTWORK_BENCHMARK \(json)")
    }
}

@MainActor
private final class WeakArtworkModel {
    weak var value: ArtworkModel?
    init(_ value: ArtworkModel) { self.value = value }
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

@MainActor
private final class ArtworkMainActorDelayProbe {
    private var task: Task<Void, Never>?
    private(set) var maximumGap = 0.0
    private(set) var samples = 0
    func start() {
        task = Task { [weak self] in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                let now = ContinuousClock.now
                guard let self else { return }
                maximumGap = max(maximumGap, seconds(previous.duration(to: now)))
                samples += 1
                previous = now
            }
        }
    }
    func stop() async { task?.cancel(); await task?.value; task = nil }
}

private final class ArtworkMemoryProbe: @unchecked Sendable {
    struct Snapshot { var first: UInt64 = 0; var peak: UInt64 = 0; var last: UInt64 = 0; var samples = 0 }
    private let lock = NSLock()
    private var values = Snapshot()
    private var task: Task<Void, Never>?
    func start() {
        sample()
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
            }
        }
    }
    func stop() async { task?.cancel(); await task?.value; task = nil; sample() }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return values }
    private func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        lock.lock()
        if values.samples == 0 { values.first = info.phys_footprint }
        values.peak = max(values.peak, info.phys_footprint)
        values.last = info.phys_footprint
        values.samples += 1
        lock.unlock()
    }
}

private enum ArtworkRasterFixture {
    struct RenderedColors { let leftRed: Int; let leftBlue: Int; let rightRed: Int; let rightBlue: Int }

    static func jpeg(width: Int, height: Int) throws -> Data {
        try autoreleasepool {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileReadCorruptFile) }
            context.setFillColor(CGColor(red: 0.05, green: 0.2, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.05, alpha: 1))
            context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
            // Synthetic detail prevents this from being an empty or single-
            // color JPEG, while leaving the sampled blue/red regions clear.
            for index in 0..<80 {
                context.setFillColor(CGColor(gray: CGFloat(index % 7) / 7, alpha: 1))
                context.fill(CGRect(x: width * 3 / 8, y: index * height / 80, width: width / 4, height: max(1, height / 160)))
            }
            guard let image = context.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            return data as Data
        }
    }

    static func renderAndSample(_ image: UIImage) throws -> RenderedColors {
        // UIImage(data:) may defer decompression. Drawing its real CGImage into
        // a poster-sized bitmap forces decoding and produces inspectable pixels.
        let width = 160, height = 240
        guard let source = image.cgImage,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else {
            throw CocoaError(.fileReadCorruptFile)
        }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let left = (height / 2 * width + width / 4) * 4
        let right = (height / 2 * width + width * 3 / 4) * 4
        return RenderedColors(leftRed: Int(bytes[left]), leftBlue: Int(bytes[left + 2]),
                              rightRed: Int(bytes[right]), rightBlue: Int(bytes[right + 2]))
    }
}

private final class WeakArtworkClient {
    weak var value: RustyDLNAClient?
    init(_ value: RustyDLNAClient) { self.value = value }
}

private final class ArtworkProbeServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "synthetic.artwork-probe.http")
    private let lock = NSLock()
    private let image: Data
    private var holding: Bool
    private var held: [() -> Void] = []
    private var connections: [NWConnection] = []
    private var startup: CheckedContinuation<String, Error>?
    private var authenticated = 0
    private var requests = 0
    var totalRequestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    private var active = 0
    private var peak = 0
    var heldResponseCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }
    var authenticatedRequestCount: Int { lock.lock(); defer { lock.unlock() }; return authenticated }
    var peakActiveTransfers: Int { lock.lock(); defer { lock.unlock() }; return peak }

    init(image: Data, holdingResponses: Bool = false) throws {
        self.image = image
        holding = holdingResponses
        listener = try NWListener(using: .tcp, on: .any)
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
    func releaseAll() {
        lock.lock(); holding = false; let responses = held; held.removeAll(); lock.unlock()
        responses.forEach { $0() }
    }
    func stop() {
        releaseAll()
        listener.cancel()
        lock.lock(); let active = connections; connections.removeAll(); lock.unlock()
        active.forEach { $0.cancel() }
    }
    private func didSendAuthenticatedResponse() {
        lock.lock(); active -= 1; lock.unlock()
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
            lock.lock(); requests += 1; lock.unlock()
            let lines = text.components(separatedBy: "\r\n")
            let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }?
                .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
            let authorized = authorization == "Basic " + Data("artwork-viewer:synthetic-artwork-secret".utf8).base64EncodedString()
            let isPoster = target.hasPrefix("/poster/") && target.contains(".jpg")
            let body = authorized && isPoster ? image : Data()
            let status = authorized ? (isPoster ? 200 : 404) : 401
            var response = Data("HTTP/1.1 \(status) Synthetic\r\nContent-Length: \(body.count)\r\nConnection: close\r\nContent-Type: image/jpeg\r\n".utf8)
            if !authorized { response.append(Data("WWW-Authenticate: Basic realm=\"Synthetic Artwork\"\r\n".utf8)) }
            response.append(Data("\r\n".utf8)); response.append(body)
            if authorized && isPoster {
                lock.lock(); authenticated += 1; active += 1; peak = max(peak, active); lock.unlock()
            }
            let send = { [weak self] in
                connection.send(content: response, completion: .contentProcessed { _ in
                    if authorized && isPoster { self?.didSendAuthenticatedResponse() }
                    connection.cancel()
                })
            }
            lock.lock()
            if holding && authorized && isPoster { held.append(send); lock.unlock() }
            else { lock.unlock(); send() }
        }
    }
}
