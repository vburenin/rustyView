import Darwin
import Foundation
import XCTest
@testable import rustyView

/// Component profile: URLSession, queue persistence and main-actor callbacks in
/// the unit host. It does not measure SwiftUI rendering or system suspension.
@MainActor
final class DownloadBatchPerformanceTests: XCTestCase {
    func testSixMediaTransfersKeepQueueActionsResponsiveWithinTwoSlots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("batch-profile-\(UUID().uuidString)")
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-native-tracks", withExtension: "mp4"))
        let payload = try Data(contentsOf: fixture)
        let host = "batch-\(UUID().uuidString.lowercased()).example.test"
        let endpoint = BatchProfileEndpoint(payload: payload)
        BatchProfileProtocol.register(endpoint, host: host)
        defer {
            BatchProfileProtocol.unregister(host: host)
            try? FileManager.default.removeItem(at: root)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BatchProfileProtocol.self]
        let owner = try ServerConnection(serverAddress: "https://\(host)", username: "batch-viewer", password: "synthetic-only")
        let client = RustyDLNAClient(configuration: configuration)
        client.configure(owner)
        let manager = DownloadManager(store: DownloadManifestStore(rootDirectory: root),
            sessionIdentifier: "batch-profile.\(UUID().uuidString)", sessionConfiguration: configuration,
            resumeSecrets: BatchProfileSecrets())
        manager.configure(connection: owner)
        await manager.waitForPendingOperations()
        let items = try (0..<6).map { try item(index: $0, byteCount: payload.count) }
        do {
            let idle = BatchHostSampler()
            idle.start()
            try await Task.sleep(for: .milliseconds(150))
            emit(try await idle.stop(), scenario: "idle")

            let single = BatchHostSampler()
            single.start()
            try manager.start(item: items[0], kind: .original, client: client)
            try await waitUntil { endpoint.snapshot.started.count == 1 && self.hasMediaProgress(manager, id: items[0].id) }
            try await Task.sleep(for: .milliseconds(150))
            let singleMetrics = try await single.stop()
            emit(singleMetrics, scenario: "single_held_media")
            XCTAssertGreaterThan(singleMetrics.samples, 0)

            let batch = BatchHostSampler()
            batch.start()
            for item in items.dropFirst() { try manager.start(item: item, kind: .original, client: client) }
            try await waitUntil {
                endpoint.snapshot.started.count == 2 && manager.active.count == 6
                    && manager.active.filter { $0.phase == .waiting(reason: .turn) }.count == 4
            }
            let heldSamples = batch.samples
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertGreaterThan(batch.samples, heldSamples,
                                 "Main-actor work must continue while actual media responses occupy both slots")
            XCTAssertEqual(endpoint.snapshot.active, 2)

            let cancelBegan = ContinuousClock.now
            manager.cancel(try XCTUnwrap(manager.activeDownload(for: items[0].id)))
            try await waitUntil {
                endpoint.snapshot.started.contains(items[2].id)
                    && manager.activeDownload(for: items[0].id) == nil
            }
            let cancelSeconds = batchSeconds(cancelBegan.duration(to: .now))

            let pauseBegan = ContinuousClock.now
            manager.pause(try XCTUnwrap(manager.activeDownload(for: items[1].id)))
            try await waitUntil {
                guard case .paused = manager.activeDownload(for: items[1].id)?.phase else { return false }
                return endpoint.snapshot.started.contains(items[3].id)
            }
            let pauseSeconds = batchSeconds(pauseBegan.duration(to: .now))
            // Every queued request must eventually be admitted when an earlier
            // real transfer is cancelled; a held response never self-completes.
            for index in 2...3 {
                manager.cancel(try XCTUnwrap(manager.activeDownload(for: items[index].id)))
                try await waitUntil { endpoint.snapshot.started.contains(items[index + 2].id) }
            }
            try await waitUntil {
                self.hasMediaProgress(manager, id: items[4].id)
                    && self.hasMediaProgress(manager, id: items[5].id)
            }
            let metrics = try await batch.stop()
            let observed = endpoint.snapshot
            emit(metrics, scenario: "six_job_queue_actions", additional: [
                "jobs": items.count, "authenticated_media_requests": observed.started.count,
                "peak_active_media_responses": observed.peak, "cancel_to_next_request_seconds": cancelSeconds,
                "pause_to_next_request_seconds": pauseSeconds,
                "media_bytes_delivered": observed.bytes,
            ])
            XCTAssertEqual(observed.started, items.map(\.id), "Cancellation and pause must advance the retained FIFO queue")
            XCTAssertEqual(observed.unauthorized, 0)
            XCTAssertLessThanOrEqual(observed.peak, 2, "Additional jobs must not bypass the transfer bound")
            XCTAssertTrue(manager.completed.isEmpty, "Held incomplete responses must not become saved movies")
            await cancelAll(manager)
            try await waitUntil { endpoint.snapshot.active == 0 }
            let journal = try DownloadQueueStore(rootDirectory: root).load()
            XCTAssertEqual(journal.entries.count, 6)
            XCTAssertTrue(journal.entries.allSatisfy { $0.state == .cancelled })
        } catch {
            await cancelAll(manager)
            throw error
        }
    }

    private func item(index: Int, byteCount: Int) throws -> MediaItem {
        let id = String(83500 + index)
        var response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)) as? [String: Any])
        var fields = try XCTUnwrap(response["item"] as? [String: Any])
        fields["id"] = id
        fields["title"] = "Synthetic Batch Movie \(index)"
        fields["file_name"] = "synthetic-\(index).mp4"
        fields["ext"] = "mp4"
        fields["mime"] = "video/mp4"
        fields["container"] = "mp4"
        fields["video_codec"] = "h264"
        fields["duration_seconds"] = 25
        fields["size_bytes"] = byteCount
        fields["download_url"] = "/web/download/\(id)"
        fields["source_url"] = "/web/media/\(id).mp4"
        fields["art_url"] = NSNull()
        fields["captions"] = []
        response["id"] = id
        response["item"] = fields
        return try JSONDecoder().decode(ItemResponse.self, from: JSONSerialization.data(withJSONObject: response)).item
    }

    private func hasMediaProgress(_ manager: DownloadManager, id: String) -> Bool {
        guard case .downloading(_, let received, let expected) = manager.activeDownload(for: id)?.phase else { return false }
        return received > 0 && expected.map { received < $0 } == true
    }

    private func cancelAll(_ manager: DownloadManager) async {
        for row in manager.active { manager.cancel(row) }
        await manager.waitForPendingOperations()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let began = ContinuousClock.now
        while !condition(), batchSeconds(began.duration(to: .now)) < 4 {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard condition() else {
            XCTFail("Actual HTTP/media and queue transitions must reach the bounded profile checkpoint")
            throw CocoaError(.coderValueNotFound)
        }
    }

    private func emit(_ sample: BatchHostSampler.Result, scenario: String, additional: [String: Any] = [:]) {
        var values = additional
        values.merge(["scenario": scenario, "measurement": "unit_host_component",
                      "elapsed_seconds": sample.elapsed, "process_cpu_seconds": sample.cpu,
                      "observed_physical_footprint_start": sample.startBytes,
                      "observed_physical_footprint_peak": sample.peakBytes,
                      "main_actor_max_gap_seconds": sample.maximumGap, "main_actor_samples": sample.samples]) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        print("DOWNLOAD_BATCH_COMPONENT_PROFILE \(json)")
    }
}

private func batchSeconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

@MainActor
private final class BatchHostSampler {
    struct Result {
        let elapsed: Double, cpu: Double, maximumGap: Double
        let startBytes: UInt64, peakBytes: UInt64
        let samples: Int
    }
    private var task: Task<Void, Never>?
    private var began = ContinuousClock.now
    private var startCPU = 0.0
    private var startBytes: UInt64 = 0
    private var peakBytes: UInt64 = 0
    private var maximumGap = 0.0
    private(set) var samples = 0

    func start() {
        began = .now
        startCPU = cpuSeconds()
        startBytes = footprint()
        peakBytes = startBytes
        task = Task { [weak self] in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                guard let self else { return }
                let now = ContinuousClock.now
                maximumGap = max(maximumGap, batchSeconds(previous.duration(to: now)))
                peakBytes = max(peakBytes, footprint())
                samples += 1
                previous = now
            }
        }
    }

    func stop() async throws -> Result {
        task?.cancel()
        await task?.value
        task = nil
        return Result(elapsed: batchSeconds(began.duration(to: .now)), cpu: max(0, cpuSeconds() - startCPU),
                      maximumGap: maximumGap, startBytes: startBytes, peakBytes: max(peakBytes, footprint()), samples: samples)
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    deinit { task?.cancel() }
}

private final class BatchProfileEndpoint: @unchecked Sendable {
    struct Snapshot { var started: [String] = []; var active = 0; var peak = 0; var bytes = 0; var unauthorized = 0 }
    let payload: Data
    private let lock = NSLock()
    private var value = Snapshot()
    private var activeIDs: Set<UUID> = []
    init(payload: Data) { self.payload = payload }
    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    func begin(_ id: UUID, request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("batch-viewer:synthetic-only".utf8).base64EncodedString(),
              let url = request.url, url.path.hasPrefix("/web/download/") else {
            value.unauthorized += 1
            return false
        }
        activeIDs.insert(id)
        value.started.append(url.lastPathComponent)
        value.active = activeIDs.count
        value.peak = max(value.peak, value.active)
        return true
    }
    func sent(_ count: Int) { lock.lock(); value.bytes += count; lock.unlock() }
    func end(_ id: UUID) { lock.lock(); activeIDs.remove(id); value.active = activeIDs.count; lock.unlock() }
}

private final class BatchProfileProtocol: URLProtocol {
    private static let registryLock = NSLock()
    private static var endpoints: [String: BatchProfileEndpoint] = [:]
    private let id = UUID()
    private var endpoint: BatchProfileEndpoint?
    static func register(_ endpoint: BatchProfileEndpoint, host: String) { registryLock.lock(); endpoints[host] = endpoint; registryLock.unlock() }
    static func unregister(host: String) { registryLock.lock(); endpoints.removeValue(forKey: host); registryLock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool {
        registryLock.lock(); defer { registryLock.unlock() }
        return request.url?.host.flatMap { endpoints[$0] } != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.registryLock.lock()
        endpoint = request.url?.host.flatMap { Self.endpoints[$0] }
        Self.registryLock.unlock()
        guard let endpoint, let url = request.url, endpoint.begin(id, request: request),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "video/mp4", "Content-Length": "\(endpoint.payload.count)"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = endpoint.payload.prefix(endpoint.payload.count * 3 / 4)
        client?.urlProtocol(self, didLoad: body)
        endpoint.sent(body.count)
        // A real 200 response and actual valid media prefix cross URLSession's
        // download-file progress boundary. Hold the tail until user cancellation.
    }
    override func stopLoading() { endpoint?.end(id) }
}

private final class BatchProfileSecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func read(account: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func write(_ value: String, account: String) throws { lock.lock(); values[account] = value; lock.unlock() }
    func remove(account: String) throws { lock.lock(); values.removeValue(forKey: account); lock.unlock() }
}
