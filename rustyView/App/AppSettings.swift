import Foundation

enum CredentialAvailability: Equatable, Sendable {
    case unchecked, missing, available, unavailable
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var serverAddress: String
    @Published var username: String
    @Published private(set) var credentialAvailability: CredentialAvailability = .unchecked
    @Published var allowCellularDownloads: Bool {
        didSet { defaults.set(allowCellularDownloads, forKey: Self.allowCellularDownloadsKey) }
    }

    private let defaults: UserDefaults
    private let secrets: SecretStoring
    private let passwordAccount = "server-password"
    private static let allowCellularDownloadsKey = "allowCellularDownloads"

    init(defaults: UserDefaults = .standard, secrets: SecretStoring = KeychainStore()) {
        self.defaults = defaults
        self.secrets = secrets
        serverAddress = defaults.string(forKey: "serverAddress") ?? ""
        username = defaults.string(forKey: "username") ?? ""
        allowCellularDownloads = defaults.object(forKey: Self.allowCellularDownloadsKey) == nil
            ? true
            : defaults.bool(forKey: Self.allowCellularDownloadsKey)
    }

    var hasSavedConnection: Bool {
        !serverAddress.isEmpty && !username.isEmpty && credentialAvailability == .available
    }

    /// Missing credentials and an unavailable Keychain are different startup
    /// states. Reading a SwiftUI property never performs a Keychain operation.
    func savedConnection() throws -> ServerConnection? {
        guard !serverAddress.isEmpty, !username.isEmpty else {
            credentialAvailability = .missing
            return nil
        }
        guard let password = try readPassword() else { return nil }
        return try ServerConnection(serverAddress: serverAddress, username: username, password: password)
    }

    func connection(password: String? = nil) throws -> ServerConnection {
        if let password { return try ServerConnection(serverAddress: serverAddress, username: username, password: password) }
        guard let saved = try savedConnection() else {
            throw UserFacingError(category: .credentialsMissing, field: .password)
        }
        return saved
    }

    func canReuseSavedPassword(serverAddress: String, username: String) -> Bool {
        credentialAvailability == .available && isSavedAccount(serverAddress: serverAddress, username: username)
    }

    func isSavedAccount(serverAddress: String, username: String) -> Bool {
        guard let candidate = try? ServerConnection(serverAddress: serverAddress, username: username, password: ""),
              let saved = try? ServerConnection(serverAddress: self.serverAddress, username: self.username, password: "") else { return false }
        return candidate.origin == saved.origin && candidate.username == saved.username
    }

    private func readPassword() throws -> String? {
        do {
            guard let saved = try secrets.read(account: passwordAccount), !saved.isEmpty else {
                credentialAvailability = .missing
                return nil
            }
            credentialAvailability = .available
            return saved
        } catch {
            credentialAvailability = .unavailable
            throw error
        }
    }

    func passwordForConnection(serverAddress: String, username: String, enteredPassword: String) throws -> String {
        guard enteredPassword.isEmpty else { return enteredPassword }
        _ = try ServerConnection(serverAddress: serverAddress, username: username, password: "")
        guard isSavedAccount(serverAddress: serverAddress, username: username) else { return enteredPassword }
        return try readPassword() ?? ""
    }

    func save(serverAddress: String, username: String, password: String) throws -> ServerConnection {
        let connection = try ServerConnection(
            serverAddress: serverAddress,
            username: username,
            password: password
        )
        try secrets.write(password, account: passwordAccount)
        self.serverAddress = connection.baseURL.absoluteString
        self.username = connection.username
        defaults.set(self.serverAddress, forKey: "serverAddress")
        defaults.set(self.username, forKey: "username")
        credentialAvailability = password.isEmpty ? .missing : .available
        return connection
    }

    func forget() throws {
        try secrets.remove(account: passwordAccount)
        defaults.removeObject(forKey: "serverAddress")
        defaults.removeObject(forKey: "username")
        serverAddress = ""
        username = ""
        credentialAvailability = .missing
    }
}
