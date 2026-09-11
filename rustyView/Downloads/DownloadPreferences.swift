import Combine
import Foundation

struct DownloadQualityLimit: Codable, Hashable {
    let width: Int
    let height: Int
    let videoKbps: Int

    init(width: Int, height: Int, videoKbps: Int) {
        self.width = width; self.height = height; self.videoKbps = videoKbps
    }

    init(_ profile: QualityProfile) {
        self.init(width: profile.maxWidth, height: profile.maxHeight,
                  videoKbps: profile.maxVideoKbps ?? profile.expectedBandwidthKbps)
    }

    var label: String { "Up to \(height)p · \((Double(videoKbps) / 1_000).formatted(.number)) Mbps" }
    static let phoneDefault = Self(width: 1920, height: 1080, videoKbps: 8_000)
}

enum DownloadAudioSelection: String, Codable, CaseIterable, Identifiable {
    case selected, all
    var id: String { rawValue }
    var label: String { self == .all ? "All audio tracks" : "Preferred language" }
}

@MainActor
final class DownloadPreferences: ObservableObject {
    @Published var maximumQuality: DownloadQualityLimit? {
        didSet {
            defaults.set(maximumQuality == nil, forKey: "download.sourceQuality")
            defaults.set(maximumQuality.flatMap { try? JSONEncoder().encode($0) }, forKey: "download.maximumQuality")
        }
    }
    @Published var preserveHDR: Bool {
        didSet { defaults.set(preserveHDR, forKey: "download.preserveHDR") }
    }
    @Published var audioSelection: DownloadAudioSelection {
        didSet { defaults.set(audioSelection.rawValue, forKey: "download.audioSelection") }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        maximumQuality = defaults.bool(forKey: "download.sourceQuality") ? nil
            : defaults.data(forKey: "download.maximumQuality").flatMap { try? JSONDecoder().decode(DownloadQualityLimit.self, from: $0) }
                ?? .phoneDefault
        preserveHDR = defaults.object(forKey: "download.preserveHDR") as? Bool ?? true
        audioSelection = defaults.string(forKey: "download.audioSelection").flatMap(DownloadAudioSelection.init(rawValue:)) ?? .selected
    }

    func resolve(item: MediaItem, capabilities: ServerCapabilities) -> DownloadQualityResolution {
        guard let maximumQuality else {
            return .init(profile: capabilities.qualityProfiles.first { $0.id == "auto" }, quality: "auto", issue: nil)
        }
        let candidates = capabilities.qualityProfiles.filter { profile in
            guard profile.id != "auto", profile.maxWidth > 0, profile.maxHeight > 0,
                  profile.maxWidth <= maximumQuality.width, profile.maxHeight <= maximumQuality.height,
                  (profile.maxVideoKbps ?? profile.expectedBandwidthKbps) > 0,
                  (profile.maxVideoKbps ?? profile.expectedBandwidthKbps) <= maximumQuality.videoKbps else { return false }
            // Legacy AI-enabled servers cannot disable enlargement explicitly.
            // Only use an envelope that cannot request an upscale on them.
            if capabilities.nativeDownloads != true && capabilities.aiUpscale != nil {
                return item.width > 0 && item.height > 0
                    && (profile.maxWidth <= item.width || profile.maxHeight <= item.height)
            }
            return true
        }.sorted {
            let lhs = Double($0.maxWidth) * Double($0.maxHeight)
            let rhs = Double($1.maxWidth) * Double($1.maxHeight)
            if lhs != rhs { return lhs > rhs }
            return ($0.maxVideoKbps ?? $0.expectedBandwidthKbps) > ($1.maxVideoKbps ?? $1.expectedBandwidthKbps)
        }
        guard let chosen = candidates.first else {
            return .init(profile: nil, quality: nil,
                issue: "This server cannot make a download within your saved limit. Choose another maximum quality in Settings or update the server.")
        }
        return .init(profile: chosen, quality: chosen.id, issue: nil)
    }
}

struct DownloadQualityResolution {
    let profile: QualityProfile?
    let quality: String?
    let issue: String?
}
