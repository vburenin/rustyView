import AVFoundation
import XCTest
@testable import rustyView

final class DownloadMovieGroupTests: XCTestCase {
    func testTwoRealRenditionsShareOneMovieAfterRelaunchAndDeleteOnlyTheSelectedCopy() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("saved"))
        let compatible = try install(store, root: root, kind: .compatible)
        let original = try install(store, root: root, kind: .original, unsupported: true,
                                   origin: "HTTPS://synthetic.example.test:443/library/")
        let reopened = DownloadManifestStore(rootDirectory: store.rootDirectory)
        let groups = DownloadMovieGroup.collect(records: try reopened.loadValidated().records, transfers: [])
        let movie = try XCTUnwrap(groups.first)
        XCTAssertEqual(groups.count, 1, "Canonical identity groups the original and compatible file into one collection row")
        XCTAssertEqual(Set(movie.records.map(\.id)), [original.id, compatible.id])
        XCTAssertEqual(movie.readyRecord?.id, compatible.id, "A newer unsupported original must not displace the ready copy")
        let asset = AVURLAsset(url: reopened.localURL(for: try XCTUnwrap(movie.readyRecord)))
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.15)

        try reopened.delete(compatible)
        let remaining = DownloadMovieGroup.collect(records: try DownloadManifestStore(rootDirectory: store.rootDirectory).loadValidated().records, transfers: [])
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, movie.id, "Deleting one rendition must preserve the movie's stable group identity")
        XCTAssertEqual(remaining.first?.records.map(\.id), [original.id])
        XCTAssertNil(remaining.first?.readyRecord)
        XCTAssertEqual(try Data(contentsOf: reopened.localURL(for: original)), try OfflineMediaFixture.unsupportedData())
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.localURL(for: compatible).path))
    }

    func testEqualTitlesDoNotMergeDifferentMoviesAccountsServersOrUnassignedLegacyCopies() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("saved"))
        let first = try install(store, root: root, kind: .original)
        let otherMovie = try install(store, root: root, kind: .original, mediaID: "900719925474099312346")
        let otherAccount = try install(store, root: root, kind: .original, account: "second-viewer")
        let otherServer = try install(store, root: root, kind: .original, origin: "https://elsewhere.example.test/library")
        let unassigned = try install(store, root: root, kind: .original, account: nil)
        let groups = DownloadMovieGroup.collect(records: try DownloadManifestStore(rootDirectory: store.rootDirectory).loadValidated().records, transfers: [])
        XCTAssertEqual(groups.count, 5, "Identical display titles are not evidence of the same movie or ownership")
        XCTAssertEqual(Set(groups.flatMap { $0.records.map(\.id) }), [first.id, otherMovie.id, otherAccount.id, otherServer.id, unassigned.id])
        XCTAssertEqual(groups.first { $0.key.accountUsername == nil }?.records.map(\.id), [unassigned.id])
        XCTAssertTrue(groups.allSatisfy { $0.records.count == 1 })
    }

    func testInstallingCopyDoesNotTemporarilyDoubleCountItsStillPublishedTransfer() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadManifestStore(rootDirectory: root.appendingPathComponent("saved"))
        let finished = try install(store, root: root, kind: .compatible)
        let metadata = metadata(id: finished.id, kind: .compatible)
        let lateActive = ActiveDownload(id: finished.id, serverOrigin: finished.serverOrigin, mediaID: finished.mediaID,
            title: finished.title, kind: finished.kind, phase: .finishing, taskIdentifier: 73, metadata: metadata)
        let pendingMetadata = self.metadata(kind: .original)
        let pendingOriginal = ActiveDownload(id: pendingMetadata.recordID, serverOrigin: pendingMetadata.serverOrigin,
            mediaID: pendingMetadata.mediaID, title: pendingMetadata.title, kind: .original,
            phase: .downloading(progress: 0.3, received: 30, expected: 100), taskIdentifier: 74, metadata: pendingMetadata)
        // This is the public-array overlap while completion is published and
        // the old transfer callback is still being retired. The file is real.
        let groups = DownloadMovieGroup.collect(records: try store.loadValidated().records, transfers: [lateActive, pendingOriginal])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.copyCount, 2)
        XCTAssertEqual(groups.first?.transfers.map(\.id), [pendingOriginal.id])
        XCTAssertEqual(groups.first?.readyRecord?.id, finished.id)
        XCTAssertEqual(try Data(contentsOf: store.localURL(for: finished)), try OfflineMediaFixture.validData())
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func metadata(id: UUID = UUID(), kind: DownloadKind, origin: String = "https://synthetic.example.test/library",
                          account: String? = "viewer", mediaID: String = "900719925474099312345", unsupported: Bool = false) -> DownloadTaskMetadata {
        DownloadTaskMetadata(recordID: id, serverOrigin: origin, mediaID: mediaID, title: "The Painted Paper Observatory",
            kind: kind, fileExtension: unsupported ? "webm" : "mp4", durationSeconds: 7200, resolution: "640x360", accountUsername: account)
    }

    private func install(_ store: DownloadManifestStore, root: URL, kind: DownloadKind, unsupported: Bool = false,
                         origin: String = "https://synthetic.example.test/library", account: String? = "viewer",
                         mediaID: String = "900719925474099312345") throws -> DownloadRecord {
        let data = try (unsupported ? OfflineMediaFixture.unsupportedData() : OfflineMediaFixture.validData())
        let incoming = root.appendingPathComponent(UUID().uuidString)
        try data.write(to: incoming)
        return try store.install(temporaryURL: incoming,
            metadata: metadata(kind: kind, origin: origin, account: account, mediaID: mediaID, unsupported: unsupported),
            expectedByteCount: Int64(data.count))
    }
}
