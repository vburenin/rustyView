import Foundation

/// Shares the selected output facts with URL construction. Server repair is
/// deliberately described as uncertain: its encoder can change HDR behavior.
struct CompatibleOutputPlan: Equatable {
    let videoMode: String
    let videoOutput: String?
    let audioIndex: Int

    init(item: MediaItem, quality: String, audioIndex: Int?, forceVideoTranscode: Bool = false) {
        videoMode = forceVideoTranscode || quality != "auto" ? "transcode" : PlaybackCompatibility.videoMode(for: item)
        videoOutput = videoMode == "transcode" ? "h264_sdr" : nil
        self.audioIndex = audioIndex ?? item.defaultAudioIndex
    }
}

struct DownloadOutputSummary {
    let video: String
    let audio: String
    let subtitles: String
    let size: String
    let essential: String

    static func estimatedByteCount(item: MediaItem, kind: DownloadKind, quality: String,
                                   profile: QualityProfile?, audioIndex: Int?) -> Int64? {
        if kind == .original { return item.sizeBytes > 0 ? Int64(clamping: item.sizeBytes) : nil }
        let plan = CompatibleOutputPlan(item: item, quality: quality, audioIndex: audioIndex)
        guard plan.videoMode == "transcode", quality != "auto", let bandwidth = profile?.expectedBandwidthKbps,
              bandwidth > 0, let runtime = item.durationSeconds, runtime > 0 else { return nil }
        return Int64(min(Double(Int64.max / 2), Double(bandwidth) * 1_000 / 8 * Double(runtime)))
    }

    init(item: MediaItem, kind: DownloadKind, quality: String, profile: QualityProfile?, audioIndex: Int?) {
        let available = item.captions.filter(\.isPlayableOnDevice).count
        let sidecars = available > 0 ? "\(available) subtitle file\(available == 1 ? "" : "s") included."
            : "No subtitle files available."
        subtitles = sidecars + (kind == .original
            ? " Embedded subtitles preserved; playback support varies."
            : " Embedded subtitles not included.")
        if kind == .original {
            video = "Source resolution and \(item.hdr.uppercased()) preserved."
            audio = "All original audio tracks; playback support varies."
            size = item.sizeBytes > 0 ? Self.bytes(item.sizeBytes) : "Size unknown"
            essential = "\(size) · May not play"
        } else {
            let plan = CompatibleOutputPlan(item: item, quality: quality, audioIndex: audioIndex)
            switch plan.videoMode {
            case "copy": video = "MP4 · Source video and \(item.hdr.uppercased()) preserved."
            case "repair": video = "MP4 · Video repair may change quality or HDR."
            default: video = "MP4 · H.264 SDR · \(profile?.label ?? "Auto")"
            }
            let selected = item.audioTracks.first { $0.index == plan.audioIndex }
            let audioName = selected.flatMap { $0.displayName.uppercased() == "UND" ? nil : $0.displayName } ?? "Selected audio"
            audio = "\(audioName) · AAC stereo · One audio track"
            if let estimate = Self.estimatedByteCount(item: item, kind: kind, quality: quality, profile: profile, audioIndex: audioIndex) {
                size = "About \(Self.bytes(UInt64(estimate)))"
            } else { size = "Size unknown" }
            var facts = [size, "Stereo"]
            if plan.videoMode == "transcode", !item.hdr.isEmpty, item.hdr.lowercased() != "sdr" { facts.append("HDR becomes SDR") }
            if plan.videoMode == "repair" { facts.append("Video quality or HDR may change") }
            facts.append("Embedded subtitles omitted")
            essential = facts.joined(separator: " · ")
        }
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}
