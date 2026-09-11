import Foundation

enum DownloadWaitingReason: String, Codable, Sendable {
    case wifi, network, credentials, turn

    var message: String {
        switch self {
        case .wifi: "Waiting for Wi-Fi"
        case .network: "Waiting for a connection"
        case .credentials: "Reconnect to this download's account to continue"
        case .turn: "Waiting for another download to finish"
        }
    }
}

enum DownloadResourceState: String, Codable, Sendable {
    case queued, running, pausing, paused, delivered, failed, cancelled
}

/// Transfer attempts belong to one package component. Retrying a caption must
/// not invalidate a verified movie that has already reached owned staging.
struct DownloadResourceDescriptor: Codable, Hashable, Identifiable, Sendable {
    let resource: OfflineResource
    var serverPath: String
    var transferID: UUID
    var state: DownloadResourceState = .queued
    var taskIdentifier: Int?
    var sessionIdentifier: String?
    var retryAttempt: Int = 0
    var scheduledAt: Date?
    var resumeReference: String?
    var receivedBytes: Int64 = 0
    var expectedBytes: Int64?
    var reason: String?
    var failure: UserFacingError? = nil
    var verificationPending: Bool? = nil
    var id: String { resource.runtimeID }

    init(resource: OfflineResource, transferID: UUID = UUID()) {
        self.resource = resource
        serverPath = resource.remotePath
        self.transferID = transferID
    }

    var sizeLimit: Int64? {
        switch resource.kind {
        case .media: nil
        case .artwork: 20 * 1_024 * 1_024
        case .caption: 5 * 1_024 * 1_024
        }
    }
}

struct DownloadTaskEnvelope: Codable, Equatable, Sendable {
    var schemaVersion = 2
    let metadata: DownloadTaskMetadata
    let resourceID: String
    let transferID: UUID
    let kind: OfflineResourceKind

    init(metadata: DownloadTaskMetadata, resource: DownloadResourceDescriptor) {
        self.metadata = metadata
        resourceID = resource.id
        transferID = resource.transferID
        kind = resource.resource.kind
    }

    init(legacyMetadata: DownloadTaskMetadata) {
        metadata = legacyMetadata
        resourceID = "video"
        transferID = legacyMetadata.attemptID ?? legacyMetadata.recordID
        kind = .media
    }

    static func decode(_ description: String?) -> DownloadTaskEnvelope? {
        guard let data = description?.data(using: .utf8) else { return nil }
        if let envelope = try? JSONDecoder().decode(Self.self, from: data), envelope.schemaVersion == 2 {
            return envelope
        }
        return (try? JSONDecoder().decode(DownloadTaskMetadata.self, from: data)).map(Self.init(legacyMetadata:))
    }
}

enum DownloadHTTPRange {
    /// URLSession's resumed temporary file includes its earlier bytes. A 206
    /// Content-Length describes only the new body, not that assembled file.
    static func completeLength(of response: URLResponse?) -> Int64? {
        guard let response = response as? HTTPURLResponse else { return nil }
        if response.statusCode == 206 {
            guard let value = response.value(forHTTPHeaderField: "Content-Range"),
                  let range = parse(value) else { return nil }
            return range.total
        }
        return response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }

    static func parse(_ value: String) -> (start: Int64, end: Int64, total: Int64?)? {
        let parts = value.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let lengths = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        guard lengths.count == 2 else { return nil }
        let bounds = lengths[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start else { return nil }
        if lengths[1] == "*" { return (start, end, nil) }
        guard let total = Int64(lengths[1]), total > end else { return nil }
        return (start, end, total)
    }
}
