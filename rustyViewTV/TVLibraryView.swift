import SwiftUI

/// Focus targets in a browse screen. Folders change in place, so the screen
/// itself has to put focus somewhere sensible when the grid is replaced.
enum TVBrowseFocus: Hashable {
    case control(String)
    case breadcrumb(String)
    case entry(String)
}

struct TVLibraryView: View {
    @EnvironmentObject private var app: AppModel
    @State private var choosingSort = false
    @FocusState private var focus: TVBrowseFocus?
    /// Whether the person was last in the folder contents (posters or the
    /// path) rather than the controls. Survives focus briefly becoming nil
    /// while the old grid is removed.
    @State private var focusWasInContent = false
    @State private var settleTask: Task<Void, Never>?
    private static let topID = "library-top"

    var body: some View {
        content
            .sheet(isPresented: $choosingSort) {
                NavigationStack {
                    TVChoiceList(title: "Sort", options: LibrarySort.allCases.map {
                        TVChoice(value: $0, title: $0.label, identifier: "sort-\($0.rawValue)")
                    }, selection: app.library.sort) { value in
                        Task { await app.library.changeSort(value) }
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !app.isConfigured {
            TVConnectPrompt()
        } else if app.library.entries.isEmpty && app.library.isLoading && !app.library.isNavigating {
            ProgressView("Loading your library…")
        } else if let error = app.library.error, app.library.entries.isEmpty {
            ScrollView {
                controls.focusSection()
                TVErrorRecoveryView(error: error, isRetrying: app.library.isLoading) {
                    Task { await app.library.reloadReportingErrors() }
                }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 48) {
                        controls.focusSection().id(Self.topID)
                        if app.library.viewMode == .folders, app.library.breadcrumbs.count > 1 {
                            breadcrumbs.focusSection()
                        }
                        if app.library.viewMode == .library {
                            TVContinueWatchingShelf()
                        }
                        if let error = app.library.error, !app.library.entries.isEmpty {
                            TVErrorRecoveryView(error: error, isRetrying: app.library.isLoading) {
                                Task { await app.library.reloadReportingErrors() }
                            }
                        }
                        if app.library.entries.isEmpty && !app.library.isLoading {
                            emptyLibrary
                        } else {
                            // The previous folder stays put and focusable while the
                            // next one loads. Disabling it would throw focus to the
                            // top controls and scroll the whole page away.
                            TVLibraryGrid(model: app.library, focus: $focus)
                                .opacity(app.library.isNavigating ? 0.45 : 1)
                                .id(app.library.displayedLocation)
                        }
                        TVUserLibraryRecoveryBanner()
                    }
                    .padding(.bottom, 60)
                }
                // Progress floats over the grid so it never shifts the layout,
                // and stays visible however far down the person has scrolled.
                .overlay(alignment: .top) {
                    if app.library.isNavigating { navigationProgress }
                }
                .onChange(of: focus) { _, value in
                    guard let value else { return }
                    if case .control = value { focusWasInContent = false } else { focusWasInContent = true }
                }
                .onChange(of: app.library.displayedLocation) { _, _ in settleAfterNavigation(proxy) }
                .onDisappear { settleTask?.cancel() }
            }
        }
    }

    private var navigationProgress: some View {
        HStack(spacing: 20) {
            ProgressView()
            Text(app.library.loadingDescription)
        }
        .font(.callout)
        .padding(.horizontal, 36)
        .padding(.vertical, 18)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("browse-loading")
    }

    /// Runs once a different folder, view or sort is on screen. Returning to a
    /// folder lands on the poster that was opened from it; anything new starts
    /// at the top. Focus moves only if the person was in the contents, so
    /// choosing Folders or a sort order leaves focus on that control.
    private func settleAfterNavigation(_ proxy: ScrollViewProxy) {
        settleTask?.cancel()
        let entries = app.library.entries
        let anchor = app.library.visibleAnchor.flatMap { id in entries.contains { $0.id == id } ? id : nil }
        if let anchor {
            proxy.scrollTo(anchor, anchor: .center)
        } else {
            proxy.scrollTo(Self.topID, anchor: .top)
        }
        guard focusWasInContent, let target = anchor ?? entries.first?.id else { return }
        settleTask = Task { @MainActor in
            // The rebuilt grid realizes its posters during the next layout
            // passes; a focus request before then is silently dropped.
            for _ in 0..<10 {
                focus = .entry(target)
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled || focus == .entry(target) { return }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 32) {
            ForEach(LibraryViewMode.allCases) { mode in
                Button {
                    Task { await app.library.switchView(mode) }
                } label: {
                    Label(mode.label, systemImage: mode == .library ? "film.stack" : "folder")
                }
                .accessibilityAddTraits(mode == app.library.viewMode ? .isSelected : [])
                .accessibilityIdentifier("browse-\(mode.rawValue)")
                .opacity(mode == app.library.viewMode ? 1 : 0.7)
                .focused($focus, equals: .control(mode.rawValue))
            }
            Button { choosingSort = true } label: {
                Label("Sort: \(app.library.sort.label)", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityIdentifier("library-sort")
            .focused($focus, equals: .control("sort"))
            Spacer(minLength: 24)
            if app.library.total > 0 {
                Text("\(app.library.total) \(app.library.viewMode == .folders ? "items" : "movies")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Stays enabled while loading: disabling the focused button would
            // throw focus elsewhere. A press during a load is simply ignored.
            Button {
                guard !app.library.isLoading else { return }
                Task { await app.library.reloadReportingErrors() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("library-refresh")
            .focused($focus, equals: .control("refresh"))
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(Array(app.library.breadcrumbs.enumerated()), id: \.element.id) { index, folder in
                    if index > 0 {
                        Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    Button(folder.title) { Task { await app.library.openFolder(folder.id) } }
                        .disabled(index == app.library.breadcrumbs.count - 1)
                        .accessibilityIdentifier("breadcrumb-\(folder.id)")
                        .focused($focus, equals: .breadcrumb(folder.id))
                }
            }
            .padding(.vertical, 12)
        }
        .scrollClipDisabled()
        .accessibilityLabel("Folder path")
    }

    @ViewBuilder
    private var emptyLibrary: some View {
        if app.library.viewMode == .folders {
            ContentUnavailableView {
                Label("This folder is empty", systemImage: "folder")
            } description: {
                Text("Choose another folder or return to All Movies.")
            } actions: {
                if app.library.breadcrumbs.count > 1 {
                    Button("Parent Folder") { Task { await app.library.navigateUp() } }
                }
                Button("All Movies") { Task { await app.library.switchView(.library) } }
            }
        } else {
            ContentUnavailableView {
                Label("No movies yet", systemImage: "film.stack")
            } description: {
                Text("Movies added to the server will appear here.")
            } actions: {
                Button("Refresh") { Task { await app.library.reloadReportingErrors() } }
            }
        }
    }
}

/// The paged poster grid shared by browsing and search. Each model owns its
/// own request epochs, so search results never replace the browse grid.
struct TVLibraryGrid: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: LibraryModel
    var focus: FocusState<TVBrowseFocus?>.Binding

    var body: some View {
        // One focus section spanning the full width: moving down from any
        // control above enters the grid, even when the folder holds a single
        // poster at the far left.
        VStack(spacing: 40) {
            LazyVGrid(columns: TVLayout.posterColumns, spacing: 64) {
                ForEach(model.entries) { entry in
                    cell(entry)
                        .id(entry.id)
                        .task { await model.loadMoreIfNeeded(after: entry) }
                }
            }
            if model.isLoading && !model.isNavigating && !model.entries.isEmpty {
                ProgressView()
            } else if model.canLoadMore, let last = model.entries.last {
                Button("Load More") { Task { await model.loadMoreIfNeeded(after: last) } }
            }
        }
        .frame(maxWidth: .infinity)
        .focusSection()
    }

    @ViewBuilder
    private func cell(_ entry: LibraryEntry) -> some View {
        if entry.isFolder {
            TVPosterCell(title: entry.displayTitle, detail: "\(entry.childCount ?? 0) items") {
                Button {
                    // A second press while this folder loads would restart it.
                    if model.isNavigating, model.requestedLocation?.folderID == entry.id { return }
                    // Remember this poster so returning to this folder lands here.
                    model.recordVisibleAnchor(entry.id)
                    Task { await model.openFolder(entry.id) }
                } label: {
                    TVPosterArtwork(artworkPath: nil, isFolder: true)
                }
                .buttonStyle(.card)
                .focused(focus, equals: .entry(entry.id))
                .accessibilityLabel("Folder \(entry.displayTitle)")
                .accessibilityIdentifier("library-card-\(entry.id)")
            }
        } else {
            let key = app.client.connection.map { MovieLibraryKey(connection: $0, mediaID: entry.id) }
            TVPosterCell(title: entry.displayTitle, detail: detail(entry, key: key)) {
                NavigationLink(value: TVRoute.movie(MovieMetadata(entry: entry), key: nil)) {
                    TVPosterArtwork(artworkPath: entry.artURL, progress: progress(key))
                }
                .buttonStyle(.card)
                .focused(focus, equals: .entry(entry.id))
                .accessibilityLabel(entry.displayTitle)
                .accessibilityValue(detail(entry, key: key) ?? "")
                .accessibilityIdentifier("library-card-\(entry.id)")
                .contextMenu {
                    if let key {
                        let favorite = app.userLibrary.isFavorite(for: key)
                        Button(favorite ? "Remove from Favorites" : "Add to Favorites",
                               systemImage: favorite ? "heart.slash" : "heart") {
                            app.userLibrary.setFavorite(!favorite, movie: MovieMetadata(entry: entry), for: key)
                        }
                    }
                }
            }
        }
    }

    private func detail(_ entry: LibraryEntry, key: MovieLibraryKey?) -> String? {
        if let key, let left = app.timeRemaining(for: key, duration: entry.durationSeconds.map(Double.init)) {
            return left
        }
        return [entry.duration?.components(separatedBy: ".").first, entry.resolution]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func progress(_ key: MovieLibraryKey?) -> Double? {
        guard let key, app.userLibrary.resumePosition(for: key) != nil,
              let progress = app.userLibrary.entry(for: key)?.progress, progress.duration > 0 else { return nil }
        return progress.position / progress.duration
    }
}

struct TVSearchView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: LibraryModel
    @State private var text = ""
    @FocusState private var focus: TVBrowseFocus?

    init(client: RustyDLNAClient) {
        // Search owns a separate browse model: results never relabel or
        // replace the Library tab's folder, sort or scroll position.
        _model = StateObject(wrappedValue: LibraryModel(client: client))
    }

    var body: some View {
        content
            .searchable(text: $text, prompt: "Movies")
            .onChange(of: text) { _, value in
                model.search(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
    }

    @ViewBuilder
    private var content: some View {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !app.isConfigured {
            TVConnectPrompt()
        } else if query.isEmpty {
            ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass",
                                   description: Text("Find movies by title."))
        } else if let error = model.error, model.entries.isEmpty {
            TVErrorRecoveryView(error: error, isRetrying: model.isLoading) {
                Task { await model.reloadReportingErrors() }
            }
        } else if model.entries.isEmpty {
            if model.isLoading || model.query != query {
                ProgressView("Searching movies…")
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            ScrollView {
                VStack(spacing: 40) {
                    // Earlier results stay put, but are not relabeled as the
                    // new query's results while it is pending.
                    if model.isNavigating {
                        ProgressView("Searching movies…").accessibilityIdentifier("search-loading")
                    }
                    TVLibraryGrid(model: model, focus: $focus).disabled(model.isNavigating)
                }
                .padding(.bottom, 60)
            }
        }
    }
}
