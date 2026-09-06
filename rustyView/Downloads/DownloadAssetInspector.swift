import AVFoundation
import CoreVideo
import Foundation
import UniformTypeIdentifiers

enum DownloadIntegrity: String, Codable, Hashable, Sendable {
    case verified
    case unverified
    case invalid
}

enum DownloadPlayability: String, Codable, Hashable, Sendable {
    case playable
    case unsupported
    case unknown
}

/// Inspection is evidence about the stored asset, not a promise that every frame will decode.
struct DownloadAssetInspection: Codable, Hashable, Sendable {
    let integrity: DownloadIntegrity
    let playability: DownloadPlayability
    let durationSeconds: Double?
    let videoTrackCount: Int
    let audioTrackCount: Int
    let inspectedAt: Date
    var fileModificationDate: Date? = nil

    static var unsupported: DownloadAssetInspection { DownloadAssetInspection(
        integrity: .unverified, playability: .unsupported, durationSeconds: nil,
        videoTrackCount: 0, audioTrackCount: 0, inspectedAt: Date()
    ) }
}

enum DownloadAssetInspector {
    /// URLSession owns its temporary file only for the synchronous delegate callback.
    /// Keep this bounded bridge on that callback's background queue; AVFoundation loading
    /// itself uses asynchronous APIs and never needs the main actor.
    static func inspect(_ url: URL, fileExtension: String? = nil) -> DownloadAssetInspection {
        guard url.isFileURL else { return .unsupported }
        let result = InspectionResult()
        let signal = DispatchSemaphore(value: 0)
        let work = Task.detached(priority: .utility) {
            let inspection = await inspectAsset(url, fileExtension: fileExtension)
            result.set(inspection)
            signal.signal()
        }
        let completed = signal.wait(timeout: .now() + 30) == .success
        if !completed { work.cancel() }
        var inspection = (completed ? result.get() : nil) ?? .unsupported
        inspection.fileModificationDate = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        return inspection
    }

    private static func inspectAsset(_ url: URL, fileExtension: String?) async -> DownloadAssetInspection {
        var options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ]
        // System download files use .tmp (or no extension). Supply the rendition's
        // parser hint; tracks and real sample reads still determine readiness.
        if let fileExtension,
           let mimeType = UTType(filenameExtension: fileExtension)?.preferredMIMEType {
            options[AVURLAssetOverrideMIMETypeKey] = mimeType
        }
        let asset = AVURLAsset(url: url, options: options)
        do {
            let duration = try await asset.load(.duration).seconds
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let playable = try await asset.load(.isPlayable)
            guard duration.isFinite, duration > 0, !video.isEmpty else { return .unsupported }
            guard playable else {
                return inspection(.unverified, .unsupported, duration, video.count, audio.count)
            }
            // Read all compressed samples so a fast-start MP4 with an intact index but
            // missing tail data cannot pass on its header alone. Decode the beginning
            // and end of the primary tracks to check this device's actual decoders.
            for track in video + audio {
                guard read(asset, track: track, settings: nil, range: nil) else {
                    return inspection(.invalid, .unknown, duration, video.count, audio.count)
                }
            }
            let primaryTracks = Array(video.prefix(1)) + Array(audio.prefix(1))
            for track in primaryTracks {
                let trackRange = try await track.load(.timeRange)
                let mediaType = track.mediaType
                let settings: [String: Any] = mediaType == .video
                    ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    : [AVFormatIDKey: kAudioFormatLinearPCM]
                let window = min(1, trackRange.duration.seconds)
                guard window.isFinite, window > 0 else {
                    return inspection(.invalid, .unknown, duration, video.count, audio.count)
                }
                for offset in [0.0, max(0, trackRange.duration.seconds - window)] {
                    let range = CMTimeRange(
                        start: trackRange.start + CMTime(seconds: offset, preferredTimescale: 600),
                        duration: CMTime(seconds: window, preferredTimescale: 600)
                    )
                    guard read(asset, track: track, settings: settings, range: range) else {
                        return inspection(.unverified, .unsupported, duration, video.count, audio.count)
                    }
                }
            }
            return inspection(.verified, .playable, duration, video.count, audio.count)
        } catch {
            return .unsupported
        }
    }

    private static func read(
        _ asset: AVAsset,
        track: AVAssetTrack,
        settings: [String: Any]?,
        range: CMTimeRange?
    ) -> Bool {
        guard !Task.isCancelled, let reader = try? AVAssetReader(asset: asset) else { return false }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        if let range { reader.timeRange = range }
        guard reader.startReading() else { return false }
        var sampleCount = 0
        while !Task.isCancelled {
            let hadSample = autoreleasepool { output.copyNextSampleBuffer() != nil }
            guard hadSample else { break }
            sampleCount += 1
        }
        if Task.isCancelled { reader.cancelReading(); return false }
        return sampleCount > 0 && reader.status == .completed
    }

    private static func inspection(
        _ integrity: DownloadIntegrity, _ playability: DownloadPlayability,
        _ duration: Double, _ video: Int, _ audio: Int
    ) -> DownloadAssetInspection {
        DownloadAssetInspection(
            integrity: integrity, playability: playability, durationSeconds: duration,
            videoTrackCount: video, audioTrackCount: audio, inspectedAt: Date()
        )
    }
}

private final class InspectionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DownloadAssetInspection?

    func set(_ value: DownloadAssetInspection) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    func get() -> DownloadAssetInspection? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
