import Network
import XCTest

/// Drives the Apple TV app with real Siri Remote events against an in-process,
/// Basic-authenticated server. Media is the generated H.264/AAC UI fixture, so
/// every position assertion reads actual AVPlayer progress through the relay.
final class TVPlaybackJourneyTests: XCTestCase {
    private var server: TVSyntheticServer?
    private var namespace = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        namespace = UUID().uuidString.lowercased()
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-playback", withExtension: "mp4"))
        server = try TVSyntheticServer(media: Data(contentsOf: media))
        try server?.start()
    }

    override func tearDown() {
        if (testRun?.failureCount ?? 0) > 0 {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Apple TV UI at failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: XCUIApplication().debugDescription)
            hierarchy.name = "Apple TV hierarchy at failure"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let requests = XCTAttachment(string: server?.requestSummary ?? "")
            requests.name = "Synthetic requests"
            requests.lifetime = .keepAlways
            add(requests)
        }
        XCUIApplication().terminate()
        server?.stop()
        server = nil
        super.tearDown()
    }

    func testRemoteBrowsesPlaysSkipsScrubsAndResumesAMovie() throws {
        let app = try launch()
        let remote = XCUIRemote.shared

        let card = app.buttons["library-card-42001"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The authenticated library grid must load")
        // The focus engine enters the grid at the poster nearest the tab bar.
        let focusedCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library-card-' AND hasFocus == true"))
        for _ in 0..<4 where focusedCard.count == 0 {
            remote.press(.down)
            _ = wait(timeout: 1) { focusedCard.count > 0 }
        }
        try moveFocus(to: card, pressing: .left)
        remote.press(.select)

        let watch = app.buttons["detail-watch"]
        XCTAssertTrue(watch.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(timeout: 10) { watch.isEnabled && watch.hasFocus },
                      "Watch must become the focused default once the item loads")
        remote.press(.select)

        let scrubber = app.buttons["playback-scrubber"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10), "Playback opens with its controls visible")
        XCTAssertTrue(wait(timeout: 20) { (self.elapsed(scrubber) ?? 0) >= 2 },
                      "Actual decoded playback must advance through the authenticated relay")

        // Menu hides the controls; the hidden surface then turns a right
        // press into a real ten-second seek.
        remote.press(.menu)
        let surface = app.buttons["player-surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        XCTAssertFalse(scrubber.exists)
        remote.press(.right)
        remote.press(.select)
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5), "Select reveals the controls again")
        // The model reports a seek target immediately; only AVPlayer's time
        // observer can move past it, so this proves the real item skipped.
        XCTAssertTrue(wait(timeout: 10) { (self.elapsed(scrubber) ?? 0) >= 14 },
                      "A right press while controls are hidden skips ten seconds of real playback")
        XCTAssertGreaterThan(try XCTUnwrap(server?.mediaRequestCount), 0)

        // The remote's Play/Pause button toggles exactly once.
        remote.press(.playPause)
        let playPause = app.buttons["play-pause-control"]
        XCTAssertTrue(wait(timeout: 5) { playPause.label == "Play" },
                      "One Play/Pause press must pause; a double toggle would keep playing")
        let paused = try XCTUnwrap(elapsed(scrubber))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(try XCTUnwrap(elapsed(scrubber)), paused, accuracy: 1, "Paused playback must not advance")

        // One held press keeps scrubbing; a click alone moves ten seconds,
        // so only repeats can carry the preview from here to the start.
        try moveFocus(to: scrubber, pressing: .up)
        XCTAssertGreaterThan(paused, 12, "The hold check needs more than one step of headroom")
        remote.press(.left, forDuration: 2)
        XCTAssertTrue(wait(timeout: 3) { (self.elapsed(scrubber) ?? 100) < 1 },
                      "Holding left must keep scrubbing past one ten-second step")
        // Repeats that outlived the release would recreate the preview here.
        remote.press(.menu)
        XCTAssertTrue(wait(timeout: 3) { abs((self.elapsed(scrubber) ?? -100) - paused) <= 1 },
                      "Menu cancels the held preview without seeking")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(try XCTUnwrap(elapsed(scrubber)), paused, accuracy: 1,
                       "Releasing the press stops the repeats")

        // Scrub back on the still-focused progress bar: left previews, select jumps.
        remote.press(.left)
        let target = paused - 10
        XCTAssertTrue(wait(timeout: 3) { abs((self.elapsed(scrubber) ?? -100) - target) <= 1 },
                      "Left on the focused progress bar previews ten seconds earlier")
        remote.press(.select)
        remote.press(.playPause)
        XCTAssertTrue(wait(timeout: 5) { playPause.label == "Pause" })
        XCTAssertTrue(wait(timeout: 10) {
            guard let value = self.elapsed(scrubber) else { return false }
            return value >= target + 2 && value <= target + 8
        }, "Real playback continues from the scrub target, not from \(paused) seconds")
        let resumeAt = try XCTUnwrap(elapsed(scrubber))
        remote.press(.playPause)
        XCTAssertTrue(wait(timeout: 5) { playPause.label == "Play" })

        remote.press(.menu)
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        // With controls hidden a click only skips; holding reveals the
        // progress bar and keeps scrubbing toward the end of the movie.
        remote.press(.right, forDuration: 2)
        XCTAssertTrue(scrubber.waitForExistence(timeout: 3), "Holding right reveals the progress bar")
        XCTAssertTrue(wait(timeout: 3) { (self.elapsed(scrubber) ?? 0) >= min(resumeAt + 15, 24) },
                      "Holding right keeps scrubbing past the click's ten-second skip")
        remote.press(.menu)
        XCTAssertTrue(wait(timeout: 3) { !app.staticTexts["Select to jump · Menu to cancel"].exists },
                      "Menu cancels the held preview")
        remote.press(.menu)
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        remote.press(.menu)
        XCTAssertTrue(watch.waitForExistence(timeout: 8), "Menu with hidden controls closes the player")
        XCTAssertTrue(wait(timeout: 8) { watch.label.hasPrefix("Resume") },
                      "Closing saves a resume position near \(resumeAt) seconds")
        XCTAssertTrue(app.buttons["detail-start-over"].exists)
    }

    func testMenuOnTheFirstLaunchConnectionScreenReturnsToTheHomeScreen() throws {
        let app = try launch(connected: false)
        XCTAssertTrue(app.textFields["connection-server"].waitForExistence(timeout: 15),
                      "A first launch without a server opens the connection screen")
        // With nothing to return to, this screen is the app's top level: the
        // Siri Remote's Menu button must leave the app instead of being swallowed.
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(wait(timeout: 8) {
            [.runningBackground, .runningBackgroundSuspended].contains(app.state)
        }, "Menu on the top-level connection screen must return to the Home screen")
    }

    func testDownFromEveryBrowseControlReachesAShortFolder() throws {
        let app = try launch()
        XCTAssertTrue(app.buttons["library-card-42001"].waitForExistence(timeout: 15))
        try focusBrowseControl("browse-folders", in: app)
        XCUIRemote.shared.press(.select)
        let shelf = app.buttons["library-card-41000"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10), "The root folder lists its single shelf")

        // The only poster sits under All Movies. Down from controls further
        // right must still enter the grid rather than doing nothing.
        for control in ["browse-folders", "library-sort", "library-refresh"] {
            try moveFocus(to: app.buttons[control], pressing: control == "browse-folders" ? .left : .right)
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(wait(timeout: 3) { shelf.hasFocus }, "Down from \(control) must focus the folder below")
            XCUIRemote.shared.press(.up)
            XCTAssertTrue(wait(timeout: 3) { !shelf.hasFocus })
        }
    }

    func testEnteringAndLeavingALargeFolderKeepsFocusAndScrollPredictable() throws {
        let app = try launch()
        let remote = XCUIRemote.shared
        XCTAssertTrue(app.buttons["library-card-42001"].waitForExistence(timeout: 15))
        try focusBrowseControl("browse-folders", in: app)
        remote.press(.select)
        let shelf = app.buttons["library-card-41000"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10))
        // All Movies sits above the shelf, so this path works with any layout.
        try moveFocus(to: app.buttons["browse-library"], pressing: .left)
        try moveFocus(to: shelf, pressing: .down)
        remote.press(.select)

        let firstBox = app.buttons["library-card-41100"]
        XCTAssertTrue(firstBox.waitForExistence(timeout: 10), "The large folder opens")
        XCTAssertTrue(wait(timeout: 5) { firstBox.hasFocus }, "Entering a folder focuses its first poster")

        for _ in 0..<5 { remote.press(.down); Thread.sleep(forTimeInterval: 0.4) }
        let deepIdentifier = try XCTUnwrap(focusedCardIdentifier(in: app), "One poster keeps focus while moving down")
        let deepIndex = try XCTUnwrap(Int(deepIdentifier.dropFirst("library-card-".count))) - 41100
        XCTAssertGreaterThanOrEqual(deepIndex, 15, "Five rows down must be well into the folder")
        let deepCard = app.buttons[deepIdentifier]

        // The subfolder answers slowly. While it loads, the chosen poster keeps
        // focus and does not move: no scrolling and no layout pushed around it.
        let before = deepCard.frame
        remote.press(.select)
        let loading = app.descendants(matching: .any)["browse-loading"]
        XCTAssertTrue(loading.waitForExistence(timeout: 2), "Opening a folder shows progress immediately")
        for _ in 0..<3 {
            XCTAssertTrue(deepCard.hasFocus, "Focus must stay on the chosen folder while it loads")
            let frame = deepCard.frame
            XCTAssertEqual(frame.midY, before.midY, accuracy: 12, "The grid must not shift while the folder loads")
            XCTAssertEqual(frame.midX, before.midX, accuracy: 12, "The grid must not shift while the folder loads")
        }
        XCTAssertTrue(loading.exists, "The checks above must run while the folder is still loading")

        let movie = app.buttons["library-card-42001"]
        XCTAssertTrue(movie.waitForExistence(timeout: 10), "The subfolder's movies replace the grid")
        XCTAssertTrue(wait(timeout: 5) { movie.hasFocus }, "The new folder's first poster takes focus")
        XCTAssertTrue(wait(timeout: 5) { self.isOnScreen(app.buttons["browse-folders"], in: app) },
                      "The new folder starts at the top, with its controls in view")

        // Returning through the breadcrumb restores the folder you came from.
        let shelfCrumb = app.buttons["breadcrumb-41000"]
        try moveFocus(to: app.buttons["breadcrumb-0"], pressing: .up)
        try moveFocus(to: shelfCrumb, pressing: .right)
        remote.press(.select)
        XCTAssertTrue(deepCard.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(timeout: 5) { deepCard.hasFocus }, "Going back focuses the folder that was opened")
        XCTAssertTrue(isOnScreen(deepCard, in: app), "Going back scrolls to the folder that was opened")
    }

    // MARK: Helpers

    private func launch(connected: Bool = true) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["RUSTYVIEW_TEST_NAMESPACE": namespace]
        if connected {
            app.launchEnvironment["RUSTYVIEW_TEST_SERVER"] = try XCTUnwrap(server?.address)
            app.launchEnvironment["RUSTYVIEW_TEST_USERNAME"] = TVSyntheticServer.username
            app.launchEnvironment["RUSTYVIEW_TEST_PASSWORD"] = TVSyntheticServer.password
        }
        app.launch()
        return app
    }

    /// Moves from the tab bar into the browse controls and onto `identifier`.
    private func focusBrowseControl(_ identifier: String, in app: XCUIApplication) throws {
        let controls = app.buttons.matching(NSPredicate(
            format: "identifier IN %@ AND hasFocus == true",
            ["browse-library", "browse-folders", "library-sort", "library-refresh"]))
        for _ in 0..<4 where controls.count == 0 {
            XCUIRemote.shared.press(.down)
            _ = wait(timeout: 1) { controls.count > 0 }
        }
        XCTAssertGreaterThan(controls.count, 0, "Focus never reached the browse controls")
        try moveFocus(to: app.buttons["browse-library"], pressing: .left)
        try moveFocus(to: app.buttons[identifier], pressing: .right)
    }

    private func focusedCardIdentifier(in app: XCUIApplication) -> String? {
        let focused = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library-card-' AND hasFocus == true"))
        return focused.count == 1 ? focused.firstMatch.identifier : nil
    }

    private func isOnScreen(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let frame = element.frame
        return element.exists && !frame.isEmpty && app.windows.firstMatch.frame.contains(frame)
    }

    private func moveFocus(to element: XCUIElement, pressing direction: XCUIRemote.Button) throws {
        for _ in 0..<8 where !element.hasFocus {
            XCUIRemote.shared.press(direction)
            _ = wait(timeout: 1) { element.hasFocus }
        }
        XCTAssertTrue(element.hasFocus, "Focus never reached \(element.identifier)")
    }

    /// Seconds elapsed from the scrubber's "[h:]mm:ss of [h:]mm:ss" value.
    private func elapsed(_ scrubber: XCUIElement) -> Double? {
        guard scrubber.exists, let value = scrubber.value as? String,
              let first = value.components(separatedBy: " of ").first else { return nil }
        let parts = first.split(separator: ":").compactMap { Double($0) }
        guard (2...3).contains(parts.count) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private func wait(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let predicate = NSPredicate { _, _ in condition() }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)],
                              timeout: timeout) == .completed
    }
}

/// Serves schema-2 JSON, Basic-authenticated byte ranges and WebVTT. All titles
/// and metadata are invented.
private final class TVSyntheticServer: @unchecked Sendable {
    static let username = "viewer"
    static let password = "test-only-password"
    private static let authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()

    private let listener: NWListener
    private let queue = DispatchQueue(label: "synthetic.tv.http")
    private let media: Data
    private let ready = DispatchSemaphore(value: 0)
    private var startError: Error?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var requests: [String] = []
    private var mediaRequests = 0
    private(set) var address = ""

    var mediaRequestCount: Int { queue.sync { mediaRequests } }
    var requestSummary: String { queue.sync { requests.joined(separator: "\n") } }

    init(media: Data) throws {
        self.media = media
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() throws {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                address = "http://127.0.0.1:\(listener.port?.rawValue ?? 0)"
                ready.signal()
            case .failed(let error):
                startError = error
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connections[ObjectIdentifier(connection)] = connection
            connection.start(queue: queue)
            receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "TVSyntheticServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Listener did not start"])
        }
        if let startError { throw startError }
    }

    func stop() {
        listener.cancel()
        queue.sync {
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, ended, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
                  let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else {
                if ended || buffer.count > 65_536 { connection.cancel() } else { receive(connection, buffer: buffer) }
                return
            }
            respond(to: head, on: connection)
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count >= 2 else { connection.cancel(); return }
        let method = String(request[0]), target = String(request[1])
        let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { _, last in last })
        requests.append("\(method) \(target.components(separatedBy: "?")[0])")
        guard headers["authorization"] == Self.authorization else {
            send(Data(), status: 401, type: "text/plain", head: false, extra: "WWW-Authenticate: Basic realm=\"synthetic\"\r\n", on: connection)
            return
        }
        let path = target.components(separatedBy: "?")[0]
        if path == "/api/web/library" {
            let (page, delay) = libraryPage(target: target)
            if delay > 0 {
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.sendJSON(page, on: connection) }
            } else {
                sendJSON(page, on: connection)
            }
        } else if path.hasPrefix("/api/web/item/"), let index = Self.ids.firstIndex(of: String(path.dropFirst(14))) {
            var item = Self.item(index)
            item.removeValue(forKey: "entry_type")
            sendJSON(["schema_version": 2, "id": Self.ids[index], "item": item,
                      "audio_tracks": item["audio_tracks"] ?? [], "chapters": item["chapters"] ?? []], on: connection)
        } else if path.hasPrefix("/web/media/") {
            mediaRequests += 1
            sendMedia(range: headers["range"], head: method == "HEAD", on: connection)
        } else if path.hasPrefix("/captions/") {
            let vtt = "WEBVTT\n\n00:00:00.000 --> 00:00:30.000\nSynthetic lantern subtitle.\n"
            send(Data(vtt.utf8), status: 200, type: "text/vtt", head: method == "HEAD", on: connection)
        } else {
            sendJSON(["schema_version": 2, "error": ["code": "not_found", "message": "Synthetic route not found.",
                                                     "recoverable": false]], status: 404, on: connection)
        }
    }

    private func sendMedia(range: String?, head: Bool, on connection: NWConnection) {
        var start = 0, end = media.count - 1, status = 200
        if let range, range.hasPrefix("bytes=") {
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if let first = bounds.first.flatMap({ Int($0) }) {
                start = first
                if bounds.count == 2, let last = Int(bounds[1]) { end = min(last, media.count - 1) }
            } else if bounds.count == 2, let suffix = Int(bounds[1]) {
                start = max(0, media.count - suffix)
            }
            status = 206
        }
        guard start < media.count, end >= start else {
            send(Data(), status: 416, type: "video/mp4", head: false,
                 extra: "Content-Range: bytes */\(media.count)\r\n", on: connection)
            return
        }
        send(media.subdata(in: start..<(end + 1)), status: status, type: "video/mp4", head: head,
             extra: "Accept-Ranges: bytes\r\n" + (status == 206 ? "Content-Range: bytes \(start)-\(end)/\(media.count)\r\n" : ""),
             on: connection)
    }

    private func sendJSON(_ object: Any, status: Int = 200, on connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        send(body, status: status, type: "application/json", head: false, on: connection)
    }

    private func send(_ body: Data, status: Int, type: String, head: Bool, extra: String = "", on connection: NWConnection) {
        let reason = [200: "OK", 206: "Partial Content", 401: "Unauthorized", 404: "Not Found", 416: "Range Not Satisfiable"][status] ?? "OK"
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n\(extra)Connection: close\r\n\r\n".utf8)
        if !head { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.connections.removeValue(forKey: ObjectIdentifier(connection))
        })
    }

    /// The flat library, plus an invented folder tree: the root holds one
    /// shelf, the shelf holds 90 boxes (paged), and each box holds both movies
    /// after a deliberate delay so the pending state is observable.
    private func libraryPage(target: String) -> (page: [String: Any], delay: TimeInterval) {
        let folders = Self.query("view", in: target) == "folders"
        let folder = Self.query("folder", in: target) ?? "0"
        let offset = Int(Self.query("offset", in: target) ?? "") ?? 0
        let limit = Int(Self.query("limit", in: target) ?? "") ?? 60
        let root = ["id": "0", "title": "Media"], shelf = ["id": Self.shelfID, "title": "Invented Shelf"]
        var all: [[String: Any]] = Self.ids.indices.map(Self.item)
        var breadcrumbs: [[String: String]] = []
        var delay: TimeInterval = 0
        if folders {
            if folder == Self.shelfID {
                all = Self.boxIDs.indices.map { ["entry_type": "folder", "id": Self.boxIDs[$0],
                                                 "title": "Paper Lantern Box \($0 + 1)", "child_count": 2] }
                breadcrumbs = [root, shelf]
            } else if let box = Self.boxIDs.firstIndex(of: folder) {
                breadcrumbs = [root, shelf, ["id": folder, "title": "Paper Lantern Box \(box + 1)"]]
                delay = 4
            } else {
                all = [["entry_type": "folder", "id": Self.shelfID, "title": "Invented Shelf",
                        "child_count": Self.boxIDs.count]]
                breadcrumbs = [root]
            }
        }
        let entries = Array(all.dropFirst(offset).prefix(limit))
        let page: [String: Any] = ["schema_version": 2, "generation": 1, "server_name": "Synthetic Media Server", "root_folder_id": "0",
                "capabilities": ["transcoding": true, "captions": true, "quality_profiles": [
                    ["id": "auto", "label": "Auto · Best for this connection", "max_width": 3840, "max_height": 2160,
                     "expected_bandwidth_kbps": 12000, "automatic_fallback": false],
                    ["id": "full_hd", "label": "1080p · 8 Mbps", "max_width": 1920, "max_height": 1080,
                     "expected_bandwidth_kbps": 8448, "automatic_fallback": false],
                ]],
                "library_state": "ready", "view": folders ? "folders" : "library",
                "folder": folders ? (breadcrumbs.last ?? root) as Any : NSNull(), "breadcrumbs": breadcrumbs,
                "offset": offset, "limit": limit, "total": all.count, "has_more": offset + entries.count < all.count,
                "query": "", "sort": "title", "entries": entries]
        return (page, delay)
    }

    private static func query(_ name: String, in target: String) -> String? {
        URLComponents(string: "http://synthetic.invalid\(target)")?.queryItems?.first { $0.name == name }?.value
    }

    private static let shelfID = "41000"
    private static let boxIDs = (0..<90).map { String(41100 + $0) }
    private static let ids = ["42001", "42002"]
    private static let titles = ["The Clockwork Orchard", "Lanterns Beyond Europa"]

    private static func item(_ index: Int) -> [String: Any] {
        let id = ids[index]
        return [
            "entry_type": "media", "id": id, "title": titles[index], "file_name": "synthetic-\(index + 1).mp4",
            "kind": "video", "mime": "video/mp4", "ext": "mp4", "duration": "0:00:25", "duration_seconds": 25,
            "resolution": "640x360", "width": 640, "height": 360,
            "about": "An entirely invented story used to verify the Apple TV interface.",
            "plot": "Synthetic plot text with no relationship to any real library.", "genre": "Adventure",
            "size_bytes": 3_673_398, "container": "mp4", "video_codec": "h264", "video_profile": "High",
            "bit_depth": 8, "frame_rate": "24", "video_repair_required": false, "audio_codec": "aac",
            "audio_layout": "mono", "codec_string": "avc1.64001e,mp4a.40.2", "hdr": "sdr",
            "audio_tracks": [["index": 0, "codec": "aac", "content_type": "audio/mp4; codecs=\"mp4a.40.2\"",
                              "channels": 1, "language": "eng", "title": "Synthetic tone", "default": true]],
            "default_audio_index": 0,
            "captions": [["index": 0, "label": "English", "language": "eng", "default": false, "source_format": "vtt",
                          "browser_supported": true, "url": "/captions/\(id).vtt"]],
            "chapters": [["index": 0, "title": "Lantern Engine Ignition", "start_seconds": 0, "end_seconds": 12],
                         ["index": 1, "title": "Glasswater Transit", "start_seconds": 12, "end_seconds": 25]],
            "art_url": NSNull(), "download_url": "/web/download/\(id)",
            "source_url": "/web/media/\(id).mp4?mode=direct", "fallback_url": "/web/media/\(id).mp4",
            "transcode_likely": false,
        ]
    }
}
