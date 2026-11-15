import Combine
import Foundation

enum AppTab: Hashable { case library, search, saved, downloads, settings }

#if os(iOS)
typealias AppDownloadManager = DownloadManager
#else
/// Apple TV streams only, so its target omits the offline transfer runtime.
enum AppDownloadManager {}
#endif

enum AppStorageLocation {
    /// tvOS gives apps only purgeable local storage: Application Support cannot
    /// be created on Apple TV hardware, so the small library indexes use Caches.
    static var persistentRoot: URL {
        #if os(tvOS)
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
    }
}

@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let client: RustyDLNAClient
    let library: LibraryModel
    #if os(iOS)
    /// Apple TV streams only; offline copies are an iPhone and iPad feature.
    let downloads: DownloadManager
    #endif
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
    @Published private(set) var subtitleChecks: Set<UUID> = []
    @Published private(set) var subtitleDownloadNotices: [UUID: String] = [:]
    private var subtitleCheckTasks: [UUID: Task<Void, Never>] = [:]
    private var subtitleCheckIDs: [UUID: UUID] = [:]
    private var childObservers: Set<AnyCancellable> = []
    private var connectionEpoch = 0
    private var savedPlaybackEpoch = 0

    init(settings suppliedSettings: AppSettings? = nil, client suppliedClient: RustyDLNAClient? = nil,
         downloads suppliedDownloads: AppDownloadManager? = nil,
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
        var metadataDirectory = AppStorageLocation.persistentRoot
            .appendingPathComponent("MovieMetadata", isDirectory: true)
        var userLibraryDirectory = AppStorageLocation.persistentRoot
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
        #if os(iOS)
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
        #endif
        player = PlaybackModel(client: client, activityStore: userLibrary, preferences: playbackPreferences)

        var children: [AnyPublisher<Void, Never>] = [
            settings.objectWillChange.eraseToAnyPublisher(),
            library.objectWillChange.eraseToAnyPublisher(),
            player.objectWillChange.eraseToAnyPublisher(),
            movieCache.objectWillChange.eraseToAnyPublisher(),
            userLibrary.objectWillChange.eraseToAnyPublisher(),
            playbackPreferences.objectWillChange.eraseToAnyPublisher(),
            downloadPreferences.objectWillChange.eraseToAnyPublisher(),
        ]
        #if os(iOS)
        children.append(downloads.objectWillChange.eraseToAnyPublisher())
        #endif
        Publishers.MergeMany(children)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &childObservers)

        #if os(iOS)
        settings.$allowCellularDownloads
            .dropFirst()
            .removeDuplicates()
            .sink { [weak downloads] allowed in
                downloads?.setAllowsCellularDownloads(allowed)
            }
            .store(in: &childObservers)
        #endif

        Task { [weak self] in
            guard let self else { return }
            await userLibrary.waitUntilRestored()
            await movieCache.waitUntilRestored()
            #if os(iOS)
            await downloads.waitUntilRestored()
            #endif
            for entry in userLibrary.entries.values where entry.movie == nil {
                if let movie = self.bestRecordedMetadata(for: entry.key) ?? movieCache.movie(for: entry.key) {
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
            #if os(iOS)
            downloads.configure(connection: nil, statusClient: client)
            #endif
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

    #if os(iOS)
    func playOffline(_ record: DownloadRecord, start: PlaybackStart = .resume) {
        savedPlaybackEpoch += 1
        let captionSources = (record.localCaptions ?? []).compactMap { caption -> LocalCaptionSource? in
            guard let url = downloads.captionURL(for: record, caption: caption) else { return nil }
            return LocalCaptionSource(caption: caption, url: url)
        }
        player.play(.offline(record: record, url: downloads.localURL(for: record),
                             captionSources: captionSources, start: start))
    }

    func downloadMissingSubtitles(_ record: DownloadRecord) {
        guard !subtitleChecks.contains(record.id) else { return }
        let request = UUID()
        subtitleCheckIDs[record.id] = request
        subtitleChecks.insert(record.id)
        subtitleDownloadNotices[record.id] = nil
        subtitleCheckTasks[record.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.subtitleCheckIDs[record.id] == request {
                    self.subtitleChecks.remove(record.id)
                    self.subtitleCheckTasks[record.id] = nil
                    self.subtitleCheckIDs[record.id] = nil
                }
            }
            do {
                let owner = try self.client.ownedConnection()
                guard owner.connection?.owns(serverIdentity: record.serverOrigin, accountUsername: record.accountUsername) == true else {
                    throw DownloadQueueError.missingOwnership
                }
                let item = try await owner.item(id: record.mediaID)
                try Task.checkCancellation()
                guard self.subtitleCheckIDs[record.id] == request else { return }
                let count = try self.downloads.downloadMissingSubtitles(for: record, item: item, client: owner)
                let unavailable = item.captions.filter { !$0.isPlayableOnDevice }.count
                let limitation = unavailable > 0 ? " \(unavailable) unsupported track\(unavailable == 1 ? " is" : "s are") unavailable offline."
                    : item.embeddedCaptionsComplete == nil ? " This server may not expose embedded subtitles." : ""
                self.subtitleDownloadNotices[record.id] = (count > 0 ? "" : item.captions.isEmpty
                    ? "No downloadable subtitles are available." : "All available subtitles are already saved.") + limitation
            } catch {
                guard !Task.isCancelled, self.subtitleCheckIDs[record.id] == request else { return }
                self.subtitleDownloadNotices[record.id] = UserFacingError(error).message
            }
        }
    }

    func cancelSubtitleCheck(_ recordID: UUID) {
        subtitleCheckTasks.removeValue(forKey: recordID)?.cancel()
        subtitleCheckIDs[recordID] = nil
        subtitleChecks.remove(recordID)
    }
    #endif

    func playSaved(_ key: MovieLibraryKey, start: PlaybackStart = .resume) async throws {
        savedPlaybackEpoch += 1
        let epoch = savedPlaybackEpoch
        let playerIdentity = player.requestIdentity
        await userLibrary.waitUntilRestored()
        #if os(iOS)
        await downloads.waitUntilRestored()
        #endif
        try Task.checkCancellation()
        guard epoch == savedPlaybackEpoch, player.requestIdentity == playerIdentity else { return }
        #if os(iOS)
        if let record = bestReadyRecord(for: key) {
            playOffline(record, start: start)
            return
        }
        #endif
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
        #if os(iOS)
        downloads.completed.filter { $0.isReadyToWatch && self.key(for: $0) == key }
            .sorted {
                if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
                return $0.id.uuidString < $1.id.uuidString
            }.first
        #else
        nil
        #endif
    }

    /// Metadata from the newest stored copy, including copies not yet ready.
    private func bestRecordedMetadata(for key: MovieLibraryKey) -> MovieMetadata? {
        #if os(iOS)
        downloads.completed.filter { self.key(for: $0) == key }.max { $0.completedAt < $1.completedAt }?.movieMetadata
        #else
        nil
        #endif
    }

    func owns(_ key: MovieLibraryKey) -> Bool {
        client.connection?.owns(serverIdentity: key.serverIdentity, accountUsername: key.accountUsername) == true
    }

    private func apply(_ connection: ServerConnection) {
        client.configure(connection)
        library.configureConnection(connection)
        #if os(iOS)
        downloads.configure(connection: connection, statusClient: client)
        #endif
        isConfigured = true
    }
}
