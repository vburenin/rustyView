import AVFoundation
import XCTest
@testable import rustyView

enum OfflineMediaFixture {
    static func validData() throws -> Data { try data("synthetic-offline-valid", extension: "mp4") }
    static func unsupportedData() throws -> Data { try data("synthetic-offline-unsupported", extension: "webm") }

    private static func data(_ name: String, extension fileExtension: String) throws -> Data {
        let bundle = Bundle(for: OfflineReadinessTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: fileExtension))
        return try Data(contentsOf: url)
    }
}

final class OfflineReadinessTests: XCTestCase {
    private var root: URL!
    private var store: DownloadManifestStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("offline"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testRealVideoRemainsReadyAfterReopenDespiteStaleCatalogDuration() async throws {
        let payload = try OfflineMediaFixture.validData()
        let record = try install(payload, metadata: metadata(duration: 7_200), expected: Int64(payload.count))
        let reopened = DownloadManifestStore(rootDirectory: store.rootDirectory)
        let saved = try XCTUnwrap(reopened.loadValidated().records.first)
        XCTAssertEqual(saved, record)
        XCTAssertTrue(saved.isReadyToWatch)
        XCTAssertEqual(saved.assetInspection?.integrity, .verified)
        XCTAssertEqual(saved.assetInspection?.audioTrackCount, 1)
        let asset = AVURLAsset(url: reopened.localURL(for: saved))
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.15, "Inspect actual local media instead of trusting stale catalog runtime")
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
    }

    func testDownloadedVideoInspectionDoesNotDependOnTemporaryFileExtension() throws {
        let payload = try OfflineMediaFixture.validData()
        for name in ["incoming.mp4", "incoming.tmp", UUID().uuidString] {
            let url = root.appendingPathComponent(name)
            try payload.write(to: url)
            let inspection = try store.inspectDownload(temporaryURL: url, metadata: metadata())
            XCTAssertEqual(inspection.integrity, .verified, "\(name): \(inspection)")
            XCTAssertEqual(inspection.playability, .playable, "\(name): \(inspection)")
        }
    }

    func testNonemptyGarbageFromSuccessfulBinaryResponseCannotBecomeReady() throws {
        let payload = Data(repeating: 0xA7, count: 4_096)
        XCTAssertThrowsError(try install(payload, metadata: metadata(), expected: Int64(payload.count))) {
            guard case DownloadStoreError.incompatibleDownload = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertTrue(try DownloadManifestStore(rootDirectory: store.rootDirectory).loadValidated().records.isEmpty)
    }

    func testTruncatedFastStartVideoCannotPassItsIntactHeaderAndRecordedByteCount() throws {
        let payload = try OfflineMediaFixture.validData()
        let truncated = Data(payload.prefix(payload.count / 2))
        // Expected bytes deliberately match what arrived: the media reader must
        // detect the incomplete samples, even when transport size checks pass.
        XCTAssertThrowsError(try install(truncated, metadata: metadata(), expected: Int64(truncated.count)))
        XCTAssertTrue(try DownloadManifestStore(rootDirectory: store.rootDirectory).loadValidated().records.isEmpty)
    }

    func testCompleteShortClipCannotSatisfyTrustworthyLargerHTTPContentLength() throws {
        let payload = try OfflineMediaFixture.validData()
        XCTAssertThrowsError(try install(payload, metadata: metadata(duration: 2), expected: Int64(payload.count + 4_096))) {
            guard case DownloadStoreError.incompleteDownload = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertTrue(try DownloadManifestStore(rootDirectory: store.rootDirectory).loadValidated().records.isEmpty)
    }

    func testUnsupportedOriginalSurvivesCompatibleCopyAndStoreReopen() throws {
        let originalPayload = try OfflineMediaFixture.unsupportedData()
        let original = try install(originalPayload, metadata: metadata(kind: .original))
        XCTAssertFalse(original.isReadyToWatch)
        XCTAssertEqual(original.assetInspection?.playability, .unsupported)
        XCTAssertNotNil(original.validationMessage)
        let compatible = try install(OfflineMediaFixture.validData(), metadata: metadata())
        let reopened = DownloadManifestStore(rootDirectory: store.rootDirectory)
        let saved = try reopened.loadValidated().records
        XCTAssertEqual(Set(saved.map(\.id)), Set([original.id, compatible.id]))
        XCTAssertEqual(try Data(contentsOf: reopened.localURL(for: original)), originalPayload)
        XCTAssertFalse(try XCTUnwrap(saved.first(where: { $0.id == original.id })).isReadyToWatch)
        XCTAssertTrue(try XCTUnwrap(saved.first(where: { $0.id == compatible.id })).isReadyToWatch)
    }

    func testCopiesForDifferentAccountsAndLegacyDuplicatesAreNeverDestructivelyMerged() throws {
        let payload = try OfflineMediaFixture.validData()
        let first = try install(payload, metadata: metadata(account: "first"))
        let second = try install(payload, metadata: metadata(account: "second"))
        let legacy = try install(payload, metadata: metadata(account: nil))
        let sameAccount = try install(payload, metadata: metadata(account: "first"))
        let records = try DownloadManifestStore(rootDirectory: store.rootDirectory).loadValidated().records
        XCTAssertEqual(Set(records.map(\.id)), Set([first.id, second.id, legacy.id, sameAccount.id]))
        for record in records {
            XCTAssertEqual(try Data(contentsOf: store.localURL(for: record)), payload)
        }
    }

    func testLegacyBytesAreUnverifiedUntilActualAssetReinspection() throws {
        let record = try install(OfflineMediaFixture.validData(), metadata: metadata())
        var legacy = record
        legacy.assetInspection = nil
        try store.stateStore.update { $0.records = [legacy] }
        let reopened = DownloadManifestStore(rootDirectory: store.rootDirectory)
        XCTAssertFalse(try XCTUnwrap(reopened.loadValidated().records.first).isReadyToWatch)
        XCTAssertTrue(try XCTUnwrap(reopened.revalidatePendingAssets().records.first).isReadyToWatch)
        XCTAssertTrue(try XCTUnwrap(DownloadManifestStore(rootDirectory: store.rootDirectory).loadValidated().records.first).isReadyToWatch)
    }

    func testDeletionUsingRecordShownBeforeInspectionStillDeletesCurrentRecord() throws {
        let record = try install(OfflineMediaFixture.validData(), metadata: metadata())
        var displayed = record
        displayed.assetInspection = nil
        try store.stateStore.update { $0.records = [displayed] }
        _ = try store.revalidatePendingAssets()
        try store.delete(displayed)
        XCTAssertTrue(try DownloadManifestStore(rootDirectory: store.rootDirectory).loadValidated().records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.localURL(for: displayed).path))
    }

    func testDuplicateCompletionKeepsOneRecordAndItsOriginalInstalledBytes() throws {
        let payload = try OfflineMediaFixture.validData()
        let request = metadata()
        let original = try install(payload, metadata: request)
        let duplicate = try install(payload, metadata: request)
        XCTAssertEqual(duplicate, original)
        XCTAssertEqual(try DownloadManifestStore(rootDirectory: store.rootDirectory).loadValidated().records, [original])
        XCTAssertEqual(try Data(contentsOf: store.localURL(for: original)), payload)
        let files = try FileManager.default.contentsOfDirectory(at: store.rootDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "mp4" }.count, 1)
    }

    func testSameSizeMutationInvalidatesInspectionAndCannotReturnReadyAfterReopen() throws {
        let record = try install(OfflineMediaFixture.validData(), metadata: metadata())
        let file = store.localURL(for: record)
        try Data(repeating: 0xA7, count: Int(record.byteCount)).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: file.path)
        let reopened = DownloadManifestStore(rootDirectory: store.rootDirectory)
        XCTAssertFalse(try XCTUnwrap(reopened.loadValidated().records.first).isReadyToWatch)
        XCTAssertFalse(try XCTUnwrap(reopened.revalidatePendingAssets().records.first).isReadyToWatch)
        XCTAssertFalse(try XCTUnwrap(DownloadManifestStore(rootDirectory: store.rootDirectory).loadValidated().records.first).isReadyToWatch)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Legacy stored bytes remain available for explicit recovery")
    }

    func testIncomingOriginalSymbolicLinkIsRejectedWithoutTouchingItsTarget() throws {
        let payload = try OfflineMediaFixture.validData()
        let outside = root.appendingPathComponent("outside.mp4")
        try payload.write(to: outside)
        let incoming = root.appendingPathComponent("incoming.webm")
        try FileManager.default.createSymbolicLink(at: incoming, withDestinationURL: outside)
        XCTAssertThrowsError(try store.install(temporaryURL: incoming, metadata: metadata(kind: .original))) {
            guard case DownloadStoreError.invalidDownloadedFile = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: outside), payload)
        XCTAssertTrue(try DownloadManifestStore(rootDirectory: store.rootDirectory).loadValidated().records.isEmpty)
    }

    private func install(_ payload: Data, metadata: DownloadTaskMetadata, expected: Int64? = nil) throws -> DownloadRecord {
        let incoming = root.appendingPathComponent(UUID().uuidString)
        try payload.write(to: incoming)
        return try store.install(temporaryURL: incoming, metadata: metadata, expectedByteCount: expected)
    }

    private func metadata(kind: DownloadKind = .compatible, duration: Int = 2, account: String? = "fixture") -> DownloadTaskMetadata {
        DownloadTaskMetadata(
            recordID: UUID(), serverOrigin: "https://media.example.test", mediaID: "42042",
            title: "The Synthetic Meridian", kind: kind,
            fileExtension: kind == .original ? "webm" : "mp4", durationSeconds: duration,
            resolution: "96x64", accountUsername: account
        )
    }
}
