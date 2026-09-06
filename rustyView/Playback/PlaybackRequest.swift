import Foundation

enum PlaybackStart: Equatable, Sendable {
    case resume
    case startOver
    case position(Double)

    var explicitPosition: Double? {
        switch self {
        case .resume: nil
        case .startOver: 0
        case .position(let seconds): seconds.isFinite ? max(0, seconds) : 0
        }
    }
}

struct LocalCaptionSource: Hashable, Sendable, Identifiable {
    let caption: OfflineCaption
    let url: URL
    var id: UUID { caption.id }
}

/// A viewing decision captures its source. An offline request never needs a
/// connection; an online request cannot silently adopt another account.
struct PlaybackRequest {
    enum Source {
        case online(item: MediaItem, connection: ServerConnection)
        case offline(record: DownloadRecord, url: URL, captionSources: [LocalCaptionSource])
    }

    let movie: MovieMetadata
    let source: Source
    let start: PlaybackStart
    var quality = "auto"
    var audioIndex: Int?
    var qualityNotice: String?
    var qualityProfiles: [QualityProfile]?

    static func online(item: MediaItem, connection: ServerConnection, start: PlaybackStart = .resume,
                       quality: String = "auto", audioIndex: Int? = nil,
                       qualityNotice: String? = nil, qualityProfiles: [QualityProfile]? = nil) -> Self {
        Self(movie: MovieMetadata(item: item), source: .online(item: item, connection: connection),
             start: start, quality: quality, audioIndex: audioIndex,
             qualityNotice: qualityNotice, qualityProfiles: qualityProfiles)
    }

    static func offline(record: DownloadRecord, url: URL, captionSources: [LocalCaptionSource] = [],
                        start: PlaybackStart = .resume) -> Self {
        Self(movie: record.movieMetadata, source: .offline(record: record, url: url, captionSources: captionSources), start: start)
    }
}

/// IDs refer to an AVFoundation option from this asset, never a server index.
struct LocalPlaybackTrack: Identifiable, Equatable {
    let id: String
    let title: String
    let language: String?
    let isDefault: Bool
    let isForced: Bool
}
