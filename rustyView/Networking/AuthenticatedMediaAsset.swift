import AVFoundation
import Foundation

final class AuthenticatedMediaAsset {
    let asset: AVURLAsset
    let sourceURL: URL
    let attemptID: UUID
    let outputPolicy = MediaOutputPolicy.localRelay
    private let relay: OwnedMediaRelay

    var rejection: UserFacingError? { relay.rejection }
    var onFailure: ((UserFacingError) -> Void)? {
        get { relay.onFailure }
        set { relay.onFailure = newValue }
    }

    init(url: URL, connection: ServerConnection) async throws {
        try Task.checkCancellation()
        sourceURL = url
        relay = try OwnedMediaRelay(sourceURL: url, connection: connection)
        attemptID = relay.attemptID
        let kind = MediaRelayResourceKind.source(url)
        let local: URL
        do {
            local = try await relay.assetURL()
            try Task.checkCancellation()
        }
        catch { relay.stop(); throw error }
        let options: [String: Any] = kind == .playlist ? [:] : [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ]
        asset = AVURLAsset(url: local, options: options)
    }

    func stop() {
        asset.cancelLoading()
        relay.stop()
    }
    deinit { relay.stop() }
}
