import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let client: RustyDLNAClient
    let library: LibraryModel
    let downloads: DownloadManager
    let player: PlaybackModel

    @Published private(set) var isConfigured = false
    @Published var presentedError: UserFacingError?
    private var childObservers: Set<AnyCancellable> = []

    init() {
        let environment = ProcessInfo.processInfo.environment
        let settings = AppSettings()
        let client = RustyDLNAClient()
        self.settings = settings
        self.client = client
        library = LibraryModel(client: client)
        #if DEBUG
        if environment["RUSTYVIEW_TEST_SERVER"] != nil,
           let testNamespace = environment["RUSTYVIEW_TEST_NAMESPACE"],
           !testNamespace.isEmpty {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            let root = applicationSupport
                .appendingPathComponent("UITestDownloads", isDirectory: true)
                .appendingPathComponent(testNamespace, isDirectory: true)
            downloads = DownloadManager(
                store: DownloadManifestStore(rootDirectory: root),
                allowsCellularDownloads: settings.allowCellularDownloads,
                sessionIdentifier: "\(Bundle.main.bundleIdentifier ?? "com.example.rustyView").downloads.ui.\(testNamespace)"
            )
        } else {
            downloads = DownloadManager(allowsCellularDownloads: settings.allowCellularDownloads)
        }
        #else
        downloads = DownloadManager(allowsCellularDownloads: settings.allowCellularDownloads)
        #endif
        player = PlaybackModel(client: client)

        Publishers.MergeMany([
            settings.objectWillChange.eraseToAnyPublisher(),
            library.objectWillChange.eraseToAnyPublisher(),
            downloads.objectWillChange.eraseToAnyPublisher(),
            player.objectWillChange.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &childObservers)

        settings.$allowCellularDownloads
            .dropFirst()
            .removeDuplicates()
            .sink { [weak downloads] allowed in
                downloads?.setAllowsCellularDownloads(allowed)
            }
            .store(in: &childObservers)

        #if DEBUG
        if let address = environment["RUSTYVIEW_TEST_SERVER"],
           let username = environment["RUSTYVIEW_TEST_USERNAME"],
           let password = environment["RUSTYVIEW_TEST_PASSWORD"],
           let connection = try? ServerConnection(
               serverAddress: address,
               username: username,
               password: password
           ) {
            apply(connection)
            return
        }
        #endif

        if settings.hasSavedConnection, let connection = try? settings.connection() {
            apply(connection)
        }
    }

    func connect(serverAddress: String, username: String, password: String) async -> Bool {
        do {
            let effectivePassword = password.isEmpty && settings.hasSavedConnection
                ? settings.savedPassword
                : password
            let candidate = try ServerConnection(
                serverAddress: serverAddress,
                username: username,
                password: effectivePassword
            )
            let previous = client.connection
            client.configure(candidate)
            do {
                try await library.reload()
            } catch {
                client.configure(previous)
                downloads.configure(connection: previous, statusClient: client)
                isConfigured = previous != nil
                throw error
            }
            let saved = try settings.save(
                serverAddress: serverAddress,
                username: username,
                password: effectivePassword
            )
            apply(saved)
            return true
        } catch {
            presentedError = UserFacingError(error)
            return false
        }
    }

    func disconnect() {
        player.stop()
        library.clear()
        client.configure(nil)
        downloads.configure(connection: nil, statusClient: client)
        isConfigured = false
        do {
            try settings.forget()
        } catch {
            presentedError = UserFacingError(error)
        }
    }

    func report(_ error: Error) {
        presentedError = UserFacingError(error)
    }

    private func apply(_ connection: ServerConnection) {
        client.configure(connection)
        downloads.configure(connection: connection, statusClient: client)
        isConfigured = true
    }
}

struct UserFacingError: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(_ error: Error, title: String = "Something went wrong") {
        self.title = title
        message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
