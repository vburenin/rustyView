import Foundation

enum RecoveryAction: String, Codable, Hashable, Identifiable, Sendable {
    case retry, editConnection, watchDownloads, manageStorage, compatibilityHelp
    var id: String { rawValue }

    var title: String {
        switch self {
        case .retry: "Retry"
        case .editConnection: "Edit Connection"
        case .watchDownloads: "Watch Downloads"
        case .manageStorage: "Manage Storage"
        case .compatibilityHelp: "Compatibility Help"
        }
    }

    var systemImage: String {
        switch self {
        case .retry: "arrow.clockwise"
        case .editConnection: "server.rack"
        case .watchDownloads: "arrow.down.circle"
        case .manageStorage: "externaldrive"
        case .compatibilityHelp: "info.circle"
        }
    }
}

enum ConnectionField: String, Codable, Hashable, Sendable {
    case server, username, password
}

/// Presentation preserves the reason for a failure without storing transport
/// errors, request URLs, credentials, or filesystem paths in the queue.
struct UserFacingError: Error, Codable, Hashable, Identifiable, Sendable {
    enum Category: String, Codable, Hashable, Sendable {
        case authentication, offline, transient, transportSecurity, incompatibleServer
        case storage, credentialsUnavailable, credentialsMissing, notConfigured
        case missingMedia, invalidMedia, invalidInput, cancelled, other

        init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
        }
    }

    let id: UUID
    let category: Category
    let title: String
    let message: String
    let field: ConnectionField?

    init(category: Category, title: String? = nil, message: String? = nil, field: ConnectionField? = nil) {
        id = UUID()
        self.category = category
        self.title = title ?? Self.title(for: category)
        self.message = message ?? Self.message(for: category)
        self.field = field
    }

    init(_ error: Error, title: String? = nil) {
        if let existing = error as? Self {
            self = existing
            return
        }
        if let validation = error as? ConnectionValidationError {
            let field: ConnectionField
            switch validation {
            case .missingUsername: field = .username
            case .missingPassword: field = .password
            case .invalidURL, .insecureURL, .missingHost: field = .server
            }
            self.init(category: .invalidInput, title: title, message: validation.localizedDescription, field: field)
            return
        }
        if let keychain = error as? KeychainError {
            self.init(category: .credentialsUnavailable, title: title, message: keychain.localizedDescription)
            return
        }
        if let server = error as? RustyDLNAError {
            let category: Category
            switch server {
            case .authenticationFailed: category = .authentication
            case .notConfigured: category = .notConfigured
            case .untrustedURL: category = .transportSecurity
            case .schemaMismatch, .invalidResponse: category = .incompatibleServer
            case .http(let status, _, _):
                switch status {
                case 401, 403: category = .authentication
                case 404, 410: category = .missingMedia
                case 408, 429, 500...599: category = .transient
                default: category = .incompatibleServer
                }
            }
            self.init(category: category, title: title)
            return
        }
        if let storage = error as? DownloadStoreError {
            let category: Category
            switch storage {
            case .invalidManifest, .missingTemporaryFile, .conflictingDownload, .verificationTimedOut: category = .storage
            case .emptyDownload, .incompleteDownload, .incompatibleDownload, .invalidDownloadedFile: category = .invalidMedia
            }
            self.init(category: category, title: title, message: storage.localizedDescription)
            return
        }
        if let storage = error as? DownloadStorageFailure {
            let category: Category
            switch storage {
            case .invalidComponent: category = .invalidMedia
            case .staleAttempt: category = .cancelled
            case .missingComponent, .interrupted, .recoveryNotNeeded: category = .storage
            }
            self.init(category: category, title: title, message: storage.localizedDescription)
            return
        }
        if let queue = error as? DownloadQueueError {
            switch queue {
            case .missingOwnership: self.init(category: .credentialsMissing, title: title, message: queue.localizedDescription)
            case .invalidJournal: self.init(category: .storage, title: title, message: queue.localizedDescription)
            }
            return
        }
        if let library = error as? UserLibraryFailure {
            self.init(category: .storage, title: title, message: library.localizedDescription)
            return
        }
        if let subtitle = error as? SubtitleError {
            self.init(category: .invalidMedia, title: title ?? "Subtitles unavailable", message: subtitle.localizedDescription)
            return
        }
        if error is CancellationError {
            self.init(category: .cancelled, title: title)
            return
        }
        if error is DecodingError {
            self.init(category: .incompatibleServer, title: title)
            return
        }
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            let category: Category
            switch value.code {
            case NSURLErrorCancelled: category = .cancelled
            case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication: category = .authentication
            case NSURLErrorNotConnectedToInternet, NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed: category = .offline
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired: category = .transportSecurity
            case NSURLErrorBadServerResponse, NSURLErrorCannotParseResponse: category = .incompatibleServer
            case NSURLErrorFileDoesNotExist: category = .missingMedia
            case NSURLErrorCannotCreateFile, NSURLErrorCannotOpenFile, NSURLErrorCannotWriteToFile,
                 NSURLErrorCannotRemoveFile, NSURLErrorCannotMoveFile: category = .storage
            default: category = .transient
            }
            self.init(category: category, title: title)
        } else if value.domain == NSCocoaErrorDomain || value.domain == NSPOSIXErrorDomain {
            self.init(category: .storage, title: title,
                      message: value.domain == NSCocoaErrorDomain && value.code == NSFileWriteOutOfSpaceError
                        ? "There is not enough free space. Remove saved movies or free device storage, then retry." : nil)
        } else {
            self.init(category: .other, title: title)
        }
    }

    func recoveryActions(hasDownloads: Bool = false) -> [RecoveryAction] {
        let actions: [RecoveryAction]
        switch category {
        case .authentication, .credentialsMissing, .notConfigured, .invalidInput: actions = [.editConnection]
        case .credentialsUnavailable: actions = [.retry, .editConnection]
        case .offline: actions = [.retry, .editConnection]
        case .transportSecurity: actions = [.editConnection]
        case .incompatibleServer: actions = [.compatibilityHelp, .editConnection]
        case .storage: actions = [.manageStorage, .retry]
        case .missingMedia: actions = []
        case .transient, .invalidMedia, .other: actions = [.retry]
        case .cancelled: actions = []
        }
        if hasDownloads, [.offline, .authentication, .credentialsUnavailable, .credentialsMissing, .notConfigured].contains(category) {
            return [.watchDownloads] + actions
        }
        return actions
    }

    static func downloadResponse(_ response: URLResponse?) -> Self {
        guard let response = response as? HTTPURLResponse else { return Self(RustyDLNAError.invalidResponse) }
        if !(200..<300).contains(response.statusCode) {
            return Self(RustyDLNAError.http(status: response.statusCode, message: "", code: nil))
        }
        return Self(category: .invalidMedia)
    }

    private static func title(for category: Category) -> String {
        switch category {
        case .authentication: "Check your sign-in details"
        case .offline: "You are offline"
        case .transient: "The server could not respond"
        case .transportSecurity: "A secure connection could not be verified"
        case .incompatibleServer: "App and server compatibility"
        case .storage: "Saved files need attention"
        case .credentialsUnavailable: "Saved password unavailable"
        case .credentialsMissing: "Enter your password again"
        case .notConfigured: "Connect to your server"
        case .missingMedia: "This movie is unavailable"
        case .invalidMedia: "This copy could not be verified"
        case .invalidInput: "Check the connection details"
        case .cancelled: "Cancelled"
        case .other: "Something went wrong"
        }
    }

    private static func message(for category: Category) -> String {
        switch category {
        case .authentication: "The server rejected the user name or password. Update your connection details, then try again."
        case .offline: "Connect to Wi-Fi or cellular data to reach your server. Saved movies can still play on this device."
        case .transient: "The connection was interrupted or the server is busy. Try again in a moment."
        case .transportSecurity: "Check the HTTPS address and the server's certificate with your server administrator."
        case .incompatibleServer: "This app could not read the server response. Ask your server administrator to check the rustyDLNA version and update the app if needed."
        case .storage: "The saved files could not be read or updated. Check device storage, then retry. Your existing movies are preserved."
        case .credentialsUnavailable: "Your saved password could not be accessed. Unlock the device and retry, or enter the password again."
        case .credentialsMissing: "The saved password is missing. Enter it again to reconnect. Your downloaded movies remain on this device."
        case .notConfigured: "Enter the server address and sign-in details provided by your server administrator."
        case .missingMedia: "Refresh the library, or watch a saved copy from Downloads."
        case .invalidMedia: "The received file could not be verified for playback. Retry a compatible download."
        case .invalidInput: "Check the highlighted connection details."
        case .cancelled: "The operation was cancelled."
        case .other: "The operation could not be completed. Please try again."
        }
    }
}

extension UserFacingError: LocalizedError {
    var errorDescription: String? { message }
}
