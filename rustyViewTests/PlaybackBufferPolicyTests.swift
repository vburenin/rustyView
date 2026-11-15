import AVFoundation
import XCTest
@testable import rustyView

@MainActor
final class PlaybackBufferPolicyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsName: String!

    override func setUp() {
        super.setUp()
        defaultsName = "PlaybackBufferPolicyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsName)
        defaults = nil
        super.tearDown()
    }

    /// The online player item that AVFoundation actually buffers receives the
    /// injected window. Removing the wiring leaves AVFoundation's automatic 0.
    func testOnlinePlayerItemUsesTheBudgetedForwardBufferThroughTheRelay() async throws {
        let fixture = try await CaptionHTTPFixture.make()
        defer { fixture.stop() }
        let duration = try XCTUnwrap(fixture.item.durationSeconds)
        let bytesPerSecond = Int64(fixture.item.sizeBytes) / Int64(duration)
        // Large enough that the result is not a clamp: about 45 seconds of
        // this source's average bitrate.
        let policy = PlaybackBufferPolicy(memoryBudgetBytes: bytesPerSecond * 45, minimumSeconds: 5, maximumSeconds: 600)
        let model = PlaybackModel(client: fixture.client, preferences: PlaybackPreferences(defaults: defaults),
                                  bufferPolicy: policy)
        defer { model.stop() }

        model.play(fixture.item, mode: .original, preservingIntent: .paused)
        await waitFor("The relay-backed item is installed") { model.player.currentItem?.status == .readyToPlay }
        let buffered = try XCTUnwrap(model.player.currentItem?.preferredForwardBufferDuration)
        XCTAssertEqual(buffered, 45, accuracy: 1, "The window follows the source bitrate within the byte budget")
        XCTAssertLessThanOrEqual(Int64(buffered) * bytesPerSecond, try XCTUnwrap(policy.memoryBudgetBytes))
    }

    func testAutomaticPolicyLeavesAVFoundationBuffering() async throws {
        let fixture = try await CaptionHTTPFixture.make()
        defer { fixture.stop() }
        let model = PlaybackModel(client: fixture.client, preferences: PlaybackPreferences(defaults: defaults),
                                  bufferPolicy: .automatic)
        defer { model.stop() }
        model.play(fixture.item, mode: .original, preservingIntent: .paused)
        await waitFor("The relay-backed item is installed") { model.player.currentItem?.status == .readyToPlay }
        XCTAssertEqual(model.player.currentItem?.preferredForwardBufferDuration, 0)
        #if os(iOS)
        XCTAssertEqual(PlaybackBufferPolicy.platformDefault, .automatic,
                       "iPhone and iPad keep AVFoundation's memory-aware automatic buffering")
        #endif
    }

    func testWindowShrinksAsBitrateRisesAndNeverExceedsTheBudgetUnlessAtTheFloor() {
        let budget: Int64 = 512 * 1_024 * 1_024
        let policy = PlaybackBufferPolicy(memoryBudgetBytes: budget)
        var previous = Double.infinity
        for megabits in [1.0, 4, 8, 15, 25, 40, 60, 80, 150] {
            let bits = megabits * 1_000_000
            let seconds = policy.forwardBufferDuration(bitsPerSecond: bits)
            XCTAssertLessThanOrEqual(seconds, previous, "\(megabits) Mbps")
            XCTAssertGreaterThanOrEqual(seconds, policy.minimumSeconds)
            XCTAssertLessThanOrEqual(seconds, policy.maximumSeconds)
            if seconds > policy.minimumSeconds {
                XCTAssertLessThanOrEqual(seconds * bits / 8, Double(budget), "\(megabits) Mbps exceeds the budget")
            }
            previous = seconds
        }
        XCTAssertEqual(policy.forwardBufferDuration(bitsPerSecond: 8_000_000), policy.maximumSeconds,
                       "A 1080p-class stream fills the whole window")
        XCTAssertLessThan(policy.forwardBufferDuration(bitsPerSecond: 60_000_000), 120,
                          "A 4K remux keeps a shorter, memory-bounded window")
        XCTAssertEqual(policy.forwardBufferDuration(bitsPerSecond: nil), policy.unknownBitrateSeconds)
        XCTAssertEqual(policy.forwardBufferDuration(bitsPerSecond: .nan), policy.unknownBitrateSeconds)
        XCTAssertEqual(PlaybackBufferPolicy.automatic.forwardBufferDuration(bitsPerSecond: 8_000_000), 0)
    }

    func testPreparedQualityCanOnlyLowerTheSourceEstimate() async throws {
        let fixture = try await CaptionHTTPFixture.make()
        defer { fixture.stop() }
        let item = fixture.item
        let source = try XCTUnwrap(PlaybackBufferPolicy.estimatedBitsPerSecond(item: item, profile: nil))
        let profile = QualityProfile(id: "full_hd", label: "1080p", maxWidth: 1920, maxHeight: 1080,
                                     expectedBandwidthKbps: 8_448, automaticFallback: false)
        XCTAssertEqual(PlaybackBufferPolicy.estimatedBitsPerSecond(item: item, profile: profile), 8_448_000)
        let generous = QualityProfile(id: "huge", label: "Huge", maxWidth: 7680, maxHeight: 4320,
                                      expectedBandwidthKbps: Int(source / 1_000) * 2, automaticFallback: false)
        XCTAssertEqual(PlaybackBufferPolicy.estimatedBitsPerSecond(item: item, profile: generous), source,
                       "A profile above the source cannot raise a copied stream's bitrate")
    }

    private func waitFor(_ description: String, _ condition: @escaping () -> Bool) async {
        let done = expectation(description: description)
        let task = Task { for _ in 0..<600 { if condition() { done.fulfill(); return }; try? await Task.sleep(for: .milliseconds(10)) } }
        await fulfillment(of: [done], timeout: 8)
        task.cancel()
    }
}
