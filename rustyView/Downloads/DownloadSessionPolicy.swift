import Foundation

enum DownloadSessionPolicy: String, CaseIterable, Sendable {
    case anyNetwork = "any", wifi

    static func selected(allowsCellular: Bool) -> Self { allowsCellular ? .anyNetwork : .wifi }

    func configuration(identifier: String, template: URLSessionConfiguration? = nil) -> URLSessionConfiguration {
        let configuration = template?.copy() as? URLSessionConfiguration
            ?? URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = self == .anyNetwork
        configuration.allowsExpensiveNetworkAccess = self == .anyNetwork
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = true
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 2
        return configuration
    }
}

enum DownloadOriginPolicy {
    static func permits(_ url: URL?, metadata: DownloadTaskMetadata) -> Bool {
        guard let url, let owner = URL(string: metadata.serverOrigin) else { return false }
        return URLOrigin(url: owner).matches(url)
    }

    static func permits(_ protectionSpace: URLProtectionSpace, metadata: DownloadTaskMetadata) -> Bool {
        guard let owner = URL(string: metadata.serverOrigin) else { return false }
        return URLOrigin(url: owner).matches(scheme: protectionSpace.protocol, host: protectionSpace.host,
                                             port: protectionSpace.port)
    }
}
