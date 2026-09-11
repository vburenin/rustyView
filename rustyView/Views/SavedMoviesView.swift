import SwiftUI

struct MyMoviesView: View {
    @EnvironmentObject private var app: AppModel
    @State private var query = ""

    var body: some View {
        List {
            if app.userLibrary.isRestoring {
                ProgressView("Loading saved library…")
            } else if query.isEmpty {
                let continuing = app.savedEntries(.continueWatching)
                if !continuing.isEmpty {
                    Section("Continue Watching") {
                        ForEach(continuing.prefix(3), id: \.key) { SavedMovieRow(entry: $0) }
                        if continuing.count > 3 {
                            NavigationLink("See All", destination: SavedMoviesView(collection: .continueWatching))
                                .frame(minHeight: 44)
                        }
                    }
                }
                Section {
                    SavedCollectionLinks()
                }
                if app.userLibrary.entries.isEmpty {
                    Text("Your favorites and movies you watch appear here.")
                        .foregroundStyle(.secondary)
                }
            } else {
                let matches = app.userLibrary.entries.values.filter { entry in
                    entry.matchesSavedSearch(query)
                }.sorted { $0.updatedAt > $1.updatedAt }
                if matches.isEmpty { Text("No matching saved movies").foregroundStyle(.secondary) }
                ForEach(matches, id: \.key) { SavedMovieRow(entry: $0) }
            }
        }
        .navigationTitle("My Movies")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search saved movies")
        .safeAreaInset(edge: .bottom) { UserLibraryRecoveryView() }
    }
}

struct SavedMoviesView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let collection: SavedCollection
    var offlineOnly = false
    @State private var query = ""

    var body: some View {
        Group {
            if app.userLibrary.isRestoring {
                ProgressView("Loading saved library…")
            } else if collection == .history {
                historyList
            } else if entries.isEmpty {
                emptyCollection
            } else {
                List(entries, id: \.key) { entry in SavedMovieRow(entry: entry) }
            }
        }
        .navigationTitle(collection.title)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(collection.title.lowercased())")
        .safeAreaInset(edge: .bottom) { UserLibraryRecoveryView() }
    }

    private var entries: [UserLibraryEntry] {
        app.savedEntries(collection, offlineOnly: offlineOnly).filter { $0.matchesSavedSearch(query) }
    }
    private var history: [ViewingHistoryEntry] {
        app.savedHistory(offlineOnly: offlineOnly).filter {
            query.isEmpty || $0.movie.matchesSavedSearch(query)
        }
    }
    @ViewBuilder private var historyList: some View {
        if history.isEmpty { emptyCollection }
        else {
            List(history, id: \.key) { viewing in
                let entry = app.userLibrary.entry(for: viewing.key)
                    ?? UserLibraryEntry(key: viewing.key, movie: viewing.movie, progress: nil,
                                        lastStartedAt: viewing.startedAt, lastCompletedAt: viewing.completedAt, updatedAt: viewing.startedAt)
                SavedMovieRow(entry: entry, viewing: viewing)
            }
        }
    }
    private var emptyCollection: some View {
        ContentUnavailableView {
            Label(collection.title, systemImage: collection.icon)
        } description: {
            Text(!query.isEmpty ? "No saved movies match your search."
                 : collection == .favorites ? "Add favorites from a movie’s actions menu."
                 : collection == .history ? "Movies appear here when you start watching."
                 : "Movies you have started will be ready to resume here.")
        } actions: {
            if !query.isEmpty {
                SavedSearchReset(query: $query)
            } else {
                Button {
                    dismiss()
                    app.selectedTab = .library
                } label: {
                    Text("Browse Movies").frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("ActionFill"))
            }
        }
    }
}

private struct SavedSearchReset: View {
    @Binding var query: String
    @Environment(\.dismissSearch) private var dismissSearch
    var body: some View {
        Button("Clear Search") { query = ""; dismissSearch() }.frame(minHeight: 44)
    }
}

struct ContinueWatchingPreview: View {
    @EnvironmentObject private var app: AppModel
    var offlineOnly = false

    var body: some View {
        let entries = app.savedEntries(.continueWatching, offlineOnly: offlineOnly)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                NavigationLink {
                    SavedMoviesView(collection: .continueWatching, offlineOnly: offlineOnly)
                } label: {
                    HStack {
                        Text("Continue Watching").font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                        Spacer()
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }.frame(minHeight: 44)
                }
                .accessibilityIdentifier("collection-continue")
                .buttonStyle(.borderless)
                if let latest = entries.first {
                    SavedMovieRow(entry: latest)
                        .padding(12)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("continue-watching-preview")
                }
            }
        }
    }
}

private extension UserLibraryEntry {
    func matchesSavedSearch(_ query: String) -> Bool {
        query.isEmpty || movie?.matchesSavedSearch(query) == true
    }
}

private extension MovieMetadata {
    func matchesSavedSearch(_ query: String) -> Bool {
        [displayTitle, summary ?? "", genre ?? ""].contains { $0.localizedStandardContains(query) }
    }
}

struct SavedCollectionLinks: View {
    var offlineOnly = false
    var body: some View {
        ForEach([SavedCollection.favorites, .history]) { collection in
            NavigationLink {
                SavedMoviesView(collection: collection, offlineOnly: offlineOnly)
            } label: { Label(collection.title, systemImage: collection.icon) }
                .accessibilityIdentifier("collection-\(collection.id)")
        }
    }
}

struct SavedMovieRow: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: UserLibraryEntry
    var viewing: ViewingHistoryEntry? = nil
    @State private var playTask: Task<Void, Never>?
    @State private var isLoading = false
    @State private var error: UserFacingError?
    @State private var submittedIdentity: UUID?
    @State private var pendingDeletion: DownloadRecord?

    private var record: DownloadRecord? { app.bestReadyRecord(for: entry.key) }
    private var movie: MovieMetadata? { record?.movieMetadata ?? entry.movie ?? app.movieCache.movie(for: entry.key) }
    private var canPlay: Bool { record != nil || app.owns(entry.key) }
    private var resume: Double? { app.savedResumePosition(for: entry.key) }
    private var isBusy: Bool { isLoading || (submittedIdentity == app.player.requestIdentity && (app.player.isSavingStartOver || app.player.isLoadingSavedPosition)) }
    private var title: String { movie?.displayTitle ?? "Saved movie" }
    private var playbackActionTitle: String {
        isBusy ? "Opening…" : rowError != nil ? "Retry" : resume == nil ? "Play" : "Resume"
    }
    private var rowError: UserFacingError? {
        error ?? (submittedIdentity == app.player.requestIdentity ? app.player.requestError.map { UserFacingError(category: .other, message: $0) } : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                SavedMovieDestination(key: entry.key, movie: movie)
            } label: {
                HStack(spacing: 12) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        PosterFrame {
                            if let record { LocalArtworkView(url: app.downloads.artworkURL(for: record)) }
                            else { AuthenticatedArtworkView(path: app.owns(entry.key) ? movie?.remoteArtworkPath : nil, client: app.client) }
                        }.frame(width: 56)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(summary).font(.subheadline)
                            .foregroundStyle(rowError == nil ? Color.secondary : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }.buttonStyle(.borderless)
            CollectionActionRow {
                primaryAction
            } secondary: {
                actionMenu
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("saved-movie-\(entry.key.mediaID)")
        .onDisappear { playTask?.cancel(); isLoading = false }
        .alert("Delete offline copy?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let selected = pendingDeletion { app.downloads.delete(selected) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The download is removed from this device. Your favorite and viewing history are kept.")
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if canPlay {
            Button { play(.resume) } label: {
                Label(playbackActionTitle, systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.borderless)
                .disabled(isBusy)
                .accessibilityIdentifier("resume-saved-\(entry.key.mediaID)")
                .accessibilityLabel("\(playbackActionTitle) \(title)")
        } else {
            Button { app.showingConnection = true } label: {
                Label("Connect", systemImage: "network").labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.borderless)
        }
    }

    private var actionMenu: some View {
        Menu {
            if canPlay, resume != nil {
                Button("Start Over", systemImage: "arrow.counterclockwise") { play(.startOver) }
                    .disabled(isBusy)
                    .accessibilityIdentifier("start-over-saved-\(entry.key.mediaID)")
            }
            Button(entry.isFavorite ? "Remove Favorite" : "Add Favorite", systemImage: entry.isFavorite ? "heart.slash" : "heart") {
                app.userLibrary.setFavorite(!entry.isFavorite, movie: movie, for: entry.key)
            }
            if resume != nil {
                Button("Remove from Continue Watching") { app.userLibrary.removeFromContinueWatching(for: entry.key) }
                    .accessibilityIdentifier("remove-continue-\(entry.key.mediaID)")
            }
            if let rowError {
                ForEach(rowError.recoveryActions().filter { $0 != .retry }) { action in
                    Button(action.title, systemImage: action.systemImage) { app.performRecovery(action) }
                }
            }
            if let record {
                Button("Delete Download", systemImage: "trash", role: .destructive) { pendingDeletion = record }
                    .accessibilityIdentifier("delete-saved-download-\(record.id.uuidString)")
            }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("saved-actions-\(entry.key.mediaID)")
            .accessibilityLabel("Actions for \(title)")
    }

    private var summary: String {
        if let rowError { return rowError.title }
        if let viewing {
            let date = viewing.startedAt.formatted(.dateTime.month(.abbreviated).day())
            return "\(viewing.completedAt == nil ? "Started" : "Watched") · \(date)"
        }
        if !canPlay { return "Reconnect to watch" }
        if let remaining = app.timeRemaining(for: entry.key, duration: movie?.durationSeconds) { return remaining }
        if let duration = app.savedDuration(for: entry.key, fallback: movie?.durationSeconds), duration.isFinite, duration > 0 {
            return "\(max(1, Int(ceil(duration / 60)))) min"
        }
        return record == nil ? "In your library" : "Saved offline"
    }

    private func play(_ start: PlaybackStart) {
        playTask?.cancel()
        isLoading = true
        error = nil
        playTask = Task {
            defer { isLoading = false }
            do {
                try await app.playSaved(entry.key, start: start)
                submittedIdentity = app.player.requestIdentity
            }
            catch { if !Task.isCancelled { self.error = UserFacingError(error) } }
        }
    }
}

private struct SavedMovieDestination: View {
    @EnvironmentObject private var app: AppModel
    let key: MovieLibraryKey
    let movie: MovieMetadata?
    var body: some View {
        if let record = app.bestReadyRecord(for: key) { MovieDetailView(record: record) }
        else if app.owns(key) { MovieDetailView(mediaID: key.mediaID, title: movie?.displayTitle ?? "Saved movie") }
        else {
            ContentUnavailableView {
                Label(movie?.displayTitle ?? "Saved movie", systemImage: "film")
            } description: {
                Text("Connect to this movie’s server and account to watch.")
            } actions: {
                Button { app.showingConnection = true } label: {
                    Text("Connect").frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("ActionFill"))
            }
        }
    }
}

/// Give the main action its natural text width before placing the compact menu.
/// Narrow windows can move the menu below without shrinking or splitting words.
struct CollectionActionRow<Primary: View, Secondary: View>: View {
    let primary: Primary
    let secondary: Secondary

    init(@ViewBuilder primary: () -> Primary, @ViewBuilder secondary: () -> Secondary) {
        self.primary = primary()
        self.secondary = secondary()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                primary
                secondary
            }
            VStack(alignment: .leading, spacing: 4) {
                primary
                HStack {
                    Spacer(minLength: 0)
                    secondary
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct UserLibraryRecoveryView: View {
    @EnvironmentObject private var app: AppModel
    @State private var isRetrying = false

    var body: some View {
        if app.userLibrary.persistenceError != nil {
            RecoveryBanner("Changes not saved", identifier: "user-library-recovery") { action in
                if let error = app.userLibrary.persistenceError {
                    ErrorRecoveryView(error: UserFacingError(error), isRetrying: isRetrying,
                                      recoveryAction: action, retry: retry)
                }
            }
        }
    }

    private func retry() {
        guard !isRetrying else { return }
        isRetrying = true
        Task {
            do { try await app.userLibrary.flush() }
            catch { /* flush retains the current failure for this recovery sheet. */ }
            isRetrying = false
        }
    }
}
