import Foundation

enum DownloadKind: String, Codable, CaseIterable, Sendable {
    case compatible
    case original

    var label: String {
        switch self {
        case .compatible: "Compatible offline copy"
        case .original: "Original file"
        }
    }
}

struct DownloadRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let serverOrigin: String
    let mediaID: String
    let title: String
    let kind: DownloadKind
    let fileName: String
    let byteCount: Int64
    let completedAt: Date
    let durationSeconds: Int?
    let resolution: String?
    let artworkPath: String?
    var qualityID: String? = nil
    var qualityLabel: String? = nil
    var audioTrackIndex: Int? = nil
    var audioTrackLabel: String? = nil

    var videoQualityDescription: String {
        DownloadMetadataPresentation.videoQuality(
            kind: kind,
            sourceResolution: resolution,
            qualityLabel: qualityLabel
        )
    }

    var audioSelectionDescription: String {
        DownloadMetadataPresentation.audioSelection(
            kind: kind,
            trackIndex: audioTrackIndex,
            trackLabel: audioTrackLabel
        )
    }
}

struct DownloadTaskMetadata: Codable, Equatable, Sendable {
    let recordID: UUID
    let serverOrigin: String
    let mediaID: String
    let title: String
    let kind: DownloadKind
    let fileExtension: String
    let durationSeconds: Int?
    let resolution: String?
    var serverPath: String? = nil
    var retryAttempt: Int? = nil
    var qualityID: String? = nil
    var qualityLabel: String? = nil
    var audioTrackIndex: Int? = nil
    var audioTrackLabel: String? = nil

    var videoQualityDescription: String {
        DownloadMetadataPresentation.videoQuality(
            kind: kind,
            sourceResolution: resolution,
            qualityLabel: qualityLabel
        )
    }

    var audioSelectionDescription: String {
        DownloadMetadataPresentation.audioSelection(
            kind: kind,
            trackIndex: audioTrackIndex,
            trackLabel: audioTrackLabel
        )
    }
}

private enum DownloadMetadataPresentation {
    static func videoQuality(
        kind: DownloadKind,
        sourceResolution: String?,
        qualityLabel: String?
    ) -> String {
        switch kind {
        case .original:
            return sourceResolution.map { "Original · \($0)" } ?? "Original quality"
        case .compatible:
            return qualityLabel.map { "Compatible · \($0)" } ?? "Compatible quality"
        }
    }

    static func audioSelection(
        kind: DownloadKind,
        trackIndex: Int?,
        trackLabel: String?
    ) -> String {
        guard kind == .compatible else { return "All original tracks" }
        let label = trackLabel ?? "Default track"
        guard let trackIndex else { return label }
        return "\(label) · Track ID \(trackIndex)"
    }
}

enum DownloadPhase: Equatable, Sendable {
    case queued
    case downloading(progress: Double, received: Int64, expected: Int64?)
    case retrying(attempt: Int, scheduledAt: Date, reason: String)
    case finishing
    case failed(message: String)

    var progress: Double? {
        if case .downloading(let progress, _, let expected) = self,
           expected != nil {
            return progress
        }
        return nil
    }
}

struct ActiveDownload: Identifiable, Equatable, Sendable {
    let id: UUID
    let serverOrigin: String
    let mediaID: String
    let title: String
    let kind: DownloadKind
    var phase: DownloadPhase
    var taskIdentifier: Int
    var metadata: DownloadTaskMetadata
}

struct DownloadPreparationProgress: Equatable, Sendable {
    let producedSeconds: Double
    let totalSeconds: Double

    init?(producedSeconds: Double, durationSeconds: Int?) {
        guard producedSeconds.isFinite,
              producedSeconds >= 0,
              let durationSeconds,
              durationSeconds > 0 else {
            return nil
        }
        totalSeconds = Double(durationSeconds)
        self.producedSeconds = min(producedSeconds, totalSeconds)
    }

    var fraction: Double { producedSeconds / totalSeconds }

    var percent: Int { Int((fraction * 100).rounded(.down)) }

    var presentationText: String {
        "Prepared \(Self.mediaTime(producedSeconds)) of \(Self.mediaTime(totalSeconds)) · \(percent)%"
    }

    private static func mediaTime(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        if value >= 3600 {
            return String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
        }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

struct DownloadManifest: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var records: [DownloadRecord] = []
}

enum DownloadResponseValidator {
    static func failure(for response: URLResponse?) -> String? {
        guard let response = response as? HTTPURLResponse else {
            return "The server returned an invalid download response."
        }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                return "The server rejected the saved credentials."
            }
            return "The download failed (HTTP \(response.statusCode))."
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if contentType?.hasPrefix("text/") == true || contentType == "application/json" {
            return "The server returned an error page instead of a video."
        }
        return nil
    }

    static func isRetryable(_ response: URLResponse?) -> Bool {
        guard let response = response as? HTTPURLResponse else { return true }
        return response.statusCode == 408 || response.statusCode == 429 || (500..<600).contains(response.statusCode)
    }
}

enum DownloadRetryPolicy {
    static let maximumAttempts = 6
    static func isRetryable(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive,
            NSURLErrorDataNotAllowed,
            NSURLErrorResourceUnavailable,
        ].contains(error.code)
    }

    static func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        let boundedExponent = min(max(0, attempt - 2), 8)
        return min(15 * 60, 5 * pow(2, Double(boundedExponent)))
    }
}

enum DownloadNetworkPolicy {
    static func apply(allowsCellularDownloads: Bool, to request: inout URLRequest) {
        request.allowsCellularAccess = allowsCellularDownloads
    }
}

enum DownloadProgressValues {
    static func expectedByteCount(reported: Int64, response: URLResponse?) -> Int64? {
        if reported > 0 { return reported }
        let responseLength = response?.expectedContentLength ?? NSURLSessionTransferSizeUnknown
        return responseLength > 0 ? responseLength : nil
    }
}
