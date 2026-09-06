import Foundation
import XCTest
@testable import rustyView

final class LibraryIdentityTests: XCTestCase {
    // Previously the absolute URL strings produced different download/progress keys,
    // even though authentication treated them as the same origin.
    func testEquivalentConnectionEditsPreserveIdentityAndResolvedRequests() throws {
        let addresses = [
            "https://MEDIA.example.test:443/library/",
            "HTTPS://media.example.test/library",
            "https://media.example.test/library///",
        ]
        let connections = try addresses.map {
            try ServerConnection(serverAddress: $0, username: "viewer", password: "synthetic-secret")
        }
        for connection in connections {
            XCTAssertEqual(connection.serverIdentity, "https://media.example.test/library")
            XCTAssertEqual(try connection.resolve(serverPath: "/api/web/item/42"),
                           URL(string: "https://media.example.test/api/web/item/42"))
            XCTAssertTrue(connection.owns(serverIdentity: addresses[0], accountUsername: "viewer"))
        }
    }

    func testOwnershipNeverAdoptsLegacyOrOtherAccountWork() throws {
        let connection = try ServerConnection(serverAddress: "https://media.example.test/library",
                                              username: "viewer", password: "synthetic-secret")
        XCTAssertFalse(connection.owns(serverIdentity: connection.serverIdentity, accountUsername: nil))
        XCTAssertFalse(connection.owns(serverIdentity: connection.serverIdentity, accountUsername: "second-viewer"))
        XCTAssertFalse(connection.owns(serverIdentity: "https://media.example.test/another-library", accountUsername: "viewer"))
        XCTAssertFalse(connection.owns(serverIdentity: "https://other.example.test/library", accountUsername: "viewer"))
        XCTAssertFalse(connection.owns(serverIdentity: "https://media.example.test:444/library", accountUsername: "viewer"))
        XCTAssertNotEqual(ServerIdentity.canonical("https://media.example.test/library%2F"), connection.serverIdentity,
                          "An escaped path character is not a deployment-path delimiter")
    }

    func testLegacyProgressMigrationPreservesNewestUnassignedPositionWithoutClaimingIt() throws {
        let suite = "IdentityMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Original on-disk schema, with competing historical URL spellings.
        let json = #"[{"serverOrigin":"https://MEDIA.example.test:443/","mediaID":"42","position":300,"duration":3600,"updatedAt":100},{"serverOrigin":"https://media.example.test","mediaID":"42","position":600,"duration":3600,"updatedAt":200}]"#
        defaults.set(Data(json.utf8), forKey: "playbackProgress.v1")
        let store = PlaybackProgressStore(defaults: defaults)
        XCTAssertEqual(store.resumePosition(serverOrigin: "https://media.example.test/", mediaID: "42"), 600)
        XCTAssertNil(store.resumePosition(serverOrigin: "https://media.example.test", mediaID: "42", accountUsername: "viewer"))
        store.update(serverOrigin: "https://MEDIA.example.test:443", mediaID: "42", position: 900, duration: 3600, accountUsername: "viewer")
        let reopened = PlaybackProgressStore(defaults: defaults)
        XCTAssertEqual(reopened.resumePosition(serverOrigin: "https://media.example.test/", mediaID: "42", accountUsername: "viewer"), 900)
        XCTAssertNil(reopened.resumePosition(serverOrigin: "https://media.example.test", mediaID: "42", accountUsername: "second-viewer"))
        XCTAssertEqual(reopened.resumePosition(serverOrigin: "https://media.example.test", mediaID: "42"), 600)
        reopened.clear(serverOrigin: "https://MEDIA.example.test:443/", mediaID: "42", accountUsername: "viewer")
        XCTAssertNil(reopened.resumePosition(serverOrigin: "https://media.example.test", mediaID: "42", accountUsername: "viewer"))
        XCTAssertEqual(reopened.resumePosition(serverOrigin: "https://media.example.test", mediaID: "42"), 600)
    }
}
