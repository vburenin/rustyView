import Foundation

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
    @Published var query = "" {
        didSet {
            if query != oldValue { requestEpoch += 1 }
        }
    }
    @Published var sort = LibrarySort.title {
        didSet {
            if sort != oldValue { requestEpoch += 1 }
        }
    }
    @Published var errorMessage: String?

    private let client: RustyDLNAClient
    private var folderID: String?
    private var generation: Int?
    private var requestEpoch = 0

    init(client: RustyDLNAClient) {
        self.client = client
    }

    func reload() async throws {
        try await load(reset: true)
    }

    func reloadReportingErrors() async {
        do {
            try await reload()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func switchView(_ mode: LibraryViewMode) async {
        guard mode != viewMode else { return }
        viewMode = mode
        folderID = nil
        currentFolder = nil
        breadcrumbs = []
        query = ""
        await reloadReportingErrors()
    }

    func openFolder(_ id: String) async {
        guard viewMode == .folders else { return }
        folderID = id
        query = ""
        await reloadReportingErrors()
    }

    func navigateUp() async {
        guard viewMode == .folders, breadcrumbs.count > 1 else { return }
        let parent = breadcrumbs[breadcrumbs.count - 2]
        await openFolder(parent.id)
    }

    func loadMoreIfNeeded(after entry: LibraryEntry) async {
        guard canLoadMore, !isLoading, entries.suffix(8).contains(entry) else { return }
        try? await load(reset: false)
    }

    func clear() {
        requestEpoch += 1
        entries = []
        capabilities = nil
        viewMode = .library
        folderID = nil
        currentFolder = nil
        breadcrumbs = []
        generation = nil
        total = 0
        canLoadMore = false
        errorMessage = nil
    }

    private func load(reset: Bool) async throws {
        requestEpoch += 1
        let epoch = requestEpoch
        if reset {
            generation = nil
            errorMessage = nil
        } else if !canLoadMore {
            return
        }
        isLoading = true
        defer { if epoch == requestEpoch { isLoading = false } }

        let request = LibraryRequest(
            view: viewMode,
            folderID: folderID,
            query: query,
            sort: sort,
            offset: reset ? 0 : entries.count,
            limit: 60,
            generation: reset ? nil : generation
        )
        let page = try await client.library(request)
        guard epoch == requestEpoch else { return }
        guard page.schemaVersion == RustyDLNAClient.schemaVersion else {
            throw RustyDLNAError.schemaMismatch(page.schemaVersion)
        }
        generation = page.generation
        capabilities = page.capabilities
        currentFolder = page.folder
        breadcrumbs = page.breadcrumbs
        entries = reset ? page.entries : entries + page.entries
        total = page.total
        canLoadMore = page.hasMore
        errorMessage = nil
    }
}
