import Foundation
import XCTest
@testable import rustyView

@MainActor
final class MovieMetadataCacheTests: XCTestCase {
    func testCachedDetailsSurviveReopenAndEquivalentConnectionEditsWithoutCrossingAccounts() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try connection("https://MEDIA.example.test:443/library/", username: "first-viewer")
        let second = try connection("https://media.example.test/library", username: "second-viewer")
        var movie = MovieMetadata(mediaID: "18446744073709551615", title: "The Glass Orchard", durationSeconds: 3600)
        movie.summary = "A paper astronomer follows a map of imaginary moons."
        movie.chapters = [MovieChapter(id: 0, title: "The Clockwork Gate", startSeconds: 0, endSeconds: 300)]
        let store = MovieMetadataCache(directory: root)
        store.store(movie, connection: first)
        var another = movie
        another.title = "The Paper Harbor"
        store.store(another, connection: second)
        await store.waitForPendingWrites()

        let reopened = MovieMetadataCache(directory: root)
        await reopened.waitUntilRestored()
        let equivalent = try connection("HTTPS://media.example.test/library///", username: "first-viewer")
        XCTAssertEqual(reopened.movie(for: MovieLibraryKey(connection: equivalent, mediaID: movie.mediaID)), movie)
        XCTAssertEqual(reopened.movie(for: MovieLibraryKey(connection: second, mediaID: movie.mediaID)), another)
        XCTAssertNil(reopened.movie(for: MovieLibraryKey(serverIdentity: first.serverIdentity, accountUsername: nil, mediaID: movie.mediaID)))
        let elsewhere = try connection("https://media.example.test/other-library", username: "first-viewer")
        XCTAssertNil(reopened.movie(for: MovieLibraryKey(connection: elsewhere, mediaID: movie.mediaID)))
    }

    func testDiskRestorationCannotReplaceNewlyRefreshedDetails() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = try connection("https://media.example.test", username: "viewer")
        let original = MovieMetadata(mediaID: "42", title: "The Tin Observatory")
        let first = MovieMetadataCache(directory: root)
        first.store(original, connection: connection)
        await first.waitForPendingWrites()

        let reopened = MovieMetadataCache(directory: root)
        var refreshed = original
        refreshed.summary = "A recently repaired telescope finds a synthetic constellation."
        reopened.store(refreshed, connection: connection)
        await reopened.waitForPendingWrites()
        let final = MovieMetadataCache(directory: root)
        await final.waitUntilRestored()
        XCTAssertEqual(final.movie(for: MovieLibraryKey(connection: connection, mediaID: "42")), refreshed)
    }

    func testCacheEvictionIsBoundedAndDoesNotTouchOfflineFiles() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let unrelated = root.appendingPathComponent("retained-offline-bytes.mp4")
        let bytes = Data("synthetic existing file".utf8)
        try bytes.write(to: unrelated)
        let connection = try connection("https://media.example.test", username: "viewer")
        let store = MovieMetadataCache(directory: root, maximumEntries: 2)
        for id in ["41", "42", "43"] {
            store.store(MovieMetadata(mediaID: id, title: "Synthetic Observatory \(id)"), connection: connection)
        }
        await store.waitForPendingWrites()
        let reopened = MovieMetadataCache(directory: root, maximumEntries: 2)
        await reopened.waitUntilRestored()
        XCTAssertNil(reopened.movie(for: MovieLibraryKey(connection: connection, mediaID: "41")))
        XCTAssertNotNil(reopened.movie(for: MovieLibraryKey(connection: connection, mediaID: "42")))
        XCTAssertNotNil(reopened.movie(for: MovieLibraryKey(connection: connection, mediaID: "43")))
        XCTAssertEqual(try Data(contentsOf: unrelated), bytes)
    }

    private func connection(_ address: String, username: String) throws -> ServerConnection {
        try ServerConnection(serverAddress: address, username: username, password: "synthetic-secret")
    }
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("movie-cache-\(UUID().uuidString)")
    }
}
