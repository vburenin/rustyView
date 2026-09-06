import Foundation
import XCTest
@testable import rustyView

@MainActor
final class BackgroundOriginTests: XCTestCase {
    /// Background sessions bypass the ordinary redirect callback. A real TLS
    /// listener must prove origin rejection before any hostile HTTP request.
    func testBackgroundTLSRedirectCannotReachAnotherOrigin() async throws {
        try await checkRedirect(warmingForeignOrigin: false)
    }

    /// A TLS check on connection creation cannot protect a request that reuses
    /// another origin's already trusted connection in a shared session.
    func testBackgroundRedirectCannotReuseAnotherOriginsWarmConnection() async throws {
        try await checkRedirect(warmingForeignOrigin: true)
    }

    private func checkRedirect(warmingForeignOrigin: Bool) async throws {
        let descriptor = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HTTPSOriginFixture.json")
        guard FileManager.default.fileExists(atPath: descriptor.path) else {
            throw XCTSkip("Start scripts/https_origin_fixture.py on the dedicated test iPhone for real background TLS verification.")
        }
        let fixture = try JSONDecoder().decode(TLSFixture.self, from: Data(contentsOf: descriptor))
        let trusted = try XCTUnwrap(URL(string: fixture.trusted))
        let hostile = try XCTUnwrap(URL(string: fixture.hostile))
        XCTAssertEqual(trusted.scheme, "https")
        XCTAssertEqual(trusted.host, "127.0.0.1")
        XCTAssertEqual(hostile.host, "127.0.0.1")
        XCTAssertNotEqual(trusted.port, hostile.port)
        guard trusted.scheme == "https", trusted.host == "127.0.0.1",
              hostile.scheme == "https", hostile.host == "127.0.0.1" else { return }
        let caseID = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tls-origin-\(caseID)")
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = try ServerConnection(serverAddress: fixture.trusted,
                                              username: "tls-viewer", password: "synthetic-tls-secret")
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(connection)
        let manager = DownloadManager(store: DownloadManifestStore(rootDirectory: root),
                                      sessionIdentifier: "tls-origin.\(caseID)")
        manager.configure(connection: connection, statusClient: client)
        defer { manager.active.forEach { manager.cancel($0) } }

        // First prove this trusted origin works in the actual background
        // transport, with valid media, OS certificate validation and Basic auth.
        try manager.start(item: try item(id: "72001", path: "/media?case=\(caseID)"), kind: .original, client: client)
        await manager.waitForPendingOperations()
        try await waitUntil {
            manager.completed.count == 1 || manager.active.contains { if case .failed = $0.phase { return true }; return false }
        }
        XCTAssertTrue(manager.completed.first?.isReadyToWatch == true,
                      "Trusted TLS background transfer must install the actual synthetic video before confinement is assessed")
        guard manager.completed.first?.isReadyToWatch == true else { return }

        var expectedIDs: Set<String> = ["72001"]
        if warmingForeignOrigin {
            let another = try ServerConnection(serverAddress: fixture.hostile,
                                               username: "tls-viewer", password: "synthetic-tls-secret")
            let anotherClient = RustyDLNAClient(configuration: .ephemeral)
            anotherClient.configure(another)
            manager.configure(connection: another, statusClient: anotherClient)
            try manager.start(item: try item(id: "72003", path: "/media?case=\(caseID)"), kind: .original, client: anotherClient)
            await manager.waitForPendingOperations()
            try await waitUntil { manager.completed.count == 2 }
            XCTAssertTrue(manager.completed.contains { $0.mediaID == "72003" && $0.isReadyToWatch })
            expectedIDs.insert("72003")
            manager.configure(connection: connection, statusClient: client)
        }
        let beforeData = try await client.data(serverPath: "/observations?case=\(caseID)")
        let before = try JSONDecoder().decode([String: Int].self, from: beforeData)

        try manager.start(item: try item(id: "72002", path: "/redirect?case=\(caseID)"), kind: .original, client: client)
        await manager.waitForPendingOperations()
        try await waitUntil {
            manager.completed.count > expectedIDs.count || manager.active.contains { if case .failed = $0.phase { return true }; return false }
        }
        let data = try await client.data(serverPath: "/observations?case=\(caseID)")
        let counts = try JSONDecoder().decode([String: Int].self, from: data)
        XCTAssertGreaterThanOrEqual(counts["trustedRequests"] ?? 0, 2)
        XCTAssertGreaterThanOrEqual(counts["trustedCredentials"] ?? 0, 2)
        XCTAssertEqual(counts["hostileRequests"] ?? 0, before["hostileRequests"] ?? 0,
                       "Rejecting a foreign final file is insufficient: the redirected HTTP request must be prevented")
        XCTAssertEqual(counts["hostileCredentials"] ?? 0, before["hostileCredentials"] ?? 0,
                       "Credentials must never reach the foreign origin")
        XCTAssertEqual(Set(manager.completed.map(\.mediaID)), expectedIDs)
        XCTAssertTrue(manager.active.contains { download in
            guard download.mediaID == "72002", case .failed = download.phase else { return false }
            return true
        })
        for download in manager.active { manager.cancel(download) }
        await manager.waitForPendingOperations()
    }

    private func item(id: String, path: String) throws -> MediaItem {
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)) as? [String: Any])
        var item = try XCTUnwrap(envelope["item"] as? [String: Any])
        item["id"] = id
        item["title"] = "The TLS Paper Observatory"
        item["download_url"] = path
        item["ext"] = "mp4"
        item["mime"] = "video/mp4"
        item["container"] = "mp4"
        item["size_bytes"] = try OfflineMediaFixture.validData().count
        item["duration_seconds"] = 2
        item["captions"] = []
        item["audio_tracks"] = []
        item["chapters"] = []
        item["art_url"] = NSNull()
        envelope["item"] = item
        envelope["id"] = id
        return try JSONDecoder().decode(ItemResponse.self, from: JSONSerialization.data(withJSONObject: envelope)).item
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(predicate(), "Background TLS transport did not reach an actionable terminal state")
    }
}

private struct TLSFixture: Decodable {
    let trusted: String
    let hostile: String
}
