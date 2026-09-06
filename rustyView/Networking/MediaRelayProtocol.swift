import Foundation

enum MediaOutputPolicy: Equatable, Sendable {
    case native
    case localRelay
    var allowsExternalPlayback: Bool { self == .native }
    var explanation: String? {
        self == .localRelay
            ? "AirPlay video is unavailable for this stream. Try Screen Mirroring."
            : nil
    }
}

struct MediaRelayLimits: Sendable {
    var activeRequests = 4
    var waitingRequests = 16
    var acceptedConnections = 24
    var headerBytes = 16 * 1024
    var headerTimeout: TimeInterval = 5
    var playlistBytes = 8 * 1024 * 1024
    var registeredURLs = 32_768
    var registeredURLBytes = 16 * 1024 * 1024
    var URLBytes = 16 * 1024
    var streamBufferBytes = 8 * 1024 * 1024
    var totalBufferBytes = 16 * 1024 * 1024
    var redirectHops = 5
}

enum MediaRelayResourceKind: Sendable {
    case playlist, media, key
    static func source(_ url: URL) -> Self {
        let delivery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "delivery" }?.value
        return url.pathExtension.lowercased() == "m3u8" || delivery == "hls" ? .playlist : .media
    }
}

enum MediaRelayError: Error {
    case untrustedReference
    case invalidPlaylist
    case unexpectedPlaylist
    case resourceLimit
    case invalidRequest
    case invalidResponse
    case cancelled

    var issue: UserFacingError {
        switch self {
        case .untrustedReference:
            UserFacingError(category: .transportSecurity, title: "Playback blocked",
                            message: "This stream contains media references the app cannot safely load within its trusted connection. Check the server connection before trying again.")
        case .unexpectedPlaylist:
            UserFacingError(category: .transportSecurity, title: "Playback blocked",
                            message: "The server returned a playlist where a media file was expected. Check the server connection before trying again.")
        case .invalidPlaylist:
            UserFacingError(category: .incompatibleServer, title: "Stream unavailable",
                            message: "The server returned a stream format this app cannot safely load. Check for an app or server update.")
        case .resourceLimit:
            UserFacingError(category: .invalidMedia, title: "Stream unavailable",
                            message: "This stream exceeded the app's loading limits. Try another playback quality.")
        case .cancelled:
            UserFacingError(category: .cancelled, title: "Playback cancelled", message: "Playback was cancelled.")
        case .invalidRequest, .invalidResponse:
            UserFacingError(category: .invalidMedia, title: "Stream unavailable", message: "The server returned an invalid media response.")
        }
    }
}

struct MediaRelayHTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]

    static func parse(_ data: Data, port: UInt16) throws -> Self {
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\r\n\r\n"),
              !text.dropLast(4).contains("\r\n\r\n") else { throw MediaRelayError.invalidRequest }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[0] == "GET" || first[0] == "HEAD", first[2] == "HTTP/1.1",
              first[1].hasPrefix("/"), !first[1].contains("?"), !first[1].contains("#") else { throw MediaRelayError.invalidRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw MediaRelayError.invalidRequest }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, headers[key] == nil,
                  value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { throw MediaRelayError.invalidRequest }
            headers[key] = value
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0" else { throw MediaRelayError.invalidRequest }
        if let range = headers["range"] {
            guard range.range(of: #"^bytes=(?:[0-9]+-[0-9]*|-[0-9]+)$"#, options: .regularExpression) != nil else { throw MediaRelayError.invalidRequest }
        }
        return Self(method: String(first[0]), target: String(first[1]), headers: headers)
    }
}

struct MediaRelayResource: Sendable {
    let url: URL
    let kind: MediaRelayResourceKind
}

/// Queue-confined registry. Complete EVENT playlists retain all routes for this
/// playback attempt, including resources a paused or seeking AVPlayer may need.
struct MediaRelayRegistry {
    let origin: URLOrigin
    let token: String
    let limits: MediaRelayLimits
    private(set) var resources: [String: MediaRelayResource] = [:]
    private var paths: [URL: String] = [:]
    private var byteCount = 0

    init(origin: URLOrigin, token: String, limits: MediaRelayLimits) {
        self.origin = origin
        self.token = token
        self.limits = limits
    }

    mutating func register(_ url: URL, kind: MediaRelayResourceKind, port: UInt16) throws -> URL {
        guard origin.matches(url), url.fragment == nil,
              !url.absoluteString.contains("{$"), !url.absoluteString.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw MediaRelayError.untrustedReference
        }
        if let path = paths[url] {
            guard resources[path]?.kind == kind else { throw MediaRelayError.unexpectedPlaylist }
            guard let local = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw MediaRelayError.invalidRequest }
            return local
        }
        let count = url.absoluteString.utf8.count
        guard count <= limits.URLBytes, resources.count < limits.registeredURLs,
              count <= limits.registeredURLBytes - byteCount else { throw MediaRelayError.resourceLimit }
        let sourceSuffix = url.pathExtension.lowercased()
        let safeSuffix = !sourceSuffix.isEmpty && sourceSuffix.count <= 12 && sourceSuffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? sourceSuffix : "mp4"
        let suffix = kind == .playlist ? "m3u8" : kind == .key ? "bin" : safeSuffix
        let path = "/\(token)/\(UUID().uuidString.lowercased()).\(suffix)"
        guard let local = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw MediaRelayError.invalidRequest }
        resources[path] = MediaRelayResource(url: url, kind: kind)
        paths[url] = path
        byteCount += count
        return local
    }

    mutating func rewrite(_ data: Data, baseURL: URL, port: UInt16) throws -> Data {
        // Work on a value snapshot: malformed or over-limit refreshes never
        // partially change the active resource table or reach AVFoundation.
        var next = self
        let rewritten = try HLSRelayPlaylist.rewrite(data, maximumBytes: limits.playlistBytes) { reference, kind in
            guard let url = URL(string: reference, relativeTo: baseURL)?.absoluteURL else { throw MediaRelayError.untrustedReference }
            return try next.register(url, kind: kind, port: port).absoluteString
        }
        self = next
        return rewritten
    }
}

enum HLSRelayPlaylist {
    /// Inspect bytes as well as headers: a .mp4/.ts label is not a guarantee that
    /// AVFoundation will treat received content as self-contained binary media.
    static func resemblesPlaylist(_ data: Data, contentType: String?) -> Bool {
        if let contentType, ["mpegurl", "m3u8"].contains(where: { contentType.lowercased().contains($0) }) { return true }
        let prefix = String(decoding: data.prefix(4096), as: UTF8.self)
        return prefix.range(of: "#EXTM3U", options: .caseInsensitive) != nil
    }

    private static let plainTags: Set<String> = [
        "#EXTM3U", "#EXTINF", "#EXT-X-VERSION", "#EXT-X-TARGETDURATION", "#EXT-X-MEDIA-SEQUENCE",
        "#EXT-X-DISCONTINUITY-SEQUENCE", "#EXT-X-ENDLIST", "#EXT-X-PLAYLIST-TYPE", "#EXT-X-I-FRAMES-ONLY",
        "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-START", "#EXT-X-DISCONTINUITY", "#EXT-X-PROGRAM-DATE-TIME",
        "#EXT-X-GAP", "#EXT-X-BYTERANGE", "#EXT-X-BITRATE", "#EXT-X-ALLOW-CACHE",
    ]
    private static let attributeTags: Set<String> = [
        "#EXT-X-STREAM-INF", "#EXT-X-I-FRAME-STREAM-INF", "#EXT-X-MEDIA", "#EXT-X-KEY", "#EXT-X-SESSION-KEY", "#EXT-X-MAP",
    ]
    static func rewrite(_ data: Data, maximumBytes: Int,
                        resolve: (String, MediaRelayResourceKind) throws -> String) throws -> Data {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8),
              !text.contains("\0"), text.components(separatedBy: .newlines).first == "#EXTM3U" else { throw MediaRelayError.invalidPlaylist }
        var nextKind = MediaRelayResourceKind.media
        var expectingVariant = false
        var output = ""
        var outputBytes = 0
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let rewritten: String
            if line.isEmpty { rewritten = line }
            else if !line.hasPrefix("#") {
                guard !line.hasPrefix(" "), !line.hasSuffix(" ") else { throw MediaRelayError.invalidPlaylist }
                rewritten = try resolve(line, nextKind)
                nextKind = .media
                expectingVariant = false
            } else if line.hasPrefix("#EXT") {
                let tag = String(line.prefix { $0 != ":" })
                if attributeTags.contains(tag) {
                    guard let colon = line.firstIndex(of: ":") else { throw MediaRelayError.invalidPlaylist }
                    var attributes = try parseAttributes(String(line[line.index(after: colon)...]))
                    for index in attributes.indices {
                        let key = attributes[index].key
                        if key == "URI" {
                            guard attributes[index].quoted, !attributes[index].value.isEmpty else { throw MediaRelayError.untrustedReference }
                            let kind: MediaRelayResourceKind = tag == "#EXT-X-KEY" || tag == "#EXT-X-SESSION-KEY" ? .key
                                : tag == "#EXT-X-MAP" ? .media : .playlist
                            attributes[index].value = try resolve(attributes[index].value, kind)
                        } else if key.contains("URI") || key.contains("URL") { throw MediaRelayError.untrustedReference }
                    }
                    if tag == "#EXT-X-STREAM-INF" { nextKind = .playlist; expectingVariant = true }
                    rewritten = tag + ":" + attributes.map(\.rendered).joined(separator: ",")
                } else if plainTags.contains(tag) {
                    guard !line.contains("URI="), !line.contains("URL=") else { throw MediaRelayError.untrustedReference }
                    rewritten = line
                } else {
                    // Unknown HLS extensions can teach AVFoundation new fetch
                    // routes. Fail closed rather than forwarding unseen syntax.
                    throw MediaRelayError.untrustedReference
                }
            } else { rewritten = line }
            let bytes = rewritten.utf8.count + 1
            guard bytes <= maximumBytes - outputBytes else { throw MediaRelayError.resourceLimit }
            outputBytes += bytes
            output += rewritten + "\n"
        }
        guard !expectingVariant else { throw MediaRelayError.invalidPlaylist }
        return Data(output.utf8)
    }

    private struct Attribute {
        let key: String
        var value: String
        let quoted: Bool
        var rendered: String { key + "=" + (quoted ? "\"\(value)\"" : value) }
    }
    private static func parseAttributes(_ text: String) throws -> [Attribute] {
        var fields: [String] = []
        var start = text.startIndex
        var quoted = false
        for index in text.indices {
            if text[index] == "\"" { quoted.toggle() }
            else if text[index] == ",", !quoted { fields.append(String(text[start..<index])); start = text.index(after: index) }
        }
        guard !quoted else { throw MediaRelayError.untrustedReference }
        fields.append(String(text[start...]))
        var seen: Set<String> = []
        return try fields.map { field in
            guard let equal = field.firstIndex(of: "=") else { throw MediaRelayError.untrustedReference }
            let key = String(field[..<equal])
            var value = String(field[field.index(after: equal)...])
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "-") }),
                  seen.insert(key).inserted, !value.isEmpty else { throw MediaRelayError.untrustedReference }
            let quoted = value.hasPrefix("\"")
            if quoted {
                guard value.count >= 2, value.hasSuffix("\"") else { throw MediaRelayError.untrustedReference }
                value = String(value.dropFirst().dropLast())
            }
            guard !value.contains("\""), !value.contains("\r"), !value.contains("\n") else { throw MediaRelayError.untrustedReference }
            return Attribute(key: key, value: value, quoted: quoted)
        }
    }
}
