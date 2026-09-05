import AVFoundation
import AVKit
import SwiftUI

enum VideoResizeMode: String, CaseIterable, Identifiable {
    case fit
    case fill

    var id: String { rawValue }
    var label: String { self == .fit ? "Fit" : "Fill" }
    var icon: String { self == .fit ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right" }
    var gravity: AVLayerVideoGravity { self == .fit ? .resizeAspect : .resizeAspectFill }
}

/// A control-free AVPlayerLayer host. The app owns the controls while AVFoundation
/// continues to own decoding, external playback, and Picture in Picture rendering.
struct PlayerVideoView: UIViewRepresentable {
    let player: AVPlayer
    let resizeMode: VideoResizeMode
    let pictureInPicture: PlayerPictureInPictureController

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = resizeMode.gravity
        pictureInPicture.connect(to: view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.videoGravity = resizeMode.gravity
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: Void) {
        view.playerLayer.player = nil
    }
}

/// Owns AVKit's PiP controller for the lifetime of the player screen. `toggle()`
/// is intentionally called directly by the button action: Apple requires PiP to
/// begin in response to user interaction, not from a deferred state update.
@MainActor
final class PlayerPictureInPictureController: NSObject, ObservableObject {
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false
    @Published var errorMessage: String?

    private var controller: AVPictureInPictureController?
    private var possibilityObservation: NSKeyValueObservation?

    func connect(to playerLayer: AVPlayerLayer) {
        guard controller == nil,
              AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: playerLayer)
        else { return }

        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
        possibilityObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            Task { @MainActor [weak self] in
                self?.isPossible = controller.isPictureInPicturePossible
            }
        }
    }

    func toggle() {
        guard let controller else { return }
        errorMessage = nil
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            errorMessage = "Picture in Picture is not ready for this video yet."
        }
    }

}

extension PlayerPictureInPictureController: @MainActor AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isActive = false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isActive = false
        errorMessage = error.localizedDescription
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .white
        picker.activeTintColor = UIColor(named: "AccessibleAccent") ?? .systemOrange
        picker.accessibilityLabel = "AirPlay"
        picker.accessibilityIdentifier = "airplay-route-picker"
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}
