import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var serverAddress: String
    @Published var username: String
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

    var savedPassword: String {
        (try? secrets.read(account: passwordAccount)) ?? ""
    }

    var hasSavedConnection: Bool {
        !serverAddress.isEmpty && !username.isEmpty && !savedPassword.isEmpty
    }

    func connection(password: String? = nil) throws -> ServerConnection {
        try ServerConnection(
            serverAddress: serverAddress,
            username: username,
            password: password ?? savedPassword
        )
    }

    func passwordForConnection(serverAddress: String, username: String, enteredPassword: String) throws -> String {
        guard enteredPassword.isEmpty else { return enteredPassword }
        let candidate = try ServerConnection(serverAddress: serverAddress, username: username, password: "")
        guard let saved = try? connection(), candidate.origin == saved.origin,
              candidate.username == saved.username else { return enteredPassword }
        return saved.password
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
        return connection
    }

    func forget() throws {
        try secrets.remove(account: passwordAccount)
        defaults.removeObject(forKey: "serverAddress")
        defaults.removeObject(forKey: "username")
        serverAddress = ""
        username = ""
    }
}
