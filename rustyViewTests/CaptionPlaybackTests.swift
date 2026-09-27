import AVFoundation
import Network
import XCTest
@testable import rustyView

/// Staged for D15. This listener serves actual authenticated video bytes and
/// holds real caption responses; a held selection is never a prearranged value.
@MainActor
final class CaptionPlaybackTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var testDefaultsName: String!

    override func setUp() {
        super.setUp()
        testDefaultsName = "CaptionPlaybackTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: testDefaultsName)!
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: testDefaultsName)
        testDefaults = nil
        super.tearDown()
    }

    private func playbackModel(client: RustyDLNAClient) -> PlaybackModel {
        PlaybackModel(client: client, preferences: PlaybackPreferences(defaults: testDefaults))
    }

    func testStreamingWindowsRenderEarlyPrefetchAcrossBoundaryAndSeekWithGlobalTimes() async throws {
        let fixture = try await CaptionHTTPFixture.make(streaming: true, long: true)
        defer { fixture.stop() }
        let model = playbackModel(client: fixture.client)
        defer { model.stop() }
        let first = Data("WEBVTT\n\n00:00.000 --> 00:10.000\nFirst window\n\n01:58.000 --> 02:04.000\nCrossing cue\n".utf8)
        let second = Data("WEBVTT\n\n01:58.000 --> 02:04.000\nCrossing cue\n\n02:05.000 --> 02:10.000\nSecond window\n".utf8)
        fixture.server.setCaptionResponse(status: 200, body: first)
        model.play(fixture.item, mode: .original, preservingIntent: .paused)
        await waitFor("Long decoded movie is ready") { model.player.currentItem?.status == .readyToPlay }
        await model.selectCaption(0)
        XCTAssertEqual(model.currentSubtitle, "First window")
        XCTAssertEqual(fixture.server.captionTargets.count, 1)
        XCTAssertTrue(fixture.server.captionTargets[0].hasSuffix("?start=0"), "Streaming must not wait for the full offline resource")

        fixture.server.holdCaptions()
        model.seek(toGlobalTime: 119)
        await waitFor("Next window is prefetched while the crossing cue remains visible") {
            fixture.server.heldCaptionCount == 1 && model.currentSubtitle == "Crossing cue"
                && abs(model.player.currentTime().seconds - 119) < 0.1
        }
        guard case .active = model.subtitleSelection else { return XCTFail("Prefetch must not hide usable captions") }
        XCTAssertTrue(fixture.server.captionTargets.last?.hasSuffix("?start=120") == true)
        fixture.server.releaseCaptions(status: 200, body: second)
        model.seek(toGlobalTime: 126)
        await waitFor("Second window uses original movie timestamps") {
            model.currentSubtitle == "Second window" && abs(model.player.currentTime().seconds - 126) < 0.1
        }

        fixture.server.setCaptionResponse(status: 200, body: Data("WEBVTT\n\n05:01.000 --> 05:06.000\nAfter the seek\n".utf8))
        model.seek(toGlobalTime: 302)
        await waitFor("A distant seek fetches its own window") {
            model.currentSubtitle == "After the seek" && abs(model.player.currentTime().seconds - 302) < 0.1
        }
        XCTAssertTrue(fixture.server.captionTargets.last?.hasSuffix("?start=240") == true)
        let requests = fixture.server.captionRequestCount
        model.seek(toGlobalTime: 3)
        await waitFor("Returning to a cached window needs no request") {
            model.currentSubtitle == "First window" && abs(model.player.currentTime().seconds - 3) < 0.1
        }
        XCTAssertEqual(fixture.server.captionRequestCount, requests)
    }

    func testEmptyStreamingWindowIsActiveAndOffDefeatsHeldSeekResponse() async throws {
        let fixture = try await CaptionHTTPFixture.make(streaming: true, long: true)
        defer { fixture.stop() }
        let model = playbackModel(client: fixture.client)
        defer { model.stop() }
        fixture.server.setCaptionResponse(status: 200, body: Data("WEBVTT\n\n".utf8))
        model.play(fixture.item, mode: .original, preservingIntent: .paused)
        await waitFor("Long movie is ready") { model.player.currentItem?.status == .readyToPlay }
        await model.selectCaption(0)
        guard case .active = model.subtitleSelection else { return XCTFail("A gap in dialogue is a loaded window") }
        XCTAssertNil(model.currentSubtitle)
        fixture.server.holdCaptions()
        model.seek(toGlobalTime: 245)
        await waitFor("Seek window is held") { fixture.server.heldCaptionCount == 1 }
        model.turnSubtitlesOff()
        fixture.server.releaseCaptions(status: 200, body: Data("WEBVTT\n\n04:00.000 --> 04:10.000\nLate cue\n".utf8))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.subtitleSelection, .off)
        XCTAssertNil(model.currentSubtitle)
        XCTAssertNil(model.selectedCaptionIndex)
    }

    func testStreamingWindowCacheBoundsAndEmptyParsingDoNotAcceptMalformedVTT() throws {
        XCTAssertEqual(try WebVTTParser.parse(Data("WEBVTT\n\n".utf8), allowEmpty: true), [])
        XCTAssertThrowsError(try WebVTTParser.parse(Data("WEBVTT\n\n".utf8)))
        XCTAssertThrowsError(try WebVTTParser.parse(Data("WEBVTT\n\ninvalid --> time\nCue".utf8), allowEmpty: true))
        let session = StreamingSubtitleSession(path: "/captions/window.vtt?start=0", client: RustyDLNAClient(),
            selection: SubtitleSelection(id: "server-0", label: "English", delivery: .appOverlay), index: 0)
        let crossing = SubtitleCue(start: 118, end: 124, text: "Crossing")
        session.insert([crossing], start: 0)
        session.insert([crossing], start: 120)
        XCTAssertEqual(session.cues, [crossing], "Overlapping windows must not repeat a cue")
        session.insert([], start: 240)
        session.insert([], start: 360)
        XCTAssertFalse(session.contains(0))
        XCTAssertTrue(session.contains(120))
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(try ServerConnection(serverAddress: "https://captions.example.test", username: "viewer", password: "synthetic"))
        let foreign = StreamingSubtitleSession(path: "https://foreign.example.test/track.vtt?start=0", client: client,
            selection: session.selection, index: 0)
        XCTAssertThrowsError(try foreign.request(start: 120), "Advertised streaming URLs must obey the same origin boundary")
    }

    func testReturningToCachedWindowDefeatsLateSeekFailure() async throws {
        let fixture = try await CaptionHTTPFixture.make(streaming: true, long: true)
        defer { fixture.stop() }
        let model = playbackModel(client: fixture.client)
        defer { model.stop() }
        fixture.server.setCaptionResponse(status: 200, body: Self.captions)
        model.play(fixture.item, mode: .original, preservingIntent: .paused)
        await waitFor("Long movie is ready") { model.player.currentItem?.status == .readyToPlay }
        await model.selectCaption(0)
        let beforeScrub = fixture.server.captionRequestCount
        model.seek(toGlobalTime: 245)
        model.seek(toGlobalTime: 1.5)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.server.captionRequestCount, beforeScrub, "A same-turn scrub back must cancel work before its task starts")
        fixture.server.holdCaptions()
        model.seek(toGlobalTime: 245)
        await waitFor("Distant seek is held") { fixture.server.heldCaptionCount == 1 }
        model.seek(toGlobalTime: 1.5)
        await waitFor("Cached captions restore immediately") { model.currentSubtitle == "Copper & paper <lantern>\nA second voice" }
        fixture.server.releaseCaptions(status: 401, body: Data())
        try await Task.sleep(for: .milliseconds(150))
        guard case .active = model.subtitleSelection else { return XCTFail("A stale seek failure cannot replace the cached selection") }
        XCTAssertNil(model.subtitleError)
    }

    func testHeldCaptionIsRequestedButNotActiveAndOffDefeatsItsLateResponse() async throws {
        let fixture = try await CaptionHTTPFixture.make()
        defer { fixture.stop() }
        let model = playbackModel(client: fixture.client)
        defer { model.stop() }
        model.play(fixture.item, mode: .original)
        await waitFor("Video is actually playing before choosing subtitles") { model.player.currentTime().seconds >= 0.4 }
        fixture.server.holdCaptions()
        let loading = Task { await model.selectCaption(0) }
        await waitFor("Caption GET is held on the socket") { fixture.server.heldCaptionCount == 1 }
        XCTAssertNil(model.selectedCaptionIndex, "A requested track is not active until it has usable cues")
        guard case .loading(let requested) = model.subtitleSelection else {
            return XCTFail("The initiating control needs a loading state while the server is held")
        }
        XCTAssertEqual(requested.label, "English")
        await model.selectCaption(nil)
        fixture.server.releaseCaptions(status: 200, body: Self.captions)
        await loading.value
        XCTAssertEqual(model.subtitleSelection, .off)
        XCTAssertNil(model.currentSubtitle)
        XCTAssertNil(model.subtitleError)
    }

    func testAuthenticationFailureKeepsRequestedTrackForRetryAndMalformedRetryIsNotActive() async throws {
        let fixture = try await CaptionHTTPFixture.make(streaming: true)
        defer { fixture.stop() }
        let model = playbackModel(client: fixture.client)
        defer { model.stop() }
        model.play(fixture.item, mode: .original)
        await waitFor("Real original is ready") { model.player.currentItem?.status == .readyToPlay }
        model.togglePlayback()
        fixture.server.setCaptionResponse(status: 401, body: Data())
        await model.selectCaption(0)
        guard case .failed(let requested, let message) = model.subtitleSelection else {
            return XCTFail("A rejected HTTP caption needs a retained Retry/Off choice")
        }
        XCTAssertEqual(requested.label, "English")
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(model.selectedCaptionIndex)
        let rejectedCount = fixture.server.captionRequestCount
        XCTAssertLessThanOrEqual(rejectedCount, 2, "Caption authentication retries must be bounded")

        fixture.server.setCaptionResponse(status: 200, body: Data("WEBVTT\n\nnot a timed cue".utf8))
        await model.retrySubtitles()
        guard case .failed = model.subtitleSelection else { return XCTFail("Malformed VTT cannot become active") }
        XCTAssertNil(model.currentSubtitle)
        XCTAssertEqual(fixture.server.captionRequestCount, rejectedCount + 1)

        fixture.server.setCaptionResponse(status: 200, body: Self.captions)
        await model.retrySubtitles()
        guard case .active(let selected) = model.subtitleSelection else { return XCTFail("Retry must load actual usable cues") }
        XCTAssertEqual(selected.id, requested.id)
        XCTAssertEqual(selected.delivery, .appOverlay)
        XCTAssertEqual(model.selectedCaptionIndex, 0)
        model.seek(toGlobalTime: 1.5)
        await waitFor("Both escaped overlapping cues render over the real paused frame") {
            model.player.currentTime().seconds >= 1.45 && model.currentSubtitle == "Copper & paper <lantern>\nA second voice"
        }
        XCTAssertNotNil(model.subtitleOutputNotice, "App-rendered subtitles require an output limitation notice")
        XCTAssertTrue(model.requiresSubtitleOutputAcknowledgement)
        model.turnSubtitlesOff()
        XCTAssertNil(model.currentSubtitle)
        XCTAssertFalse(model.requiresSubtitleOutputAcknowledgement)
    }

    func testOldHeldCaptionCannotChangeANewerMovieEvenAtTheSameIndex() async throws {
        let fixture = try await CaptionHTTPFixture.make(streaming: true)
        defer { fixture.stop() }
        let model = playbackModel(client: fixture.client)
        defer { model.stop() }
        model.play(fixture.item, mode: .original)
        fixture.server.holdCaptions()
        let oldLoad = Task { await model.selectCaption(0) }
        await waitFor("Old movie's caption GET reached the socket") { fixture.server.heldCaptionCount == 1 }
        let replacement = try fixture.itemWithID("76002")
        model.play(replacement, mode: .original)
        fixture.server.setCaptionResponse(status: 200, body: Data("WEBVTT\n\n00:00.000 --> 00:06.000\nNew movie's cue\n".utf8))
        await model.selectCaption(0)
        fixture.server.releaseCaptions(status: 200, body: Data("WEBVTT\n\n00:00.000 --> 00:06.000\nOld movie's cue\n".utf8))
        await oldLoad.value
        await waitFor("New movie actually plays with its own caption") { model.currentSubtitle == "New movie's cue" && model.player.currentTime().seconds >= 0.4 }
        XCTAssertEqual(model.item?.id, "76002")
        XCTAssertEqual(model.selectedCaptionIndex, 0)
        XCTAssertNil(model.subtitleError)
    }

    func testOwnedNativeAndSidecarSelectionsReportTheActualOutputKind() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-native-tracks", withExtension: "mp4"))
        let captionURL = FileManager.default.temporaryDirectory.appendingPathComponent("caption-\(UUID().uuidString).vtt")
        try Self.captions.write(to: captionURL)
        defer { try? FileManager.default.removeItem(at: captionURL) }
        let caption = OfflineCaption(id: UUID(), label: "Owned English", language: "eng", isDefault: false, isForced: false, fileName: captionURL.lastPathComponent)
        let record = DownloadRecord(id: UUID(), serverOrigin: "https://caption.example.test", mediaID: "76003", title: "The Copper Lantern",
                                    kind: .original, fileName: url.lastPathComponent, byteCount: Int64(try Data(contentsOf: url).count),
                                    completedAt: Date(), durationSeconds: 6, resolution: "320x180", artworkPath: nil)
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral))
        defer { model.stop() }
        model.playLocal(record: record, url: url, captionSources: [.init(caption: caption, url: captionURL)], preservingIntent: .paused)
        await waitFor("Native caption groups came from AVFoundation") { !model.isLoadingLocalTracks && model.localSubtitleTracks.count >= 2 }
        let embedded = try XCTUnwrap(model.localSubtitleTracks.first { $0.id != caption.id.uuidString && !$0.isForced })
        await model.selectLocalSubtitle(embedded.id)
        guard case .active(let native) = model.subtitleSelection else { return XCTFail("Native selection must become active") }
        XCTAssertEqual(native.delivery, .native)
        XCTAssertFalse(model.requiresSubtitleOutputAcknowledgement)
        let playerItem = try XCTUnwrap(model.player.currentItem)
        let loadedGroup = try await playerItem.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loadedGroup)
        XCTAssertNotNil(playerItem.currentMediaSelection.selectedMediaOption(in: group))
        await model.selectLocalSubtitle(caption.id.uuidString)
        XCTAssertNil(playerItem.currentMediaSelection.selectedMediaOption(in: group))
        XCTAssertTrue(model.requiresSubtitleOutputAcknowledgement)
        model.seek(toGlobalTime: 1.5)
        await waitFor("Owned sidecar decodes overlapping cues without HTTP") { model.currentSubtitle == "Copper & paper <lantern>\nA second voice" }
    }

    func testWebVTTReferencesDecodeAfterMarkupAndInvalidTimesNeverBecomeCues() throws {
        let bytes = Data("""
        WEBVTT

        00:00.000 --> 00:02.000
        <v Narrator><b>&amp; &lt;b&gt;literal&lt;/b&gt; &nbsp; &#65; &#x42;</b></v>

        -1:00.000 --> 00:10.000
        Invalid negative start

        00:01.000 --> 00:03.000
        A second voice
        """.utf8)
        let cues = try WebVTTParser.parse(bytes)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "& <b>literal</b> \u{00a0} A B")
        XCTAssertEqual(cues[1].text, "A second voice")
    }

    private static let captions = Data("WEBVTT\n\n00:00.000 --> 00:02.000\n<v Narrator>Copper &amp; paper &lt;lantern&gt;</v>\n\n00:01.000 --> 00:04.000\nA second voice\n".utf8)

    private func waitFor(_ description: String, _ condition: @escaping () -> Bool) async {
        let done = expectation(description: description)
        let task = Task { for _ in 0..<400 { if condition() { done.fulfill(); return }; try? await Task.sleep(for: .milliseconds(10)) } }
        await fulfillment(of: [done], timeout: 5)
        task.cancel()
    }
}

struct CaptionHTTPFixture {
    let server: CaptionTestHTTPServer
    let client: RustyDLNAClient
    let item: MediaItem

    @MainActor static func make(streaming: Bool = false, long: Bool = false) async throws -> Self {
        let mediaURL = try XCTUnwrap(Bundle(for: CaptionPlaybackTests.self).url(forResource: "synthetic-native-tracks", withExtension: "mp4"))
        let media: Data
        if long {
            // Repeat real decoded video samples to exercise movie-time seeks
            // beyond several windows without another checked-in fixture.
            let asset = AVURLAsset(url: mediaURL)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let source = try XCTUnwrap(tracks.first)
            let length = try await asset.load(.duration)
            let composition = AVMutableComposition()
            let video = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
            for _ in 0..<70 {
                try video.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: composition.duration)
            }
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("caption-timeline-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
            exporter.outputURL = output; exporter.outputFileType = .mp4
            await exporter.export()
            if let error = exporter.error { throw error }
            media = try Data(contentsOf: output)
        } else { media = try Data(contentsOf: mediaURL) }
        let server = try CaptionTestHTTPServer(media: media)
        let address = try await server.start()
        let client = RustyDLNAClient(configuration: .ephemeral)
        client.configure(try ServerConnection(serverAddress: address, username: "viewer", password: "synthetic-caption-secret"))
        return try Self(server: server, client: client, item: decodeItem(id: "76001", streaming: streaming, long: long))
    }
    func itemWithID(_ id: String) throws -> MediaItem { try Self.decodeItem(id: id) }
    func stop() { server.stop() }
    private static func decodeItem(id: String, streaming: Bool = false, long: Bool = false) throws -> MediaItem {
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)) as? [String: Any])
        var item = try XCTUnwrap(envelope["item"] as? [String: Any])
        item["id"] = id; item["title"] = "The Copper Lantern \(id)"
        item["source_url"] = "/media/\(id).mp4"; item["duration_seconds"] = long ? 420 : 6
        var caption: [String: Any] = ["index": 0, "label": "English", "language": "eng", "default": false, "source_format": "vtt", "browser_supported": true, "url": "/captions/\(id).vtt"]
        if streaming { caption["streaming_url"] = "/captions/\(id).vtt?start=0" }
        item["captions"] = [caption]
        envelope["item"] = item
        return try JSONDecoder().decode(ItemResponse.self, from: JSONSerialization.data(withJSONObject: envelope)).item
    }
}

final class CaptionTestHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "synthetic.caption.http")
    private let listener: NWListener
    private let media: Data
    private let lock = NSLock()
    private var active: [NWConnection] = []
    private var captionStatus = 200
    private var captionBody = Data()
    private var holding = false
    private var holdingMedia = false
    private var held: [NWConnection] = []
    private var captionRequests = 0
    private var requestedCaptionTargets: [String] = []
    private var preparedMediaRequests: [String] = []
    private var startup: CheckedContinuation<String, Error>?
    var heldCaptionCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }
    var captionRequestCount: Int { lock.lock(); defer { lock.unlock() }; return captionRequests }
    var captionTargets: [String] { lock.lock(); defer { lock.unlock() }; return requestedCaptionTargets }
    var preparedRequests: [String] { lock.lock(); defer { lock.unlock() }; return preparedMediaRequests }
    init(media: Data) throws { self.media = media; listener = try NWListener(using: .tcp, on: .any) }
    func holdCaptions() { lock.lock(); holding = true; lock.unlock() }
    func holdMediaRequests() { lock.lock(); holdingMedia = true; lock.unlock() }
    func setCaptionResponse(status: Int, body: Data) { lock.lock(); captionStatus = status; captionBody = body; holding = false; lock.unlock() }
    func releaseCaptions(status: Int, body: Data) {
        lock.lock(); let pending = held; held.removeAll(); holding = false; lock.unlock()
        pending.forEach { send($0, status: status, body: body, contentType: "text/vtt") }
    }
    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); startup = continuation; lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                let result: Result<String, Error>
                switch state {
                case .ready: guard let port = listener.port else { return }; result = .success("http://127.0.0.1:\(port.rawValue)")
                case .failed(let error): result = .failure(error)
                default: return
                }
                lock.lock(); let continuation = startup; startup = nil; lock.unlock()
                continuation?.resume(with: result)
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                lock.lock(); active.append(connection); lock.unlock()
                connection.start(queue: queue); receive(connection, bytes: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel(); lock.lock(); let connections = active; active.removeAll(); lock.unlock(); connections.forEach { $0.cancel() } }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, ended, error in
            guard let self, error == nil else { connection.cancel(); return }
            var bytes = bytes; if let data { bytes.append(data) }
            guard bytes.count <= 65_536 else { connection.cancel(); return }
            guard let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") else {
                if ended { connection.cancel() } else { receive(connection, bytes: bytes) }; return
            }
            let lines = text.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count >= 2 else { connection.cancel(); return }
            let target = String(first[1]), head = first[0] == "HEAD"
            let auth = lines.first { $0.lowercased().hasPrefix("authorization:") }?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
            if target.hasPrefix("/captions/") { lock.lock(); captionRequests += 1; requestedCaptionTargets.append(target); lock.unlock() }
            guard auth == "Basic " + Data("viewer:synthetic-caption-secret".utf8).base64EncodedString() else {
                send(connection, status: 401, body: Data(), contentType: "text/plain"); return
            }
            if target.hasPrefix("/web/media/") {
                lock.lock(); preparedMediaRequests.append(target); lock.unlock()
            }
            if target.hasPrefix("/captions/") {
                lock.lock(); let hold = holding, status = captionStatus, body = captionBody
                if hold { held.append(connection) }; lock.unlock()
                if !hold { send(connection, status: status, body: body, contentType: "text/vtt") }
                return
            }
            lock.lock(); let holdMedia = holdingMedia; lock.unlock()
            if holdMedia && (target.hasPrefix("/web/media/") || target.hasPrefix("/media/")) { return }
            guard target.hasPrefix("/media/") else { send(connection, status: 404, body: Data(), contentType: "text/plain"); return }
            let range = lines.first { $0.lowercased().hasPrefix("range:") }?.components(separatedBy: "bytes=").last
            let parts = range?.split(separator: "-", omittingEmptySubsequences: false)
            let start = parts?.first.flatMap { Int($0) } ?? 0
            let requestedEnd = (parts?.count == 2 ? Int(parts?[1] ?? "") : nil) ?? media.count - 1
            guard start >= 0, start < media.count, requestedEnd >= start else { send(connection, status: 416, body: Data(), contentType: "video/mp4"); return }
            let end = min(requestedEnd, media.count - 1)
            let body = media.subdata(in: start..<(end + 1))
            send(connection, status: range == nil ? 200 : 206, body: body, contentType: "video/mp4", head: head,
                 extra: range == nil ? "" : "Content-Range: bytes \(start)-\(end)/\(media.count)\r\n")
        }
    }
    private func send(_ connection: NWConnection, status: Int, body: Data, contentType: String, head: Bool = false, extra: String = "") {
        var response = Data("HTTP/1.1 \(status) Synthetic\r\nConnection: close\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\n\(extra)".utf8)
        if status == 401 { response.append(Data("WWW-Authenticate: Basic realm=\"Synthetic captions\"\r\n".utf8)) }
        response.append(Data("\r\n".utf8)); if !head { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
