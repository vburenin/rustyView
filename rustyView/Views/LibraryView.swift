import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var usesCompactPosterGrid: Bool {
        horizontalSizeClass == .compact && dynamicTypeSize <= .large
    }

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            [GridItem(.flexible(), spacing: 18, alignment: .top)]
        } else if usesCompactPosterGrid {
            [GridItem(.adaptive(minimum: 104, maximum: 132), spacing: 12, alignment: .top)]
        } else {
            [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 18, alignment: .top)]
        }
    }

    private var gridSpacing: CGFloat { usesCompactPosterGrid ? 18 : 24 }
    private var gridPadding: CGFloat { usesCompactPosterGrid ? 12 : 16 }

    var body: some View {
        content
        .navigationTitle(app.library.currentFolder?.title ?? "Movies")
        .navigationDestination(for: LibraryEntry.self) { entry in
            MovieDetailView(entry: entry)
        }
        .searchable(text: Binding(
            get: { app.library.query },
            set: { app.library.search($0) }
        ), placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("Search movies").foregroundColor(.primary.opacity(0.75)))
        .safeAreaInset(edge: .bottom) { UserLibraryRecoveryView() }
        .toolbar {
            if app.library.viewMode == .folders, app.library.breadcrumbs.count > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await app.library.navigateUp() }
                    } label: {
                        Label("Parent folder", systemImage: "chevron.left")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    SavedCollectionLinks()
                    Divider()
                    ForEach(LibraryViewMode.allCases) { mode in
                        Button {
                            Task { await app.library.switchView(mode) }
                        } label: {
                            if mode == app.library.viewMode {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                } label: {
                    Label("Browse", systemImage: app.library.viewMode == .library ? "film.stack" : "folder")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: Binding(
                        get: { app.library.sort },
                        set: { value in Task { await app.library.changeSort(value) } }
                    )) {
                        ForEach(LibrarySort.allCases) { sort in Text(sort.label).tag(sort) }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !app.isConfigured {
            VStack {
                ContinueWatchingPreview().padding()
                ContentUnavailableView {
                    Label("Connect to your server", systemImage: "network.slash")
                } description: { Text("Connect to browse your movie library. Saved movies remain available in Downloads.") }
                actions: {
                    Button { app.showingConnection = true } label: {
                        Text("Connect").frame(minWidth: 44, minHeight: 44)
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(Color("ActionFill"))
                    Button { app.selectedTab = .downloads } label: {
                        Text("Watch Downloads").frame(minWidth: 44, minHeight: 44)
                    }
                }
            }
        } else if app.library.entries.isEmpty && app.library.isLoading {
            VStack {
                ContinueWatchingPreview().padding()
                Spacer()
                ProgressView("Loading your library…")
                Spacer()
            }
        } else if let error = app.library.error, app.library.entries.isEmpty {
            ScrollView {
                ContinueWatchingPreview().padding()
                ErrorRecoveryView(error: error, retry: { Task { await app.library.reloadReportingErrors() } }).padding()
            }
        } else if app.library.entries.isEmpty {
            VStack { ContinueWatchingPreview().padding(); emptyLibrary }
        } else {
            loadedLibrary
        }
    }

    @ViewBuilder
    private var emptyLibrary: some View {
        if !app.library.query.isEmpty {
            ContentUnavailableView {
                Label("No matching movies", systemImage: "magnifyingglass")
            } description: { EmptyView() }
            actions: { ClearLibrarySearchButton() }
        } else if app.library.viewMode == .folders {
            ContentUnavailableView {
                Label("This folder is empty", systemImage: "folder")
            } description: { Text("Choose another folder or return to All Movies.") }
            actions: {
                if app.library.breadcrumbs.count > 1 {
                    Button { Task { await app.library.navigateUp() } } label: {
                        Text("Parent Folder").frame(minWidth: 44, minHeight: 44)
                    }
                }
                Button { Task { await app.library.switchView(.library) } } label: {
                    Text("All Movies").frame(minWidth: 44, minHeight: 44)
                }
                Button { Task { await app.library.reloadReportingErrors() } } label: {
                    Text("Refresh").frame(minWidth: 44, minHeight: 44)
                }
            }
        } else {
            ContentUnavailableView {
                Label("No movies yet", systemImage: "film.stack")
            } description: { Text("Movies added to the server will appear here.") }
            actions: {
                Button { Task { await app.library.reloadReportingErrors() } } label: {
                    Text("Refresh").frame(minWidth: 44, minHeight: 44)
                }
            }
        }
    }

    private var loadedLibrary: some View {
        PositionedLibraryScroll(model: app.library) {
            if app.library.query.isEmpty, app.library.viewMode == .library {
                ContinueWatchingPreview().padding(.horizontal)
            }
            if app.library.viewMode == .folders, app.library.breadcrumbs.count > 1 {
                breadcrumbs
            }
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(app.library.entries) { entry in
                    entryLink(entry)
                        .accessibilityIdentifier("library-card-\(entry.id)")
                        .id(entry.id)
                        .task { await app.library.loadMoreIfNeeded(after: entry) }
                }
            }
            .scrollTargetLayout()
            .padding(gridPadding)

            if app.library.isLoading {
                ProgressView().padding(.vertical, 24)
            } else if app.library.canLoadMore, let last = app.library.entries.last {
                Button("Load more") { Task { await app.library.loadMoreIfNeeded(after: last) } }
                    .padding(.bottom, 24)
            }
        }
        .id(app.library.displayedLocation)
        .disabled(app.library.isNavigating)
        .overlay(alignment: .top) {
            if app.library.isNavigating {
                ProgressView(app.library.loadingDescription)
                    .padding().frame(maxWidth: .infinity).background(.regularMaterial)
                    .accessibilityIdentifier("browse-loading")
            }
        }
        .refreshable { await app.library.reloadReportingErrors() }
        .safeAreaInset(edge: .bottom) {
            if app.library.error != nil {
                RecoveryBanner("Library needs attention", identifier: "library-recovery") { action in
                    if let error = app.library.error {
                        ErrorRecoveryView(error: error, isRetrying: app.library.isLoading,
                                          recoveryAction: action, retry: {
                            Task { await app.library.reloadReportingErrors() }
                        })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func entryLink(_ entry: LibraryEntry) -> some View {
        if entry.isFolder {
            Button {
                Task { await app.library.openFolder(entry.id) }
            } label: {
                LibraryCard(entry: entry)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: entry) {
                LibraryCard(entry: entry)
            }
            .buttonStyle(.plain)
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(app.library.breadcrumbs.enumerated()), id: \.element.id) { index, folder in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    Button {
                        Task { await app.library.openFolder(folder.id) }
                    } label: {
                        Text(folder.title).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .font(index == app.library.breadcrumbs.count - 1 ? .subheadline.bold() : .subheadline)
                    .disabled(index == app.library.breadcrumbs.count - 1)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .accessibilityLabel("Folder path")
    }

}

private struct LibraryTitleFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Restore a visible title, rather than the next full poster below it. Titles
/// remain recognizable when search changes the keyboard and navigation insets.
private struct PositionedLibraryScroll<Content: View>: View {
    @ObservedObject var model: LibraryModel
    @State private var scrollID: String?
    @State private var initialAnchor: String?
    @State private var hasAppeared = false
    private let content: Content

    init(model: LibraryModel, @ViewBuilder content: () -> Content) {
        self.model = model
        _scrollID = State(initialValue: model.visibleAnchor)
        _initialAnchor = State(initialValue: model.visibleAnchor)
        self.content = content()
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
            ScrollView { content }
                    // SwiftUI owns the live grid position through size changes.
                    // The saved title anchor is separate: writing geometry back
                    // into the scroll binding would move the view while reading it.
                    .scrollPosition(id: $scrollID, anchor: .center)
                    .task {
                        if let initialAnchor {
                            // The grid must register its lazy targets before a
                            // recreated search/folder view can restore one.
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            proxy.scrollTo(initialAnchor, anchor: .center)
                            scrollID = initialAnchor
                            self.initialAnchor = nil
                        }
                        hasAppeared = true
                    }
                    .onPreferenceChange(LibraryTitleFrames.self) { frames in
                        guard hasAppeared, !model.isNavigating else { return }
                        let visible = frames.filter {
                            $0.value.midY > viewport.safeAreaInsets.top && $0.value.midY < viewport.size.height - viewport.safeAreaInsets.bottom
                        }.sorted {
                            if abs($0.value.midY - $1.value.midY) > 2 { return $0.value.midY < $1.value.midY }
                            return $0.value.minX < $1.value.minX
                        }
                        if let first = visible.first {
                            model.recordVisibleAnchor(first.key)
                        }
                    }
            .coordinateSpace(name: "library-viewport")
            }
        }
    }
}

private struct ClearLibrarySearchButton: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismissSearch) private var dismissSearch
    var body: some View {
        Button {
            dismissSearch()
            Task { await app.library.clearSearch() }
        } label: {
            Text("Clear Search").frame(minWidth: 44, minHeight: 44)
        }
    }
}

private struct LibraryCard: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: LibraryEntry

    private var usesCompactPresentation: Bool {
        horizontalSizeClass == .compact && dynamicTypeSize <= .large
    }

    var body: some View {
        VStack(alignment: .leading, spacing: usesCompactPresentation ? 7 : 9) {
            if dynamicTypeSize.isAccessibilitySize {
                title
                HStack(alignment: .top, spacing: 16) {
                    poster.frame(width: 64)
                    metadata.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                poster
                title
                metadata
            }
            if !entry.isFolder, let connection = app.client.connection {
                let key = MovieLibraryKey(connection: connection, mediaID: entry.id)
                if let left = app.timeRemaining(for: key, duration: entry.durationSeconds.map(Double.init)) {
                    Text(left).font(.caption).foregroundStyle(.secondary)
                }
                if let progress = app.userLibrary.entry(for: key)?.progress, progress.duration > 0,
                   app.userLibrary.resumePosition(for: key) != nil {
                    ProgressView(value: min(1, max(0, progress.position / progress.duration)))
                        .accessibilityLabel("Movie progress")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
    private var poster: some View {
        PosterFrame {
            if entry.isFolder {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.orange.opacity(0.12))
                    .overlay {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.orange)
                    }
            } else {
                AuthenticatedArtworkView(path: entry.artURL, client: app.client)
                    .overlay(alignment: .bottomTrailing) {
                        if app.downloads.record(for: entry.id) != nil {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.white, .green)
                                .font(usesCompactPresentation ? .body : .title2)
                                .padding(usesCompactPresentation ? 6 : 8)
                                .accessibilityLabel("Downloaded")
                        }
                    }
            }
        }
    }

    private var title: some View {
        Text(entry.displayTitle)
            .font(usesCompactPresentation ? .subheadline.weight(.semibold) : .headline)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(usesCompactPresentation ? 3 : nil)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: LibraryTitleFrames.self,
                        value: [entry.id: geometry.frame(in: .named("library-viewport"))])
                }
            }
            .frame(
                minHeight: usesCompactPresentation ? 60 : 44,
                maxHeight: usesCompactPresentation ? 60 : nil,
                alignment: .topLeading
            )
            .foregroundStyle(.primary)
    }

    private var metadata: some View {
        Group {
            if entry.isFolder {
                Text("\(entry.childCount ?? 0) items")
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        if let duration = entry.duration { Text(duration.components(separatedBy: ".").first ?? duration) }
                        if let resolution = entry.resolution {
                            Text("•").accessibilityHidden(true)
                            Text(resolution)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if let duration = entry.duration { Text(duration.components(separatedBy: ".").first ?? duration) }
                        if let resolution = entry.resolution { Text(resolution) }
                    }
                }
            }
        }
        .font(usesCompactPresentation ? .caption2 : .caption)
        .foregroundStyle(.primary)
    }

}
