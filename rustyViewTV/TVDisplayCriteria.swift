import AVFoundation
import AVKit
import Combine
import OSLog
import SwiftUI

/// Asks tvOS to switch the TV to the playing video's dynamic range and frame
/// rate when the person has turned on Match Dynamic Range or Match Frame Rate.
/// `AVPlayerViewController` does this itself; this app draws its own player on
/// an `AVPlayerLayer`, so without it HDR10 and Dolby Vision play in whatever
/// mode the Home screen uses.
///
/// The criteria come from the playing item's actual video format description.
/// A copied Dolby Vision Profile 8 stream (`hvc1` with `dvvC`) selects Dolby
/// Vision, PQ selects HDR10, and an SDR fallback stream returns to SDR.
struct TVDisplayCriteriaBridge: UIViewRepresentable {
    let player: AVPlayer
    /// Server-reported source frame rate, such as "24000/1001". HLS video
    /// tracks report no nominal frame rate of their own.
    let sourceFrameRate: String?

    func makeUIView(context: Context) -> TVDisplayCriteriaView {
        let view = TVDisplayCriteriaView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.configure(player: player, sourceFrameRate: sourceFrameRate)
        return view
    }

    func updateUIView(_ view: TVDisplayCriteriaView, context: Context) {
        view.configure(player: player, sourceFrameRate: sourceFrameRate)
    }

    static func dismantleUIView(_ view: TVDisplayCriteriaView, coordinator: ()) {
        view.reset()
    }
}

final class TVDisplayCriteriaView: UIView {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "rustyView", category: "DisplayCriteria")
    private weak var player: AVPlayer?
    private var sourceFrameRate: String?
    private var itemSubscription: AnyCancellable?
    private var tracksSubscription: AnyCancellable?
    private var loadTask: Task<Void, Never>?
    private var applied: (format: CMFormatDescription, rate: Float)?
    /// The window whose display manager holds this player's criteria, so the
    /// request is withdrawn there even after the view has left it.
    private weak var requestingWindow: UIWindow?

    func configure(player: AVPlayer, sourceFrameRate: String?) {
        self.sourceFrameRate = sourceFrameRate
        guard player !== self.player else { return }
        self.player = player
        itemSubscription = player.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in self?.follow(item) }
    }

    /// Withdraws the request so the TV returns to the Home screen's mode.
    func reset() {
        loadTask?.cancel()
        loadTask = nil
        if requestingWindow != nil { Self.log.info("Withdrew the display mode request") }
        requestingWindow?.avDisplayManager.preferredDisplayCriteria = nil
        requestingWindow = nil
        applied = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            reset()
        } else if let item = player?.currentItem {
            evaluate(item, tracks: item.tracks)
        }
    }

    private func follow(_ item: AVPlayerItem?) {
        loadTask?.cancel()
        // A new item (a seek restart, recovery, or another movie) keeps the
        // current mode until its own format is known.
        tracksSubscription = item?.publisher(for: \.tracks)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] tracks in
                guard let self, let item else { return }
                self.evaluate(item, tracks: tracks)
            }
    }

    private func evaluate(_ item: AVPlayerItem, tracks: [AVPlayerItemTrack]) {
        guard window != nil,
              let track = tracks.lazy.compactMap(\.assetTrack).first(where: { $0.mediaType == .video }) else { return }
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let (formats, nominalRate) = try? await track.load(.formatDescriptions, .nominalFrameRate),
                  let format = formats.first, !Task.isCancelled,
                  let self, self.player?.currentItem === item else { return }
            let rate = nominalRate > 0 ? nominalRate : Self.frameRate(self.sourceFrameRate) ?? 0
            self.request(format: format, rate: rate)
        }
    }

    private func request(format: CMFormatDescription, rate: Float) {
        if let applied, applied.rate == rate, CMFormatDescriptionEqual(applied.format, otherFormatDescription: format) {
            return
        }
        guard let window else { return }
        // A rate of zero leaves the refresh rate to the system.
        window.avDisplayManager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: rate, formatDescription: format)
        requestingWindow = window
        applied = (format, rate)
        Self.log.info("Requested \(Self.dynamicRange(format), privacy: .public) display mode at \(rate, privacy: .public) fps")
    }

    /// A diagnostic label for the requested mode, from public format facts.
    static func dynamicRange(_ format: CMFormatDescription) -> String {
        let atoms = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        if atoms?["dvvC"] != nil || atoms?["dvcC"] != nil || atoms?["dvwC"] != nil { return "Dolby Vision" }
        let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
        if let transfer = transfer as? String {
            if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { return "HDR10" }
            if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { return "HLG" }
        }
        return "SDR"
    }

    /// Parses FFprobe's rational ("24000/1001") or decimal ("23.976") rate.
    static func frameRate(_ value: String?) -> Float? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        let rate: Double?
        if parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator > 0 {
            rate = numerator / denominator
        } else {
            rate = Double(value)
        }
        guard let rate, rate.isFinite, rate > 0, rate <= 240 else { return nil }
        return Float(rate)
    }
}
