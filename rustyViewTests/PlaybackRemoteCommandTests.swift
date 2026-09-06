import AVFoundation
import MediaPlayer
import XCTest
@testable import rustyView

@MainActor
final class PlaybackRemoteCommandTests: XCTestCase {
    func testRegisteredCommandsControlRealOutputAndRetiredCallbacksCannotRestartIt() async throws {
        let commands = CapturedPlaybackCommands()
        let audio = RecordedAudioSession()
        let system = PlaybackSystemController(audioSession: audio, remoteCommands: commands)
        let model = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral), systemController: system)
        let (record, url) = try fixture(mediaID: "78001")
        defer { model.stop() }
        model.playLocal(record: record, url: url, startAt: 1, preservingIntent: .paused)
        await waitFor("Local paused asset is ready before remote commands") {
            model.player.currentItem?.status == .readyToPlay && model.player.currentTime().seconds >= 0.95
        }
        XCTAssertEqual(commands.targets.count, 6)
        let play = try XCTUnwrap(commands.latest(.play))
        let pause = try XCTUnwrap(commands.latest(.pause))
        let seek = try XCTUnwrap(commands.latest(.seek))
        XCTAssertEqual(play.handler(.play), .success)
        await waitFor("Registered Play advances real decoded video") { model.player.currentTime().seconds >= 1.4 }
        XCTAssertGreaterThan(audio.activations, 0)
        XCTAssertEqual(pause.handler(.pause), .success)
        await waitFor("Registered Pause stops real output") { model.player.rate == 0 && model.transport.intent == .paused }
        XCTAssertEqual(seek.handler(.seek(3)), .success)
        await waitFor("Registered absolute seek changes actual playback position") { abs(model.player.currentTime().seconds - 3) < 0.1 }
        XCTAssertEqual(model.player.rate, 0, "Seeking from the lock screen must preserve deliberate pause")
        model.stop()
        XCTAssertEqual(commands.removedIDs.count, 6)
        XCTAssertEqual(audio.deactivations, 1)
        XCTAssertEqual(play.handler(.play), .commandFailed,
                       "A callback retained by the operating system after target removal must reject the retired lease")
        XCTAssertEqual(seek.handler(.seek(1)), .commandFailed)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.player.currentItem)
        XCTAssertEqual(model.player.rate, 0)
    }

    func testCommandQueuedBeforeAnotherOwnerClaimsCannotControlEitherViewing() async throws {
        let oldCommands = CapturedPlaybackCommands()
        let newCommands = CapturedPlaybackCommands()
        let old = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral),
                                systemController: PlaybackSystemController(remoteCommands: oldCommands))
        let new = PlaybackModel(client: RustyDLNAClient(configuration: .ephemeral),
                                systemController: PlaybackSystemController(remoteCommands: newCommands))
        defer { old.stop(); new.stop() }
        let (oldRecord, url) = try fixture(mediaID: "78002")
        let (newRecord, _) = try fixture(mediaID: "78003")
        old.playLocal(record: oldRecord, url: url, startAt: 1, preservingIntent: .paused)
        await waitFor("Old viewing is prepared and paused") { old.player.currentItem?.status == .readyToPlay }
        let oldPlay = try XCTUnwrap(oldCommands.latest(.play))
        // The system callback queues its main-actor operation. A different
        // viewing claims ownership before this test yields the actor.
        XCTAssertEqual(oldPlay.handler(.play), .success)
        new.playLocal(record: newRecord, url: url, startAt: 2, preservingIntent: .paused)
        await waitFor("New viewing is prepared while the retired callback drains") {
            new.player.currentItem?.status == .readyToPlay && new.player.currentTime().seconds >= 1.95
        }
        XCTAssertEqual(old.player.rate, 0)
        XCTAssertEqual(new.player.rate, 0)
        XCTAssertEqual(old.transport.intent, .paused)
        XCTAssertEqual(new.transport.intent, .paused)
        let newPlay = try XCTUnwrap(newCommands.latest(.play))
        XCTAssertEqual(newPlay.handler(.play), .success)
        await waitFor("The current owner's command still advances its real video") { new.player.currentTime().seconds >= 2.4 }
        XCTAssertEqual(old.player.rate, 0)
        old.stop()
        XCTAssertFalse(newCommands.removedIDs.contains(newPlay.id), "Older cleanup must not remove newer registrations")
    }

    private func fixture(mediaID: String) throws -> (DownloadRecord, URL) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-native-tracks", withExtension: "mp4"))
        let record = DownloadRecord(id: UUID(), serverOrigin: "https://controls.example.test", mediaID: mediaID,
                                    title: "The Clockwork Umbrella", kind: .original, fileName: url.lastPathComponent,
                                    byteCount: Int64(try Data(contentsOf: url).count), completedAt: Date(),
                                    durationSeconds: 6, resolution: "320x180", artworkPath: nil)
        return (record, url)
    }
    private func waitFor(_ description: String, _ condition: @escaping () -> Bool) async {
        let done = expectation(description: description)
        let task = Task {
            for _ in 0..<400 {
                if condition() { done.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await fulfillment(of: [done], timeout: 5)
        task.cancel()
    }
}

@MainActor
private final class CapturedPlaybackCommands: PlaybackRemoteCommandRegistering {
    struct Target {
        let id: UUID
        let kind: PlaybackCommandKind
        let handler: (PlaybackSystemCommand) -> MPRemoteCommandHandlerStatus
    }
    var targets: [Target] = []
    var removedIDs: Set<UUID> = []
    func addTarget(for kind: PlaybackCommandKind, handler: @escaping (PlaybackSystemCommand) -> MPRemoteCommandHandlerStatus) -> Any {
        let target = Target(id: UUID(), kind: kind, handler: handler)
        targets.append(target)
        return target.id
    }
    func removeTarget(_ target: Any, for kind: PlaybackCommandKind) {
        if let id = target as? UUID { removedIDs.insert(id) }
    }
    func setEnabled(_ enabled: Bool, for kind: PlaybackCommandKind) {}
    func latest(_ kind: PlaybackCommandKind) -> Target? { targets.last { $0.kind == kind && !removedIDs.contains($0.id) } }
}

@MainActor
private final class RecordedAudioSession: PlaybackAudioSessionControlling {
    var activations = 0
    var deactivations = 0
    func activate() throws { activations += 1 }
    func deactivate() throws { deactivations += 1 }
}
