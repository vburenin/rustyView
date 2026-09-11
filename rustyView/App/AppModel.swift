import Combine
import Foundation

enum AppTab: Hashable { case library, saved, downloads, settings }

@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let client: RustyDLNAClient
    let library: LibraryModel
    let downloads: DownloadManager
    let player: PlaybackModel
    let movieCache: MovieMetadataCache
    let userLibrary: UserLibraryStore
    let playbackPreferences: PlaybackPreferences
    let downloadPreferences: DownloadPreferences

    @Published private(set) var isConfigured = false
    @Published var selectedTab = AppTab.library
    @Published var showingConnection = false
    @Published var showingCompatibilityHelp = false
    @Published var presentedError: UserFacingError?
    @Published var connectionError: UserFacingError?
    private var childObservers: Set<AnyCancellable> = []
    private var connectionEpoch = 0
    private var savedPlaybackEpoch = 0

    init(settings suppliedSettings: AppSettings? = nil, client suppliedClient: RustyDLNAClient? = nil,
         downloads suppliedDownloads: DownloadManager? = nil,
         movieCache suppliedMovieCache: MovieMetadataCache? = nil,
         userLibrary suppliedUserLibrary: UserLibraryStore? = nil,
         playbackPreferences suppliedPreferences: PlaybackPreferences? = nil) {
        let environment = ProcessInfo.processInfo.environment
        var defaults = UserDefaults.standard
        var secrets = KeychainStore()
        #if DEBUG
        if let namespace = environment["RUSTYVIEW_TEST_NAMESPACE"], !namespace.isEmpty {
            let service = "\(Bundle.main.bundleIdentifier ?? "com.example.rustyView").ui.\(namespace)"
            defaults = UserDefaults(suiteName: service) ?? .standard
            secrets = KeychainStore(service: service)
        }
        #endif
        let settings = suppliedSettings ?? AppSettings(defaults: defaults, secrets: secrets)
        let client = suppliedClient ?? RustyDLNAClient()
        self.settings = settings
        self.client = client
        var metadataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MovieMetadata", isDirectory: true)
        var userLibraryDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UserLibrary", isDirectory: true)
        var uiTestStorageRoot: URL?
        #if DEBUG && targetEnvironment(simulator)
        // UI tests may exercise real disk failures in a runner-owned temporary
        // directory. The override is unavailable on devices and release builds.
        if let namespace = environment["RUSTYVIEW_TEST_NAMESPACE"],
           let identifier = UUID(uuidString: namespace),
           let path = environment["RUSTYVIEW_TEST_STORAGE_ROOT"], path.hasPrefix("/") {
            uiTestStorageRoot = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                .appendingPathComponent(identifier.uuidString.lowercased(), isDirectory: true)
        }
        #endif
        #if DEBUG
        if let namespace = environment["RUSTYVIEW_TEST_NAMESPACE"], !namespace.isEmpty {
            metadataDirectory = metadataDirectory.appendingPathComponent(namespace, isDirectory: true)
            userLibraryDirectory = userLibraryDirectory.appendingPathComponent(namespace, isDirectory: true)
        }
        #endif
        if let uiTestStorageRoot {
            metadataDirectory = uiTestStorageRoot.appendingPathComponent("MovieMetadata", isDirectory: true)
            userLibraryDirectory = uiTestStorageRoot.appendingPathComponent("UserLibrary", isDirectory: true)
        }
        movieCache = suppliedMovieCache ?? MovieMetadataCache(directory: metadataDirectory)
        userLibrary = suppliedUserLibrary ?? UserLibraryStore(directory: userLibraryDirectory,
            legacyProgressStore: PlaybackProgressStore(defaults: defaults))
        playbackPreferences = suppliedPreferences ?? PlaybackPreferences(defaults: defaults)
        downloadPreferences = DownloadPreferences(defaults: defaults)
        library = LibraryModel(client: client, defaults: defaults)
        if let suppliedDownloads {
            downloads = suppliedDownloads
        } else {
        #if DEBUG
        if let testNamespace = environment["RUSTYVIEW_TEST_NAMESPACE"],
           !testNamespace.isEmpty {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            let root = uiTestStorageRoot?.appendingPathComponent("Downloads", isDirectory: true) ?? applicationSupport
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
        // OS-owned transfers must reconnect even when Keychain is unavailable
        // or the person has intentionally forgotten the connection.
        downloads.startBackgroundOwnership()
        player = PlaybackModel(client: client, activityStore: userLibrary, preferences: playbackPreferences)

        Publishers.MergeMany([
            settings.objectWillChange.eraseToAnyPublisher(),
            library.objectWillChange.eraseToAnyPublisher(),
            downloads.objectWillChange.eraseToAnyPublisher(),
            player.objectWillChange.eraseToAnyPublisher(),
            movieCache.objectWillChange.eraseToAnyPublisher(),
            userLibrary.objectWillChange.eraseToAnyPublisher(),
            playbackPreferences.objectWillChange.eraseToAnyPublisher(),
            downloadPreferences.objectWillChange.eraseToAnyPublisher(),
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

        Task { [weak self] in
            guard let self else { return }
            await userLibrary.waitUntilRestored()
            await movieCache.waitUntilRestored()
            await downloads.waitUntilRestored()
            for entry in userLibrary.entries.values where entry.movie == nil {
                let saved = downloads.completed.filter { self.key(for: $0) == entry.key }.max { $0.completedAt < $1.completedAt }
                if let movie = saved?.movieMetadata ?? movieCache.movie(for: entry.key) {
                    userLibrary.upsertMetadata(movie, for: entry.key)
                }
            }
        }

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

        do {
            if let connection = try settings.savedConnection() { apply(connection) }
            else if !settings.serverAddress.isEmpty && !settings.username.isEmpty {
                connectionError = UserFacingError(category: .credentialsMissing, field: .password)
            }
        } catch {
            connectionError = UserFacingError(error)
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
            guard !effectivePassword.isEmpty else { throw ConnectionValidationError.missingPassword }
            let candidate = try ServerConnection(
                serverAddress: serverAddress,
                username: username,
                password: effectivePassword
            )
            let probe = client.connectionProbe()
            probe.configure(candidate)
            let page = try await probe.library(library.initialRequest(for: candidate))
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
        do {
            try settings.forget()
            player.stop()
            library.clear()
            client.configure(nil)
            downloads.configure(connection: nil, statusClient: client)
            isConfigured = false
        } catch {
            presentedError = UserFacingError(error)
        }
    }

    func cancelConnectionAttempt() {
        connectionEpoch += 1
        connectionError = nil
    }

    func report(_ error: Error) {
        presentedError = UserFacingError(error)
    }

    func playOffline(_ record: DownloadRecord, start: PlaybackStart = .resume) {
        savedPlaybackEpoch += 1
        let captionSources = (record.localCaptions ?? []).compactMap { caption -> LocalCaptionSource? in
            guard let url = downloads.captionURL(for: record, caption: caption) else { return nil }
            return LocalCaptionSource(caption: caption, url: url)
        }
        player.play(.offline(record: record, url: downloads.localURL(for: record),
                             captionSources: captionSources, start: start))
    }

    func playSaved(_ key: MovieLibraryKey, start: PlaybackStart = .resume) async throws {
        savedPlaybackEpoch += 1
        let epoch = savedPlaybackEpoch
        let playerIdentity = player.requestIdentity
        await userLibrary.waitUntilRestored()
        await downloads.waitUntilRestored()
        try Task.checkCancellation()
        guard epoch == savedPlaybackEpoch, player.requestIdentity == playerIdentity else { return }
        if let record = bestReadyRecord(for: key) {
            playOffline(record, start: start)
            return
        }
        guard let connection = client.connection, owns(key) else { throw RustyDLNAError.notConfigured }
        let requestClient = client.connectionProbe()
        requestClient.configure(connection)
        let profiles: [QualityProfile]
        if let capabilities = library.capabilities { profiles = capabilities.qualityProfiles }
        else { profiles = try await requestClient.library(LibraryRequest(limit: 1)).capabilities.qualityProfiles }
        try Task.checkCancellation()
        guard epoch == savedPlaybackEpoch, player.requestIdentity == playerIdentity,
              client.connection == connection else { return }
        let item = try await requestClient.item(id: key.mediaID)
        try Task.checkCancellation()
        guard epoch == savedPlaybackEpoch, player.requestIdentity == playerIdentity,
              client.connection == connection else { return }
        cacheMovie(item, connection: connection)
        let quality = playbackPreferences.quality(in: profiles)
        player.play(.online(item: item, connection: connection, start: start,
                            quality: quality.qualityID, qualityNotice: quality.notice, qualityProfiles: profiles))
    }

    func cachedMovie(mediaID: String) -> MovieMetadata? {
        guard let connection = client.connection else { return nil }
        return movieCache.movie(for: MovieLibraryKey(connection: connection, mediaID: mediaID))
    }

    func cacheMovie(_ item: MediaItem, connection: ServerConnection) {
        movieCache.store(MovieMetadata(item: item), connection: connection)
        userLibrary.upsertMetadata(MovieMetadata(item: item), for: MovieLibraryKey(connection: connection, mediaID: item.id))
    }

    func key(for record: DownloadRecord) -> MovieLibraryKey {
        MovieLibraryKey(serverIdentity: record.serverOrigin, accountUsername: record.accountUsername, mediaID: record.mediaID)
    }

    func bestReadyRecord(for key: MovieLibraryKey) -> DownloadRecord? {
        downloads.completed.filter { $0.isReadyToWatch && self.key(for: $0) == key }
            .sorted {
                if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
                return $0.id.uuidString < $1.id.uuidString
            }.first
    }

    func owns(_ key: MovieLibraryKey) -> Bool {
        client.connection?.owns(serverIdentity: key.serverIdentity, accountUsername: key.accountUsername) == true
    }

    private func apply(_ connection: ServerConnection) {
        client.configure(connection)
        library.configureConnection(connection)
        downloads.configure(connection: connection, statusClient: client)
        isConfigured = true
    }
}
