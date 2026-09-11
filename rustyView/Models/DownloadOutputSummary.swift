import Foundation

/// Shares the selected output facts with URL construction. Server repair is
/// deliberately described as uncertain: its encoder can change HDR behavior.
struct CompatibleOutputPlan: Equatable {
    let videoMode: String
    let videoOutput: String?
    let audioIndex: Int

    init(item: MediaItem, quality: String, audioIndex: Int?, forceVideoTranscode: Bool = false, preserveHDR: Bool = true) {
        let sourceMode = PlaybackCompatibility.videoMode(for: item)
        let canEncodeHDR = preserveHDR && item.preparedVideoOutputs?.contains("hevc_hdr10") == true
        videoMode = forceVideoTranscode || quality != "auto" || (sourceMode == "repair" && canEncodeHDR)
            ? "transcode" : sourceMode
        videoOutput = videoMode == "transcode"
            ? (preserveHDR && item.preparedVideoOutputs?.contains("hevc_hdr10") == true ? "hevc_hdr10" : "h264_sdr") : nil
        self.audioIndex = audioIndex ?? item.defaultAudioIndex
    }
}

struct DownloadOutputSummary {
    let video: String
    let audio: String
    let subtitles: String
    let size: String
    let essential: String
    let featureChangeNotice: String?

    static func estimatedByteCount(item: MediaItem, kind: DownloadKind, quality: String,
                                   profile: QualityProfile?, audioIndex: Int?) -> Int64? {
        if kind == .original { return item.sizeBytes > 0 ? Int64(clamping: item.sizeBytes) : nil }
        let plan = CompatibleOutputPlan(item: item, quality: quality, audioIndex: audioIndex)
        guard plan.videoMode == "transcode", quality != "auto", let bandwidth = profile?.expectedBandwidthKbps,
              bandwidth > 0, let runtime = item.durationSeconds, runtime > 0 else { return nil }
        return Int64(min(Double(Int64.max / 2), Double(bandwidth) * 1_000 / 8 * Double(runtime)))
    }

    init(item: MediaItem, kind: DownloadKind, quality: String, profile: QualityProfile?, audioIndex: Int?,
         preserveHDR: Bool = true, downloadAudio: DownloadAudioSelection? = nil) {
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
            featureChangeNotice = nil
        } else {
            let plan = CompatibleOutputPlan(item: item, quality: quality, audioIndex: audioIndex, preserveHDR: preserveHDR)
            switch plan.videoMode {
            case "copy": video = "MP4 · Source video and \(item.hdr.uppercased()) preserved."
            case "repair": video = "MP4 · Video repair may change quality or HDR."
            default:
                let limit = quality != "auto" ? profile.map { "Up to \($0.label)" } : nil
                video = "MP4 · \(plan.videoOutput == "hevc_hdr10" ? "HEVC HDR10" : "H.264 SDR") · \(limit ?? "Auto")"
            }
            let selected = item.audioTracks.first { $0.index == plan.audioIndex }
            let audioName = selected.flatMap { $0.displayName.uppercased() == "UND" ? nil : $0.displayName } ?? "Selected audio"
            if let downloadAudio {
                audio = (downloadAudio == .all ? "All \(item.audioTracks.count) audio tracks." : "\(audioName).")
                    + " Supported audio is preserved; other audio becomes AAC with up to 8 channels."
            } else {
                audio = "\(audioName) · AAC stereo · One audio track"
            }
            if downloadAudio != nil, plan.videoMode == "transcode", quality != "auto",
               let bitrate = profile?.maxVideoKbps, bitrate > 0, let runtime = item.durationSeconds, runtime > 0 {
                let budget = UInt64(min(Double(Int64.max / 2), Double(bitrate) * 1_000 / 8 * Double(runtime)))
                size = "Video budget about \(Self.bytes(budget)); audio adds to this"
            } else if downloadAudio == nil,
                      let estimate = Self.estimatedByteCount(item: item, kind: kind, quality: quality, profile: profile, audioIndex: audioIndex) {
                size = "Up to about \(Self.bytes(UInt64(estimate)))"
            } else { size = "Size unknown" }
            var facts = [size, downloadAudio == .all ? "All audio tracks" : downloadAudio == .selected ? "Preferred audio · channels preserved where supported" : "Stereo"]
            var changes: [String] = []
            if plan.videoOutput == "hevc_hdr10" {
                let sourceHDR = item.hdr.lowercased()
                facts.append(sourceHDR.hasPrefix("dv") || sourceHDR.contains("dolby") ? "Dolby Vision becomes HDR10" : "HDR10")
                if sourceHDR.hasPrefix("dv") || sourceHDR.contains("dolby") { changes.append("Dolby Vision becomes HDR10.") }
            }
            else if plan.videoMode == "transcode", !item.hdr.isEmpty, item.hdr.lowercased() != "sdr" {
                facts.append("HDR becomes SDR")
                changes.append("HDR becomes SDR.")
            }
            if plan.videoMode == "repair" {
                facts.append("Video quality or HDR may change")
                changes.append("Video quality or HDR may change.")
            }
            if downloadAudio == nil { changes.append("Audio becomes stereo.") }
            changes.append("Embedded subtitles are not included.")
            featureChangeNotice = changes.joined(separator: " ")
            facts.append(available > 0 ? sidecars + " Embedded subtitles omitted." : "Embedded subtitles omitted; no separate subtitle files")
            essential = facts.joined(separator: " · ")
        }
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}
