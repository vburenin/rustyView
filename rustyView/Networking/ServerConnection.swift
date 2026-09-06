import Foundation

enum ConnectionValidationError: LocalizedError, Equatable {
    case invalidURL
    case insecureURL
    case missingHost
    case missingUsername
    case missingPassword

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid server address."
        case .insecureURL: "The server must use HTTPS."
        case .missingHost: "The server address needs a host name."
        case .missingUsername: "Enter the server user name."
        case .missingPassword: "Enter the server password."
        }
    }
}

struct ServerConnection: Equatable, Sendable {
    let baseURL: URL
    let username: String
    let password: String

    init(serverAddress: String, username: String, password: String) throws {
        let trimmedAddress = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedAddress) else {
            throw ConnectionValidationError.invalidURL
        }
        guard components.user == nil, components.password == nil else {
            throw ConnectionValidationError.invalidURL
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw ConnectionValidationError.invalidURL }
        guard let host = url.host, !host.isEmpty else { throw ConnectionValidationError.missingHost }

        #if DEBUG
        let permitsLocalHTTP = url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
        #else
        let permitsLocalHTTP = false
        #endif
        guard url.scheme == "https" || permitsLocalHTTP else {
            throw ConnectionValidationError.insecureURL
        }

        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else { throw ConnectionValidationError.missingUsername }
        self.baseURL = url
        self.username = trimmedUsername
        self.password = password
    }

    var origin: URLOrigin { URLOrigin(url: baseURL) }

    /// Deployment paths identify separate libraries even when authentication shares an origin.
    var serverIdentity: String { ServerIdentity.canonical(baseURL.absoluteString) }

    func owns(serverIdentity: String, accountUsername: String?) -> Bool {
        // Legacy records stay unassigned. Merely connecting is not evidence of ownership.
        accountUsername == username && ServerIdentity.canonical(serverIdentity) == self.serverIdentity
    }

    func resolve(serverPath: String) throws -> URL {
        guard let candidate = URL(string: serverPath, relativeTo: baseURL)?.absoluteURL,
              origin.matches(candidate) else {
            throw RustyDLNAError.untrustedURL
        }
        return candidate
    }

    func authorizationHeader() -> String {
        let bytes = Data("\(username):\(password)".utf8)
        return "Basic \(bytes.base64EncodedString())"
    }
}

enum ServerIdentity {
    static func canonical(_ address: String) -> String {
        guard var components = URLComponents(string: address),
              components.host != nil else { return address }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? address
    }
}

struct URLOrigin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init(url: URL) {
        scheme = url.scheme?.lowercased() ?? ""
        host = url.host?.lowercased() ?? ""
        port = url.port ?? (scheme == "https" ? 443 : 80)
    }

    func matches(_ url: URL) -> Bool {
        url.user == nil && url.password == nil && self == URLOrigin(url: url)
    }

    func matches(scheme candidateScheme: String?, host candidateHost: String, port candidatePort: Int) -> Bool {
        guard let candidateScheme else { return false }
        let normalizedScheme = candidateScheme.lowercased()
        let normalizedPort = candidatePort > 0
            ? candidatePort
            : (normalizedScheme == "https" ? 443 : 80)
        return scheme == normalizedScheme
            && host == candidateHost.lowercased()
            && port == normalizedPort
    }
}
