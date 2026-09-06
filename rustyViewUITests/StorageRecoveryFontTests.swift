import CryptoKit
import Network
import UIKit
import XCTest

/// Faults affect real files shared with the Simulator app, never observable UI
/// state. Each case owns its namespace, background sessions and temporary root.
/// Default and Extra Large text cover the normal-size recovery journey.
@MainActor
final class StorageRecoveryFontTests: XCTestCase {
    private var app: XCUIApplication?
    private var server: StorageRecoveryHTTPServer?
    private var temporaryRoot: URL?

    override func setUp() { continueAfterFailure = false }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0, let app {
            attach(app.screenshot(), name: "Synthetic storage recovery failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Synthetic storage recovery hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app?.terminate()
        server?.stop()
        if let temporaryRoot { try FileManager.default.removeItem(at: temporaryRoot) }
        XCUIDevice.shared.orientation = .portrait
    }

    func testStorageRecoveryLarge() throws { try exercise(.large, name: "Default") }
    func testStorageRecoveryExtraLarge() throws { try exercise(.extraLarge, name: "XL") }

    private func exercise(_ category: UIContentSizeCategory, name: String) throws {
        let files = FileManager.default
        let namespace = UUID().uuidString.lowercased()
        let parent = files.temporaryDirectory.appendingPathComponent("rustyView-storage-ui-\(UUID())", isDirectory: true)
        temporaryRoot = parent
        let root = parent.appendingPathComponent(namespace, isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let stateURL = downloads.appendingPathComponent("state.json")
        let libraryURL = root.appendingPathComponent("UserLibrary/library.json")
        try files.createDirectory(at: downloads, withIntermediateDirectories: true)
        let movie = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-native-caption", withExtension: "mp4"))
        let movieBytes = try Data(contentsOf: movie)
        let movieURL = downloads.appendingPathComponent("offline-\(UUID().uuidString).mp4")
        try movieBytes.write(to: movieURL)
        let corruptIndex = Data("Synthetic interrupted index {".utf8)
        try corruptIndex.write(to: stateURL)

        let server = try StorageRecoveryHTTPServer()
        self.server = server
        let app = XCUIApplication()
        self.app = app
        app.launchArguments = ["-AppleInterfaceStyle", "Light", "-UIPreferredContentSizeCategoryName", category.rawValue]
        app.launchEnvironment = [
            "RUSTYVIEW_TEST_NAMESPACE": namespace,
            "RUSTYVIEW_TEST_STORAGE_ROOT": parent.path,
            "RUSTYVIEW_TEST_SERVER": server.address,
            "RUSTYVIEW_TEST_USERNAME": "storage-viewer",
            "RUSTYVIEW_TEST_PASSWORD": "synthetic-storage-password",
        ]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        try awaitCondition("The app must save its real library index in the shared test root") {
            files.fileExists(atPath: libraryURL.path)
        }
        let savedLibrary = try Data(contentsOf: libraryURL)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: savedLibrary) as? [String: Any])
        try waitForEmptyCatalog(in: app)
        app.tabBars.buttons["Downloads"].tap()

        // The production index-recovery action inspects an actual orphaned MP4
        // and creates the first legitimate snapshot. No record JSON is seeded.
        try openBanner("download-storage-recovery", title: "Downloads need attention", in: app)
        try inspectSheet("Downloads need attention", message: "The offline library index is damaged.",
                         actions: ["Recover Saved Files"], font: name, state: "damaged-download-index", in: app)
        try tap("Recover Saved Files", in: app)
        try awaitCondition("Recovery must publish a playable local copy and dismiss its sheet") {
            !app.navigationBars["Downloads need attention"].exists && self.playButton(in: app).exists
        }
        let savedDownloads = try Data(contentsOf: stateURL)
        let snapshot = try XCTUnwrap(try JSONSerialization.jsonObject(with: savedDownloads) as? [String: Any])
        let records = try XCTUnwrap(snapshot["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1)
        let recoveredID = try XCTUnwrap(records.first?["id"] as? String)
        XCTAssertEqual(records.first?["title"] as? String, "Recovered movie")
        let preservedIndexes = try files.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("recovered-index-") && $0.lastPathComponent.hasSuffix("-state.json") }
        XCTAssertTrue(try preservedIndexes.contains { try Data(contentsOf: $0) == corruptIndex })
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: movieURL)), SHA256.hash(data: movieBytes))

        // Relaunch after corrupting the real, previously saved library index.
        // Denied file access must offer retry, not destructive index recovery.
        app.terminate()
        try corruptIndex.write(to: libraryURL, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: stateURL.path)
        XCTAssertThrowsError(try Data(contentsOf: stateURL), "The fixture must cause a real read-permission failure")
        app.launch()
        try waitForEmptyCatalog(in: app)
        try openBanner("user-library-recovery", title: "Changes not saved", in: app)
        let libraryMessage = "Your saved library could not be read. Its file has been preserved. Try again after restoring storage access."
        try inspectSheet("Changes not saved", message: libraryMessage, actions: ["Manage Storage", "Retry"],
                         font: name, state: "unreadable-saved-library", in: app)
        try tap("Retry", in: app)
        try assertRetryFailedWithoutAlert(title: "Changes not saved", retry: "Retry", in: app)
        XCTAssertEqual(try Data(contentsOf: libraryURL), corruptIndex, "Retry must preserve the unreadable index")

        try tap("Manage Storage", in: app)
        try awaitCondition("Manage Storage must close the sheet and select Downloads") {
            !app.navigationBars["Changes not saved"].exists && app.tabBars.buttons["Downloads"].isSelected
        }
        try openBanner("user-library-recovery", title: "Changes not saved", in: app)
        try savedLibrary.write(to: libraryURL, options: .atomic)
        try tap("Retry", in: app)
        try awaitCondition("Retry must reload the restored bytes and remove the persistent error") {
            !app.buttons["user-library-recovery"].exists && !app.navigationBars["Changes not saved"].exists
        }
        XCTAssertEqual(try Data(contentsOf: libraryURL), savedLibrary)

        try openBanner("download-storage-recovery", title: "Downloads need attention", in: app)
        try inspectSheet("Downloads need attention",
                         message: "The saved files could not be read or updated. Check device storage, then retry. Your existing movies are preserved.",
                         actions: ["Retry Loading Downloads"], font: name, state: "denied-download-read", in: app)
        XCTAssertFalse(app.buttons["Recover Saved Files"].exists)
        try tap("Retry Loading Downloads", in: app)
        try assertRetryFailedWithoutAlert(title: "Downloads need attention", retry: "Retry Loading Downloads", in: app)
        XCTAssertThrowsError(try Data(contentsOf: stateURL))
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        XCTAssertEqual(try Data(contentsOf: stateURL), savedDownloads)
        try tap("Retry Loading Downloads", in: app)
        try awaitCondition("Storage retry must restore the same playable record") {
            !app.navigationBars["Downloads need attention"].exists && app.buttons["play-download-\(recoveredID)"].exists
        }
        XCTAssertFalse(app.buttons["download-storage-recovery"].exists)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: movieURL)), SHA256.hash(data: movieBytes))
        let requestsBeforePlayback = server.authorizedRequests
        let play = app.buttons["play-download-\(recoveredID)"]
        try reveal(play, in: app)
        try assertTarget(play, in: app)
        play.tap()
        let time = app.descendants(matching: .any).matching(identifier: "player-time-label").firstMatch
        try awaitCondition("The recovered file must actually advance in AVPlayer") {
            guard let value = time.value as? String, let seconds = Int(value.split(separator: " ").first ?? "") else { return false }
            return seconds >= 1
        }
        XCTAssertEqual(server.authorizedRequests, requestsBeforePlayback, "Recovered offline playback must not request the catalog")
        attach(app.screenshot(), name: "Synthetic-storage-\(name)-recovered-playback")
        app.buttons["Close player"].tap()
        app.terminate()
    }

    private func playButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-download-'")).firstMatch
    }

    private func waitForEmptyCatalog(in app: XCUIApplication) throws {
        try awaitCondition("The real authenticated empty catalog must load") {
            app.staticTexts["No movies yet"].exists && (self.server?.authorizedRequests ?? 0) > 0
        }
    }

    private func openBanner(_ identifier: String, title: String, in app: XCUIApplication) throws {
        let banner = app.buttons[identifier]
        try awaitCondition("The actual disk failure must expose \(identifier)") { banner.exists }
        try reveal(banner, in: app)
        try assertTarget(banner, in: app)
        banner.tap()
        try awaitCondition("The recovery details must open") { app.navigationBars[title].exists }
    }

    private func inspectSheet(_ title: String, message: String, actions: [String], font: String,
                              state: String, in app: XCUIApplication) throws {
        let text = app.staticTexts[message]
        try awaitCondition("The real storage explanation must remain available") { text.exists }
        let bounds = app.frame
        XCTAssertGreaterThan(text.frame.height, 0)
        XCTAssertGreaterThanOrEqual(text.frame.minX, bounds.minX)
        XCTAssertLessThanOrEqual(text.frame.maxX, bounds.maxX)
        attach(app.screenshot(), name: "Synthetic-storage-\(font)-\(state)-explanation")
        for action in actions {
            let button = app.buttons[action]
            try reveal(button, in: app)
            try assertTarget(button, in: app)
            attach(app.screenshot(), name: "Synthetic-storage-\(font)-\(state)-\(action)")
        }
        XCTAssertTrue(app.navigationBars[title].buttons["Done"].isHittable)
    }

    private func assertRetryFailedWithoutAlert(title: String, retry: String, in app: XCUIApplication) throws {
        try awaitCondition("A failed retry must leave its existing recovery action available") {
            app.navigationBars[title].exists && app.buttons[retry].isEnabled
        }
        XCTAssertEqual(app.alerts.count, 0, "The recovery sheet must not present a duplicate modal error")
    }

    private func tap(_ title: String, in app: XCUIApplication) throws {
        let button = app.buttons[title]
        try reveal(button, in: app)
        try assertTarget(button, in: app)
        button.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) throws {
        try awaitCondition("The action must exist: \(element.identifier)") { element.exists }
        let visible = { self.visibleBounds(in: app) }
        for _ in 0..<10 {
            if element.isHittable && visible().insetBy(dx: -1, dy: -1).contains(element.frame) { return }
            let scroll = app.scrollViews.allElementsBoundByIndex.last(where: { $0.isHittable }) ?? app.scrollViews.firstMatch
            let bounds = visible()
            let down = element.frame.minY < bounds.minY
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: bounds.midX, dy: bounds.minY + bounds.height * (down ? 0.3 : 0.7)))
            let end = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: bounds.midX, dy: bounds.minY + bounds.height * (down ? 0.7 : 0.3)))
            if scroll.exists { start.press(forDuration: 0.05, thenDragTo: end) }
        }
        XCTFail("Scrolling did not reveal the complete recovery action: \(element.label)")
        throw StorageFixtureError.failed
    }

    private func visibleBounds(in app: XCUIApplication) -> CGRect {
        var bounds = app.frame
        if let navigation = app.navigationBars.allElementsBoundByIndex.last(where: { $0.isHittable }) {
            bounds.origin.y = navigation.frame.maxY
            bounds.size.height = app.frame.maxY - bounds.minY
        }
        if let tabs = app.tabBars.allElementsBoundByIndex.last(where: { $0.isHittable }) {
            bounds.size.height = min(bounds.height, tabs.frame.minY - bounds.minY)
        }
        return bounds
    }

    private func assertTarget(_ element: XCUIElement, in app: XCUIApplication) throws {
        XCTAssertTrue(element.isHittable)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44 - 0.01)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44 - 0.01)
        XCTAssertTrue(visibleBounds(in: app).insetBy(dx: -1, dy: -1).contains(element.frame))
    }

    private func awaitCondition(_ message: String, timeout: TimeInterval = 8, _ condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail(message)
            throw StorageFixtureError.failed
        }
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum StorageFixtureError: Error { case failed }

/// Only a real, authenticated empty catalog is needed by the recovery journey.
private final class StorageRecoveryHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "synthetic.storage-recovery")
    private let lock = NSLock()
    private var authorized = 0
    private var connections: [UUID: NWConnection] = [:]
    private(set) var address = ""
    var authorizedRequests: Int { lock.lock(); defer { lock.unlock() }; return authorized }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.connections.count < 16 else { connection.cancel(); return }
            let id = UUID()
            self.connections[id] = connection
            connection.start(queue: self.queue)
            self.read(connection, id: id, bytes: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success else { throw StorageFixtureError.failed }
        if let failure { throw failure }
        guard let port = listener.port else { throw StorageFixtureError.failed }
        address = "http://127.0.0.1:\(port.rawValue)"
    }

    func stop() {
        listener.cancel()
        queue.sync {
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    private func read(_ connection: NWConnection, id: UUID, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, ended, error in
            guard let self else { connection.cancel(); return }
            var accumulated = bytes
            if let data { accumulated.append(data) }
            guard accumulated.count <= 32_768 else { self.close(connection, id: id); return }
            if let header = String(data: accumulated, encoding: .utf8), header.contains("\r\n\r\n") {
                let expected = "Basic " + Data("storage-viewer:synthetic-storage-password".utf8).base64EncodedString()
                let authorized = header.components(separatedBy: "\r\n").contains {
                    $0.lowercased().hasPrefix("authorization:") && $0.split(separator: ":", maxSplits: 1).last?
                        .trimmingCharacters(in: .whitespaces) == expected
                }
                self.lock.lock()
                if authorized { self.authorized += 1 }
                self.lock.unlock()
                let body = Data((authorized ? Self.catalog : "{}").utf8)
                let challenge = authorized ? "" : "WWW-Authenticate: Basic realm=\"Synthetic storage\"\r\n"
                var reply = Data("HTTP/1.1 \(authorized ? 200 : 401) Synthetic\r\n\(challenge)Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                reply.append(body)
                connection.send(content: reply, completion: .contentProcessed { _ in self.close(connection, id: id) })
            } else if ended || error != nil { self.close(connection, id: id) }
            else { self.read(connection, id: id, bytes: accumulated) }
        }
    }

    private func close(_ connection: NWConnection, id: UUID) {
        connections.removeValue(forKey: id)
        connection.cancel()
    }

    private static let catalog = #"""
    {"schema_version":2,"generation":1,"server_name":"Synthetic Storage Library","root_folder_id":"root",
     "capabilities":{"transcoding":false,"captions":false,"quality_profiles":[]},"library_state":"ready",
     "view":"library","folder":null,"breadcrumbs":[],"offset":0,"limit":60,"total":0,"has_more":false,
     "query":"","sort":"title","entries":[]}
    """#
}
