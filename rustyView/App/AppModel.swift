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
    @Published var connectionError: UserFacingError?
    private var childObservers: Set<AnyCancellable> = []
    private var connectionEpoch = 0

    init(settings suppliedSettings: AppSettings? = nil, client suppliedClient: RustyDLNAClient? = nil,
         downloads suppliedDownloads: DownloadManager? = nil) {
        let environment = ProcessInfo.processInfo.environment
        let settings = suppliedSettings ?? AppSettings()
        let client = suppliedClient ?? RustyDLNAClient()
        self.settings = settings
        self.client = client
        library = LibraryModel(client: client)
        if let suppliedDownloads {
            downloads = suppliedDownloads
        } else {
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
        }
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
        connectionEpoch += 1
        connectionError = nil
        let epoch = connectionEpoch
        do {
            let effectivePassword = try settings.passwordForConnection(
                serverAddress: serverAddress, username: username, enteredPassword: password
            )
            let candidate = try ServerConnection(
                serverAddress: serverAddress,
                username: username,
                password: effectivePassword
            )
            let probe = client.connectionProbe()
            probe.configure(candidate)
            let page = try await probe.library(LibraryRequest())
            try Task.checkCancellation()
            guard epoch == connectionEpoch else { return false }
            let saved = try settings.save(
                serverAddress: serverAddress,
                username: username,
                password: effectivePassword
            )
            player.stop()
            apply(saved)
            library.replaceWithVerifiedPage(page)
            return true
        } catch {
            guard epoch == connectionEpoch, !Task.isCancelled else { return false }
            connectionError = UserFacingError(error)
            return false
        }
    }

    func disconnect() {
        connectionEpoch += 1
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
