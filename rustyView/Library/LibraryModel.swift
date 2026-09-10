import Foundation

struct BrowseLocation: Hashable, Sendable {
    let serverIdentity: String
    let accountUsername: String
    let view: LibraryViewMode
    let folderID: String?
    let query: String
    let sort: String
}

private struct BrowsePreference: Codable {
    let serverIdentity: String
    let accountUsername: String
    let view: String
    let sort: String
}

/// The native field observes edits independently of the movie collection. A
/// keystroke must not invalidate every card and every AppModel subscriber.
@MainActor
final class LibrarySearchInput: ObservableObject {
    @Published fileprivate(set) var text = ""
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published private(set) var capabilities: ServerCapabilities?
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = false
    @Published private(set) var viewMode = LibraryViewMode.library
    @Published private(set) var currentFolder: FolderReference?
    @Published private(set) var breadcrumbs: [FolderReference] = []
    @Published private(set) var displayedLocation: BrowseLocation?
    @Published private(set) var visibleAnchor: String?
    @Published private(set) var error: UserFacingError?
    let searchInput = LibrarySearchInput()
    var query: String {
        get { searchInput.text }
        set { setQuery(newValue, endingLoading: true) }
    }
    @Published var sort = LibrarySort.title { didSet { if sort != oldValue { invalidateRequest() } } }

    private struct Snapshot {
        let entries: [LibraryEntry]
        let capabilities: ServerCapabilities?
        let total: Int
        let hasMore: Bool
        let folder: FolderReference?
        let breadcrumbs: [FolderReference]
        let generation: Int?
        let anchor: String?
    }
    private let client: RustyDLNAClient
    private let defaults: UserDefaults?
    private var owner: MovieLibraryKey?
    private var folderID: String?
    private var rootFolderID: String?
    private var generation: Int?
    private var requestEpoch = 0
    private var requestTask: Task<LibraryPage, Error>?
    private var searchTask: Task<Void, Never>?
    private var snapshots: [BrowseLocation: Snapshot] = [:]
    private var snapshotOrder: [BrowseLocation] = []

    init(client: RustyDLNAClient, defaults: UserDefaults? = nil) {
        self.client = client
        self.defaults = defaults
        if let connection = client.connection { configureConnection(connection) }
    }

    var errorMessage: String? { error?.message }
    var isNavigating: Bool { isLoading && displayedLocation != requestedLocation }
    var loadingDescription: String {
        if !query.isEmpty { return "Searching movies…" }
        return viewMode == .folders ? "Loading folder…" : "Loading movies…"
    }
    var requestedLocation: BrowseLocation? {
        guard let connection = client.connection else { return nil }
        return BrowseLocation(serverIdentity: connection.serverIdentity, accountUsername: connection.username,
                              view: viewMode, folderID: viewMode == .folders ? folderID ?? rootFolderID : nil,
                              query: query, sort: sort.rawValue)
    }

    func configureConnection(_ connection: ServerConnection) {
        let next = MovieLibraryKey(connection: connection, mediaID: "")
        guard owner != next else { return }
        clear()
        owner = next
        let request = initialRequest(for: connection)
        viewMode = request.view
        sort = request.sort
    }

    func initialRequest(for connection: ServerConnection) -> LibraryRequest {
        let preference = preferences.first {
            $0.serverIdentity == connection.serverIdentity && $0.accountUsername == connection.username
        }
        return LibraryRequest(view: preference.flatMap { LibraryViewMode(rawValue: $0.view) } ?? .library,
                              sort: preference.flatMap { LibrarySort(rawValue: $0.sort) } ?? .title)
    }

    func reload() async throws { try await load(reset: true) }
    func reloadReportingErrors() async { try? await reload() }

    func search(_ value: String) {
        guard value != query else { return }
        saveSnapshot()
        searchTask?.cancel()
        // Keep the pending presentation stable while replacing its request.
        // Publishing false/true for every edit repeatedly rebuilds the grid.
        if query.isEmpty != value.isEmpty, isLoading { objectWillChange.send() }
        setQuery(value, endingLoading: false)
        if error != nil { error = nil }
        if !isLoading { isLoading = true }
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            if value.isEmpty, restoreSnapshot() { return }
            await reloadReportingErrors()
        }
    }

    func clearSearch() async {
        saveSnapshot()
        searchTask?.cancel()
        query = ""
        if !restoreSnapshot() { await reloadReportingErrors() }
    }

    func changeSort(_ value: LibrarySort) async {
        guard value != sort else { return }
        saveSnapshot()
        searchTask?.cancel()
        sort = value
        persistPreference()
        await reloadReportingErrors()
    }

    func switchView(_ mode: LibraryViewMode) async {
        guard mode != viewMode else { return }
        saveSnapshot()
        searchTask?.cancel()
        invalidateRequest()
        viewMode = mode
        folderID = nil
        query = ""
        persistPreference()
        if !restoreSnapshot() { await reloadReportingErrors() }
    }

    func openFolder(_ id: String) async {
        guard viewMode == .folders else { return }
        saveSnapshot()
        searchTask?.cancel()
        invalidateRequest()
        folderID = id
        query = ""
        if !restoreSnapshot() { await reloadReportingErrors() }
    }

    func navigateUp() async {
        guard viewMode == .folders, breadcrumbs.count > 1 else { return }
        await openFolder(breadcrumbs[breadcrumbs.count - 2].id)
    }

    func recordVisibleAnchor(_ id: String?) {
        guard displayedLocation == requestedLocation, let id, entries.contains(where: { $0.id == id }) else { return }
        guard visibleAnchor != id else { return }
        visibleAnchor = id
    }

    func loadMoreIfNeeded(after entry: LibraryEntry) async {
        guard displayedLocation == requestedLocation, canLoadMore, !isLoading,
              entries.suffix(8).contains(entry) else { return }
        try? await load(reset: false)
    }

    func replaceWithVerifiedPage(_ page: LibraryPage) {
        clear()
        if let connection = client.connection { owner = MovieLibraryKey(connection: connection, mediaID: "") }
        viewMode = LibraryViewMode(rawValue: page.view) ?? .library
        sort = LibrarySort(rawValue: page.sort) ?? .title
        apply(page, reset: true)
    }

    func clear() {
        invalidateRequest()
        searchTask?.cancel()
        searchTask = nil
        query = ""
        entries = []
        capabilities = nil
        viewMode = .library
        folderID = nil
        rootFolderID = nil
        currentFolder = nil
        breadcrumbs = []
        generation = nil
        total = 0
        canLoadMore = false
        error = nil
        visibleAnchor = nil
        displayedLocation = nil
        snapshots = [:]
        snapshotOrder = []
        owner = nil
    }

    private func setQuery(_ value: String, endingLoading: Bool) {
        guard value != searchInput.text else { return }
        invalidateRequest(endingLoading: endingLoading)
        searchInput.text = value
    }

    private func invalidateRequest(endingLoading: Bool = true) {
        requestEpoch += 1
        requestTask?.cancel()
        requestTask = nil
        if endingLoading, isLoading { isLoading = false }
    }

    private func load(reset: Bool) async throws {
        if let connection = client.connection,
           owner != MovieLibraryKey(connection: connection, mediaID: "") { configureConnection(connection) }
        if !reset && !canLoadMore { return }
        invalidateRequest(endingLoading: false)
        let epoch = requestEpoch
        let requestOwner = client.connection.map { MovieLibraryKey(connection: $0, mediaID: "") }
        if error != nil { error = nil }
        if !isLoading { isLoading = true }
        defer { if epoch == requestEpoch { isLoading = false; requestTask = nil } }
        let request = LibraryRequest(view: viewMode, folderID: folderID, query: query, sort: sort,
                                     offset: reset ? 0 : entries.count, limit: 60,
                                     generation: reset ? nil : generation)
        let operation = Task { try await client.library(request) }
        requestTask = operation
        do {
            let page = try await operation.value
            try Task.checkCancellation()
            guard epoch == requestEpoch,
                  requestOwner == client.connection.map({ MovieLibraryKey(connection: $0, mediaID: "") }) else { return }
            guard page.schemaVersion == RustyDLNAClient.schemaVersion else {
                throw RustyDLNAError.schemaMismatch(page.schemaVersion)
            }
            apply(page, reset: reset)
        } catch {
            guard epoch == requestEpoch else { return }
            if !Task.isCancelled && !(error is CancellationError) && (error as NSError).code != NSURLErrorCancelled {
                self.error = UserFacingError(error)
            }
            throw error
        }
    }

    private func apply(_ page: LibraryPage, reset: Bool) {
        generation = page.generation
        rootFolderID = page.rootFolderID
        capabilities = page.capabilities
        currentFolder = page.folder
        if viewMode == .folders { folderID = page.folder?.id ?? page.rootFolderID }
        breadcrumbs = page.breadcrumbs
        entries = reset ? page.entries : entries + page.entries
        total = page.total
        canLoadMore = page.hasMore
        if reset && (displayedLocation != requestedLocation || !entries.contains(where: { $0.id == visibleAnchor })) {
            visibleAnchor = nil
        }
        displayedLocation = requestedLocation
        error = nil
        saveSnapshot()
    }

    private func saveSnapshot() {
        guard let location = displayedLocation, location == requestedLocation else { return }
        snapshots[location] = Snapshot(entries: entries, capabilities: capabilities, total: total,
                                       hasMore: canLoadMore, folder: currentFolder, breadcrumbs: breadcrumbs,
                                       generation: generation, anchor: visibleAnchor)
        snapshotOrder.removeAll { $0 == location }
        snapshotOrder.append(location)
        while snapshotOrder.count > 8 { snapshots.removeValue(forKey: snapshotOrder.removeFirst()) }
    }

    private func restoreSnapshot() -> Bool {
        guard let location = requestedLocation, let snapshot = snapshots[location] else { return false }
        invalidateRequest()
        entries = snapshot.entries
        capabilities = snapshot.capabilities
        total = snapshot.total
        canLoadMore = snapshot.hasMore
        currentFolder = snapshot.folder
        breadcrumbs = snapshot.breadcrumbs
        generation = snapshot.generation
        visibleAnchor = snapshot.anchor
        displayedLocation = location
        error = nil
        return true
    }

    private var preferences: [BrowsePreference] {
        guard let data = defaults?.data(forKey: "browsePreferences.v1") else { return [] }
        return (try? JSONDecoder().decode([BrowsePreference].self, from: data)) ?? []
    }
    private func persistPreference() {
        guard let connection = client.connection else { return }
        var values = preferences.filter {
            $0.serverIdentity != connection.serverIdentity || $0.accountUsername != connection.username
        }
        values.append(BrowsePreference(serverIdentity: connection.serverIdentity, accountUsername: connection.username,
                                       view: viewMode.rawValue, sort: sort.rawValue))
        if let data = try? JSONEncoder().encode(Array(values.suffix(20))) {
            defaults?.set(data, forKey: "browsePreferences.v1")
        }
    }

    deinit { requestTask?.cancel(); searchTask?.cancel() }
}
