import AVFoundation
import Foundation

enum ServerAuthenticationPolicy {
    static func credential(
        for challenge: URLAuthenticationChallenge,
        connection: ServerConnection
    ) -> URLCredential? {
        let protectionSpace = challenge.protectionSpace
        let method = protectionSpace.authenticationMethod
        let isPasswordChallenge = method == NSURLAuthenticationMethodHTTPBasic
            || method == NSURLAuthenticationMethodHTTPDigest
        guard isPasswordChallenge,
              challenge.previousFailureCount == 0,
              connection.origin.matches(
                  scheme: protectionSpace.protocol,
                  host: protectionSpace.host,
                  port: protectionSpace.port
              ) else {
            return nil
        }
        return URLCredential(
            user: connection.username,
            password: connection.password,
            persistence: .forSession
        )
    }
}

enum RustyDLNAError: LocalizedError, Equatable {
    case notConfigured
    case untrustedURL
    case invalidResponse
    case schemaMismatch(Int)
    case authenticationFailed
    case http(status: Int, message: String, code: String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Connect to your server first."
        case .untrustedURL: "The server returned a URL outside its trusted origin."
        case .invalidResponse: "The server returned an invalid response."
        case .schemaMismatch: "This app and server use incompatible API versions."
        case .authenticationFailed: "The server rejected the user name or password."
        case .http(_, let message, _): message
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case title = "title"
    case recent = "date_desc"

    var id: String { rawValue }
    var label: String { self == .title ? "Title" : "Recently added" }
}

enum LibraryViewMode: String, CaseIterable, Identifiable, Sendable {
    case library
    case folders

    var id: String { rawValue }
    var label: String { self == .library ? "All Movies" : "Folders" }
}

struct LibraryRequest: Equatable, Sendable {
    var view = LibraryViewMode.library
    var folderID: String?
    var query = ""
    var sort = LibrarySort.title
    var offset = 0
    var limit = 60
    var generation: Int?
}

final class AuthenticatedSessionDelegate: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var currentConnection: ServerConnection?

    func update(connection: ServerConnection?) {
        lock.lock()
        currentConnection = connection
        lock.unlock()
    }

    private func connection() -> ServerConnection? {
        lock.lock()
        defer { lock.unlock() }
        return currentConnection
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let connection = connection() else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let credential = ServerAuthenticationPolicy.credential(
            for: challenge,
            connection: connection
        ) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, credential)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let connection = connection(),
              let url = request.url,
              connection.origin.matches(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

final class AuthenticatedAssetResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    private let connection: ServerConnection

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForResponseTo authenticationChallenge: URLAuthenticationChallenge
    ) -> Bool {
        guard let credential = ServerAuthenticationPolicy.credential(
            for: authenticationChallenge,
            connection: connection
        ) else {
            return false
        }
        authenticationChallenge.sender?.use(credential, for: authenticationChallenge)
        return true
    }
}

final class AuthenticatedMediaAsset {
    let asset: AVURLAsset
    private let resourceLoaderDelegate: AuthenticatedAssetResourceLoaderDelegate

    init(url: URL, connection: ServerConnection) {
        asset = AVURLAsset(url: url)
        resourceLoaderDelegate = AuthenticatedAssetResourceLoaderDelegate(connection: connection)
        asset.resourceLoader.setDelegate(
            resourceLoaderDelegate,
            queue: DispatchQueue(label: "com.example.rustyView.asset-authentication")
        )
    }
}

final class RustyDLNAClient {
    static let schemaVersion = 2

    private let delegate: AuthenticatedSessionDelegate
    private let session: URLSession
    private(set) var connection: ServerConnection?

    init(configuration: URLSessionConfiguration = .default) {
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        delegate = AuthenticatedSessionDelegate()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func configure(_ connection: ServerConnection?) {
        self.connection = connection
        delegate.update(connection: connection)
    }

    func connectionProbe() -> RustyDLNAClient {
        RustyDLNAClient(configuration: session.configuration)
    }

    func library(_ request: LibraryRequest) async throws -> LibraryPage {
        var components = URLComponents()
        components.path = "/api/web/library"
        var items = [
            URLQueryItem(name: "view", value: request.view.rawValue),
            URLQueryItem(name: "kind", value: request.view == .folders ? "all" : "video"),
            URLQueryItem(name: "q", value: request.query),
            URLQueryItem(name: "sort", value: request.sort.rawValue),
            URLQueryItem(name: "offset", value: String(request.offset)),
            URLQueryItem(name: "limit", value: String(request.limit)),
        ]
        if request.view == .folders, let folderID = request.folderID {
            items.append(URLQueryItem(name: "folder", value: folderID))
        }
        if let generation = request.generation { items.append(URLQueryItem(name: "generation", value: String(generation))) }
        components.queryItems = items
        return try await decoded(pathAndQuery: components.string ?? components.path)
    }

    func item(id: String) async throws -> MediaItem {
        let response: ItemResponse = try await decoded(pathAndQuery: "/api/web/item/\(encodedPathComponent(id))")
        return response.item
    }

    func transcodeStatus(mediaID: String, compatiblePath: String) async throws -> TranscodeStatus {
        try await transcodeRequest(mediaID: mediaID, compatiblePath: compatiblePath)
    }

    @discardableResult
    func cancelTranscode(mediaID: String, compatiblePath: String) async throws -> TranscodeStatus {
        try await transcodeRequest(
            mediaID: mediaID,
            compatiblePath: compatiblePath,
            method: "DELETE"
        )
    }

    func data(serverPath: String) async throws -> Data {
        let request = try authorizedRequest(serverPath: serverPath)
        return try await data(for: request)
    }

    func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    func resolvedURL(serverPath: String) throws -> URL {
        guard let connection else { throw RustyDLNAError.notConfigured }
        return try connection.resolve(serverPath: serverPath)
    }

    func authorizedRequest(serverPath: String) throws -> URLRequest {
        guard let connection else { throw RustyDLNAError.notConfigured }
        let url = try connection.resolve(serverPath: serverPath)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(connection.authorizationHeader(), forHTTPHeaderField: "Authorization")
        return request
    }

    func asset(serverPath: String) throws -> AuthenticatedMediaAsset {
        guard let connection else { throw RustyDLNAError.notConfigured }
        let url = try connection.resolve(serverPath: serverPath)
        return AuthenticatedMediaAsset(url: url, connection: connection)
    }

    func compatiblePath(
        for item: MediaItem,
        delivery: String = "hls",
        quality: String = "auto",
        audioIndex: Int? = nil,
        startSeconds: Int = 0,
        forceVideoTranscode: Bool = false
    ) -> String {
        // A non-Auto quality is a resolution/bitrate constraint. Copying the
        // source cannot satisfy that constraint, so it must use a video encode.
        let video = forceVideoTranscode || quality != "auto"
            ? "transcode"
            : PlaybackCompatibility.videoMode(for: item)
        var components = URLComponents(string: item.fallbackURL) ?? URLComponents()
        if delivery == "hls" {
            components.path = components.path.replacingOccurrences(of: ".mp4", with: ".m3u8")
        }
        let requestID = UInt64.random(in: 1...UInt64.max)
        var queryItems = [
            URLQueryItem(name: "mode", value: "compatible"),
            URLQueryItem(name: "audio", value: String(audioIndex ?? item.defaultAudioIndex)),
            URLQueryItem(name: "start", value: String(max(0, startSeconds))),
            URLQueryItem(name: "quality", value: quality),
            URLQueryItem(name: "video_mode", value: video),
            URLQueryItem(name: "audio_mode", value: "transcode"),
            URLQueryItem(name: "reason", value: "native_ios"),
            URLQueryItem(name: "request", value: String(requestID)),
            URLQueryItem(name: "session", value: String(requestID)),
        ]
        if video == "transcode" { queryItems.append(URLQueryItem(name: "video_output", value: "h264_sdr")) }
        if delivery != "mp4" { queryItems.append(URLQueryItem(name: "delivery", value: delivery)) }
        components.queryItems = queryItems
        return components.string ?? item.fallbackURL
    }

    private func decoded<T: Decodable>(pathAndQuery: String) async throws -> T {
        let request = try authorizedRequest(serverPath: pathAndQuery)
        return try await decoded(request: request)
    }

    private func decoded<T: Decodable>(request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let version = try JSONDecoder().decode(SchemaEnvelope.self, from: data).schemaVersion
        if version != Self.schemaVersion {
            throw RustyDLNAError.schemaMismatch(version)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func transcodeRequest<T: Decodable>(
        mediaID: String,
        compatiblePath: String,
        method: String = "GET"
    ) async throws -> T {
        guard let source = URLComponents(string: compatiblePath) else {
            throw RustyDLNAError.invalidResponse
        }
        guard let requestID = source.queryItems?.first(where: { $0.name == "request" })?.value,
              UInt64(requestID) != nil,
              let sessionID = source.queryItems?.first(where: { $0.name == "session" })?.value,
              UInt64(sessionID) != nil else {
            throw RustyDLNAError.invalidResponse
        }
        var status = URLComponents()
        status.path = "/api/web/transcode/\(encodedPathComponent(mediaID))"
        status.queryItems = [
            URLQueryItem(name: "request", value: requestID),
            URLQueryItem(name: "session", value: sessionID),
        ]
        var request = try authorizedRequest(serverPath: status.string ?? status.path)
        request.httpMethod = method
        return try await decoded(request: request)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw RustyDLNAError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw RustyDLNAError.authenticationFailed }
            let body = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data).error
            throw RustyDLNAError.http(
                status: http.statusCode,
                message: body?.message ?? "The server request failed (HTTP \(http.statusCode)).",
                code: body?.code
            )
        }
    }

    private func encodedPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    deinit { session.invalidateAndCancel() }
}

private struct SchemaEnvelope: Decodable {
    let schemaVersion: Int
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version" }
}

enum PlaybackCompatibility {
    static func videoMode(for item: MediaItem) -> String {
        if item.videoRepairRequired { return "repair" }
        let codecs = Set(item.videoCodec.lowercased().split(separator: ",").map(String.init))
        if !codecs.isEmpty && codecs.allSatisfy({ $0 == "h264" || $0 == "hevc" }) {
            return "copy"
        }
        return "transcode"
    }
}
