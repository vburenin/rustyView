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
            persistence: .none
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
    private let connection: ServerConnection
    private let lock = NSLock()
    private var failure: RustyDLNAError?

    var rejection: RustyDLNAError? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    private func reject(_ error: RustyDLNAError) {
        lock.lock()
        failure = error
        lock.unlock()
    }

    init(connection: ServerConnection) { self.connection = connection }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let isTrust = space.authenticationMethod == NSURLAuthenticationMethodServerTrust
        guard connection.origin.matches(scheme: space.protocol ?? (isTrust ? "https" : nil),
                                        host: space.host, port: space.port) else {
            reject(.untrustedURL)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if let credential = ServerAuthenticationPolicy.credential(for: challenge, connection: connection) {
            completionHandler(.useCredential, credential)
        } else if space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
                    || space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest {
            reject(.authenticationFailed)
            completionHandler(.cancelAuthenticationChallenge, nil)
        } else {
            // Preserve normal certificate validation for the owned HTTPS origin.
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              connection.origin.matches(url) else {
            reject(.untrustedURL)
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

final class RustyDLNAClient {
    static let schemaVersion = 2

    private let session: URLSession
    private let connectionLock = NSLock()
    private var currentConnection: ServerConnection?
    var connection: ServerConnection? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return currentConnection
    }

    init(configuration: URLSessionConfiguration = .default) {
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }

    func configure(_ connection: ServerConnection?) {
        connectionLock.lock()
        currentConnection = connection
        connectionLock.unlock()
    }

    func connectionProbe() -> RustyDLNAClient {
        RustyDLNAClient(configuration: session.configuration)
    }

    /// Capture credentials and transport configuration before asynchronous work
    /// starts. Later connection edits must not retarget an existing viewer.
    func ownedConnection() throws -> RustyDLNAClient {
        guard let connection else { throw RustyDLNAError.notConfigured }
        let owned = connectionProbe()
        owned.configure(connection)
        return owned
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
        let owner = try owner(for: request)
        return try await data(for: request, owner: owner)
    }

    /// A queued caller captures its account before waiting for admission. Reuse
    /// this client's session while keeping that request's authentication fixed.
    func data(for request: URLRequest, owner: ServerConnection) async throws -> Data {
        guard let url = request.url, owner.origin.matches(url) else { throw RustyDLNAError.untrustedURL }
        if let authorization = request.value(forHTTPHeaderField: "Authorization"),
           authorization != owner.authorizationHeader() {
            throw URLError(.cancelled)
        }
        let delegate = AuthenticatedSessionDelegate(connection: owner)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: delegate)
        } catch {
            throw delegate.rejection ?? error
        }
        if let rejection = delegate.rejection { throw rejection }
        try validate(response: response, data: data, owner: owner)
        return data
    }

    func resolvedURL(serverPath: String) throws -> URL {
        guard let connection else { throw RustyDLNAError.notConfigured }
        return try connection.resolve(serverPath: serverPath)
    }

    /// Inspect the same completed rendition without opening another media body.
    /// Growing output deliberately has no final length; missing/encoded/error
    /// responses cannot supply a transfer total.
    func completedDownloadByteCount(serverPath: String) async throws -> Int64? {
        var request = try authorizedRequest(serverPath: serverPath)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        request.setValue("video/mp4, application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let owner = try owner(for: request)
        let delegate = AuthenticatedSessionDelegate(connection: owner)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: delegate) }
        catch { throw delegate.rejection ?? error }
        if let rejection = delegate.rejection { throw rejection }
        try validate(response: response, data: data, owner: owner)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == request.url,
              ["video/mp4", "application/mp4", "application/octet-stream"].contains(response.mimeType?.lowercased() ?? ""),
              response.value(forHTTPHeaderField: "Transfer-Encoding") == nil,
              response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) != false,
              let value = response.value(forHTTPHeaderField: "Content-Length")?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let count = Int64(value), count > 0 else { return nil }
        return count
    }

    func authorizedRequest(serverPath: String) throws -> URLRequest {
        guard let connection else { throw RustyDLNAError.notConfigured }
        let url = try connection.resolve(serverPath: serverPath)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(connection.authorizationHeader(), forHTTPHeaderField: "Authorization")
        return request
    }

    func asset(serverPath: String) async throws -> AuthenticatedMediaAsset {
        guard let connection else { throw RustyDLNAError.notConfigured }
        let url = try connection.resolve(serverPath: serverPath)
        return try await AuthenticatedMediaAsset(url: url, connection: connection)
    }

    func compatiblePath(
        for item: MediaItem,
        delivery: String = "hls",
        quality: String = "auto",
        audioIndex: Int? = nil,
        startSeconds: Int = 0,
        forceVideoTranscode: Bool = false,
        preparedIdentity: PreparedPlaybackIdentity? = nil
    ) -> String {
        // A non-Auto quality is a resolution/bitrate constraint. Copying the
        // source cannot satisfy that constraint, so it must use a video encode.
        let output = CompatibleOutputPlan(item: item, quality: quality, audioIndex: audioIndex,
                                          forceVideoTranscode: forceVideoTranscode)
        let video = output.videoMode
        var components = URLComponents(string: item.fallbackURL) ?? URLComponents()
        if delivery == "hls" {
            components.path = components.path.replacingOccurrences(of: ".mp4", with: ".m3u8")
        }
        let requestID = UInt64.random(in: 1...UInt64.max)
        var queryItems = [
            URLQueryItem(name: "mode", value: "compatible"),
            URLQueryItem(name: "audio", value: String(output.audioIndex)),
            URLQueryItem(name: "start", value: String(max(0, startSeconds))),
            URLQueryItem(name: "quality", value: quality),
            URLQueryItem(name: "video_mode", value: video),
            URLQueryItem(name: "audio_mode", value: "transcode"),
            URLQueryItem(name: "reason", value: "native_ios"),
            URLQueryItem(name: "request", value: String(preparedIdentity?.generation ?? requestID)),
            URLQueryItem(name: "session", value: String(preparedIdentity?.session ?? requestID)),
        ]
        if let videoOutput = output.videoOutput { queryItems.append(URLQueryItem(name: "video_output", value: videoOutput)) }
        if delivery != "mp4" { queryItems.append(URLQueryItem(name: "delivery", value: delivery)) }
        components.queryItems = queryItems
        return components.string ?? item.fallbackURL
    }

    private func decoded<T: Decodable>(pathAndQuery: String) async throws -> T {
        let request = try authorizedRequest(serverPath: pathAndQuery)
        return try await decoded(request: request)
    }

    private func decoded<T: Decodable>(request: URLRequest) async throws -> T {
        let data = try await data(for: request)
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

    private func owner(for request: URLRequest) throws -> ServerConnection {
        guard let connection else { throw RustyDLNAError.notConfigured }
        guard let url = request.url, connection.origin.matches(url) else { throw RustyDLNAError.untrustedURL }
        // Artwork can wait for a request slot while the account changes. Never
        // attach that old request to the new account's authentication delegate.
        if let authorization = request.value(forHTTPHeaderField: "Authorization"),
           authorization != connection.authorizationHeader() {
            throw URLError(.cancelled)
        }
        return connection
    }

    private func validate(response: URLResponse, data: Data, owner: ServerConnection) throws {
        guard let url = response.url, owner.origin.matches(url) else { throw RustyDLNAError.untrustedURL }
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
