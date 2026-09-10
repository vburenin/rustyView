import Foundation
import XCTest
@testable import rustyView

final class DownloadProgressDeliveryTests: XCTestCase {
    func testQuietConnectionGetsTheLastSampleAndRetiredAttemptCannotFlush() async throws {
        let delivery = DownloadProgressDelivery(interval: 0.1)
        let samples = CapturedProgress()
        let envelope = makeEnvelope()
        delivery.submit(.init(envelope: envelope, received: 1, expected: nil), deliver: samples.append)
        delivery.submit(.init(envelope: envelope, received: 2, expected: nil), deliver: samples.append)
        delivery.submit(.init(envelope: envelope, received: 3, expected: 10), deliver: samples.append)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(samples.values.map(\.received), [1, 3])
        XCTAssertEqual(samples.values.last?.expected, 10)
        delivery.submit(.init(envelope: envelope, received: 4, expected: 10), deliver: samples.append)
        // At least one update is pending inside the interval after this pair.
        delivery.submit(.init(envelope: envelope, received: 5, expected: 10), deliver: samples.append)
        delivery.remove(envelope.transferID)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(samples.values.contains { $0.received == 5 })
    }

    func testBackgroundKeepsOnlyLatestBytesForEachAttemptAndResumesWithoutNewNetworkData() async throws {
        let delivery = DownloadProgressDelivery(interval: 0.05)
        let samples = CapturedProgress()
        let old = makeEnvelope(), current = makeEnvelope()
        delivery.setEnabled(false)
        for bytes in 1...100 {
            delivery.submit(.init(envelope: old, received: Int64(bytes), expected: nil), deliver: samples.append)
            delivery.submit(.init(envelope: current, received: Int64(bytes * 2), expected: 500), deliver: samples.append)
        }
        delivery.remove(old.transferID)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(samples.values.isEmpty)
        delivery.setEnabled(true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(samples.values.map(\.received), [200])
        XCTAssertEqual(samples.values.first?.envelope.transferID, current.transferID)
    }

    private func makeEnvelope() -> DownloadTaskEnvelope {
        DownloadTaskEnvelope(legacyMetadata: DownloadTaskMetadata(recordID: UUID(), serverOrigin: "https://energy.example.test",
            mediaID: "123", title: "Synthetic Energy Sample", kind: .compatible, fileExtension: "mp4",
            durationSeconds: nil, resolution: nil))
    }
}

private final class CapturedProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [DownloadProgressDelivery.Sample] = []
    var values: [DownloadProgressDelivery.Sample] { lock.lock(); defer { lock.unlock() }; return captured }
    func append(_ sample: DownloadProgressDelivery.Sample) { lock.lock(); captured.append(sample); lock.unlock() }
}
