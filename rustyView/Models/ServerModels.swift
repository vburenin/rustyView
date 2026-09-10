import Foundation

enum MediaKind: String, Codable, Sendable {
    case video
    case audio
}

struct LibraryPage: Codable, Sendable {
    let schemaVersion: Int
    let generation: Int
    let serverName: String
    let rootFolderID: String
    let capabilities: ServerCapabilities
    let libraryState: String
    let view: String
    let folder: FolderReference?
    let breadcrumbs: [FolderReference]
    let offset: Int
    let limit: Int
    let total: Int
    let hasMore: Bool
    let query: String
    let sort: String
    let entries: [LibraryEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generation
        case serverName = "server_name"
        case rootFolderID = "root_folder_id"
        case capabilities
        case libraryState = "library_state"
        case view, folder, breadcrumbs, offset, limit, total
        case hasMore = "has_more"
        case query, sort, entries
    }
}

struct ServerCapabilities: Codable, Sendable {
    let transcoding: Bool
    let captions: Bool
    let qualityProfiles: [QualityProfile]

    enum CodingKeys: String, CodingKey {
        case transcoding, captions
        case qualityProfiles = "quality_profiles"
    }
}

struct QualityProfile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let maxWidth: Int
    let maxHeight: Int
    let expectedBandwidthKbps: Int
    let automaticFallback: Bool

    enum CodingKeys: String, CodingKey {
        case id, label
        case maxWidth = "max_width"
        case maxHeight = "max_height"
        case expectedBandwidthKbps = "expected_bandwidth_kbps"
        case automaticFallback = "automatic_fallback"
    }
}

struct FolderReference: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

struct LibraryEntry: Codable, Identifiable, Hashable, Sendable {
    let entryType: String
    let id: String
    let title: String
    let childCount: Int?
    let fileName: String?
    let kind: MediaKind?
    let mime: String?
    let ext: String?
    let duration: String?
    let durationSeconds: Int?
    let resolution: String?
    let width: Int?
    let height: Int?
    let about: String?
    let genre: String?
    let sizeBytes: UInt64?
    let container: String?
    let videoCodec: String?
    let audioCodec: String?
    let hdr: String?
    let artURL: String?
    let downloadURL: String?
    let sourceURL: String?
    let fallbackURL: String?
    let transcodeLikely: Bool?

    var isFolder: Bool { entryType == "folder" }

    enum CodingKeys: String, CodingKey {
        case entryType = "entry_type"
        case id, title
        case childCount = "child_count"
        case fileName = "file_name"
        case kind, mime, ext, duration
        case durationSeconds = "duration_seconds"
        case resolution, width, height, about, genre
        case sizeBytes = "size_bytes"
        case container
        case videoCodec = "video_codec"
        case audioCodec = "audio_codec"
        case hdr
        case artURL = "art_url"
        case downloadURL = "download_url"
        case sourceURL = "source_url"
        case fallbackURL = "fallback_url"
        case transcodeLikely = "transcode_likely"
    }
}

struct ItemResponse: Codable, Sendable {
    let schemaVersion: Int
    let id: String
    let item: MediaItem
    let audioTracks: [AudioTrack]
    let chapters: [Chapter]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id, item
        case audioTracks = "audio_tracks"
        case chapters
    }
}

struct TranscodeStatus: Codable, Sendable {
    let schemaVersion: Int
    let itemID: String
    let requestID: UInt64?
    let state: String
    let retryAfterSeconds: UInt64?
    let producedSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case itemID = "item_id"
        case requestID = "request_id"
        case state
        case retryAfterSeconds = "retry_after_seconds"
        case producedSeconds = "produced_seconds"
    }
}

struct MediaItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let fileName: String
    let kind: MediaKind
    let mime: String
    let ext: String
    let duration: String?
    let durationSeconds: Int?
    let resolution: String?
    let width: Int
    let height: Int
    let about: String?
    let plot: String?
    let genre: String?
    let sizeBytes: UInt64
    let container: String
    let videoCodec: String
    let videoProfile: String?
    let bitDepth: Int?
    let frameRate: String?
    let videoRepairRequired: Bool
    let audioCodec: String
    let audioLayout: String?
    let codecString: String?
    let hdr: String
    let audioTracks: [AudioTrack]
    let defaultAudioIndex: Int
    let captions: [CaptionTrack]
    let chapters: [Chapter]
    let artURL: String?
    let downloadURL: String?
    let sourceURL: String
    let fallbackURL: String
    let transcodeLikely: Bool

    enum CodingKeys: String, CodingKey {
        case id, title
        case fileName = "file_name"
        case kind, mime, ext, duration
        case durationSeconds = "duration_seconds"
        case resolution, width, height, about, plot, genre
        case sizeBytes = "size_bytes"
        case container
        case videoCodec = "video_codec"
        case videoProfile = "video_profile"
        case bitDepth = "bit_depth"
        case frameRate = "frame_rate"
        case videoRepairRequired = "video_repair_required"
        case audioCodec = "audio_codec"
        case audioLayout = "audio_layout"
        case codecString = "codec_string"
        case hdr
        case audioTracks = "audio_tracks"
        case defaultAudioIndex = "default_audio_index"
        case captions, chapters
        case artURL = "art_url"
        case downloadURL = "download_url"
        case sourceURL = "source_url"
        case fallbackURL = "fallback_url"
        case transcodeLikely = "transcode_likely"
    }
}

struct AudioTrack: Codable, Identifiable, Hashable, Sendable {
    let index: Int
    let codec: String
    let contentType: String?
    let channels: Int
    let language: String?
    let title: String?
    let `default`: Bool

    var id: Int { index }

    var displayName: String {
        AudioTrackName.display(title: title, language: language, fallback: "Track \(index + 1)")
    }

    var technicalLabel: String {
        let channelLabel = channels > 2 ? "\(channels) ch" : channels == 2 ? "Stereo" : channels == 1 ? "Mono" : "Channels unknown"
        return "\(codec.uppercased()) · \(channelLabel)"
    }

    func selectionLabel(defaultIndex: Int?) -> String {
        let isDefault = self.default || index == defaultIndex
        return "\(displayName) · \(technicalLabel)\(isDefault ? " · Default" : "")"
    }

    enum CodingKeys: String, CodingKey {
        case index, codec, channels, language, title, `default`
        case contentType = "content_type"
    }
}

struct CaptionTrack: Codable, Identifiable, Hashable, Sendable {
    let index: Int
    let label: String
    let language: String?
    let `default`: Bool
    let sourceFormat: String
    let browserSupported: Bool
    let url: String?

    var id: Int { index }
    var isPlayableOnDevice: Bool { browserSupported && url != nil }

    enum CodingKeys: String, CodingKey {
        case index, label, language, `default`
        case sourceFormat = "source_format"
        case browserSupported = "browser_supported"
        case url
    }
}

struct Chapter: Codable, Identifiable, Hashable, Sendable {
    let index: Int
    let title: String
    let startSeconds: Double
    let endSeconds: Double

    var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index, title
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }
}

struct ServerErrorEnvelope: Codable, Sendable {
    let schemaVersion: Int?
    let error: ServerErrorBody

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case error
    }
}

struct ServerErrorBody: Codable, Sendable {
    let code: String
    let message: String
    let recoverable: Bool
    let action: String?
}
