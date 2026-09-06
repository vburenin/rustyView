import Foundation
import Combine

@MainActor
final class PlaybackPreferences: ObservableObject {
    @Published var preferredQualityID: String {
        didSet { defaults.set(preferredQualityID, forKey: "playback.preferredQuality") }
    }
    @Published var preferredAudioLanguage: String? {
        didSet { defaults.set(preferredAudioLanguage, forKey: "playback.preferredAudioLanguage") }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferredQualityID = defaults.string(forKey: "playback.preferredQuality") ?? "auto"
        preferredAudioLanguage = defaults.string(forKey: "playback.preferredAudioLanguage")
    }

    func quality(in profiles: [QualityProfile]) -> PlaybackQualityResolution {
        PlaybackQualityResolution(preferredID: preferredQualityID, profiles: profiles)
    }

    func audioIndex(in item: MediaItem) -> Int {
        let languages = preferredAudioLanguage.map { [$0] } ?? []
        for language in languages {
            if let track = item.audioTracks.first(where: { PlaybackLanguage.matches($0.language, language) }) { return track.index }
        }
        return item.defaultAudioIndex
    }
}

struct PlaybackQualityResolution: Equatable {
    let qualityID: String
    let displayLabel: String
    let notice: String?

    init(preferredID: String, profiles: [QualityProfile]) {
        if preferredID == "auto" {
            qualityID = "auto"
            displayLabel = profiles.first { $0.id == "auto" }?.label ?? "Auto"
            notice = nil
        } else if let profile = profiles.first(where: { $0.id == preferredID }) {
            qualityID = profile.id
            displayLabel = profile.label
            notice = nil
        } else {
            qualityID = "auto"
            displayLabel = "Auto"
            notice = "Preferred quality unavailable; using Auto for this movie."
        }
    }
}

enum PlaybackLanguage {
    static func matches(_ actual: String?, _ preferred: String) -> Bool {
        guard let actual, !actual.isEmpty, !preferred.isEmpty else { return false }
        let left = Locale.Language(identifier: actual).languageCode
        let right = Locale.Language(identifier: preferred).languageCode
        return left != nil && left == right
    }
}

/// Draft mutations never reach the player until Apply. Contradictory choices
/// change together in this visible draft rather than during a later retry.
struct StreamingSettingsDraft: Equatable {
    private(set) var mode: PlaybackMode
    private(set) var quality: String

    init(mode: PlaybackMode, quality: String) { self.mode = mode; self.quality = quality }
    mutating func selectMode(_ mode: PlaybackMode) {
        self.mode = mode
        if mode == .original { quality = "auto" }
    }
    mutating func selectQuality(_ quality: String) {
        self.quality = quality
        if quality != "auto" && mode == .original { mode = .compatible }
    }
    func isValid(in profiles: [QualityProfile]) -> Bool {
        (quality == "auto" || profiles.contains { $0.id == quality }) && (mode != .original || quality == "auto")
    }
}
