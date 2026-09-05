import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var searchTask: Task<Void, Never>?

    private var usesCompactPosterGrid: Bool {
        horizontalSizeClass == .compact && dynamicTypeSize <= .large
    }

    private var columns: [GridItem] {
        if usesCompactPosterGrid {
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
            set: { app.library.query = $0 }
        ), prompt: "Search movies")
        .onChange(of: app.library.query) { _, _ in scheduleReload() }
        .onChange(of: app.library.sort) { _, _ in Task { await app.library.reloadReportingErrors() } }
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
                        set: { app.library.sort = $0 }
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
            ContentUnavailableView(
                "Connect to your server",
                systemImage: "network.slash",
                description: Text("Open Settings to connect to your movie library.")
            )
        } else if app.library.entries.isEmpty && app.library.isLoading {
            ProgressView("Loading your library…")
        } else if let error = app.library.errorMessage, app.library.entries.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load the library", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await app.library.reloadReportingErrors() } }
                    .buttonStyle(.borderedProminent)
            }
        } else if app.library.entries.isEmpty {
            emptyLibrary
        } else {
            loadedLibrary
        }
    }

    @ViewBuilder
    private var emptyLibrary: some View {
        if !app.library.query.isEmpty {
            ContentUnavailableView.search(text: app.library.query)
        } else if app.library.viewMode == .folders {
            ContentUnavailableView(
                "This folder is empty",
                systemImage: "folder",
                description: Text("Choose another folder or return to All Movies.")
            )
        } else {
            ContentUnavailableView(
                "No movies yet",
                systemImage: "film.stack",
                description: Text("Movies added to the server will appear here.")
            )
        }
    }

    private var loadedLibrary: some View {
        ScrollView {
            if app.library.viewMode == .folders, app.library.breadcrumbs.count > 1 {
                breadcrumbs
            }
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(app.library.entries) { entry in
                    entryLink(entry)
                        .task { await app.library.loadMoreIfNeeded(after: entry) }
                }
            }
            .padding(gridPadding)

            if app.library.isLoading {
                ProgressView().padding(.vertical, 24)
            } else if app.library.canLoadMore, let last = app.library.entries.last {
                Button("Load more") { Task { await app.library.loadMoreIfNeeded(after: last) } }
                    .padding(.bottom, 24)
            }
        }
        .refreshable { await app.library.reloadReportingErrors() }
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
                    Button(folder.title) {
                        Task { await app.library.openFolder(folder.id) }
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

    private func scheduleReload() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await app.library.reloadReportingErrors()
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
            Text(entry.displayTitle)
                .font(usesCompactPresentation ? .subheadline.weight(.semibold) : .headline)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(usesCompactPresentation ? 3 : nil)
                .frame(
                    minHeight: usesCompactPresentation ? 60 : 44,
                    maxHeight: usesCompactPresentation ? 60 : nil,
                    alignment: .topLeading
                )
                .foregroundStyle(.primary)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library-card-\(entry.id)")
    }
}
