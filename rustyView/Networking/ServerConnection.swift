import Foundation

enum ConnectionValidationError: LocalizedError, Equatable {
    case invalidURL
    case insecureURL
    case missingHost
    case missingUsername

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid server address."
        case .insecureURL: "The server must use HTTPS."
        case .missingHost: "The server address needs a host name."
        case .missingUsername: "Enter the server user name."
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
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
        self == URLOrigin(url: url)
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
