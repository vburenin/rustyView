import SwiftUI

struct TVMyMoviesView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            if app.userLibrary.isRestoring {
                ProgressView("Loading your movies…")
            } else if app.userLibrary.entries.isEmpty {
                VStack(spacing: 40) {
                    ContentUnavailableView {
                        Label("My Movies", systemImage: "heart")
                    } description: {
                        Text("Favorites and movies you watch appear here.")
                    } actions: {
                        Button("Browse Movies") { app.selectedTab = .library }
                    }
                    TVUserLibraryRecoveryBanner()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 64) {
                        TVUserLibraryRecoveryBanner()
                        TVSavedShelf(title: "Continue Watching", entries: app.savedEntries(.continueWatching),
                                     selectResumes: true, identifier: "continue")
                        TVSavedShelf(title: "Favorites", entries: app.savedEntries(.favorites), identifier: "favorites")
                        TVSavedShelf(title: "History", entries: history, identifier: "history")
                        Text("Favorites, history and resume positions are kept on this Apple TV. tvOS may clear them when it needs storage.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 60)
                }
            }
        }
    }

    /// History shows each movie's latest viewing once, newest first.
    private var history: [UserLibraryEntry] {
        app.savedHistory().map { viewing in
            app.userLibrary.entry(for: viewing.key)
                ?? UserLibraryEntry(key: viewing.key, movie: viewing.movie, progress: nil,
                                    lastStartedAt: viewing.startedAt, lastCompletedAt: viewing.completedAt,
                                    updatedAt: viewing.startedAt)
        }
    }
}

/// The Library tab's shortcut back into unfinished movies.
struct TVContinueWatchingShelf: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let entries = app.savedEntries(.continueWatching)
        if !entries.isEmpty {
            TVSavedShelf(title: "Continue Watching", entries: Array(entries.prefix(12)),
                         selectResumes: true, identifier: "library-continue")
        }
    }
}

struct TVSavedShelf: View {
    let title: String
    let entries: [UserLibraryEntry]
    var selectResumes = false
    let identifier: String

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                Text(title).font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 48) {
                        ForEach(entries, id: \.key) { entry in
                            TVSavedTile(entry: entry, selectResumes: selectResumes)
                                .frame(width: TVLayout.shelfPosterWidth)
                        }
                    }
                    .padding(.vertical, 24)
                }
                .scrollClipDisabled()
            }
            .focusSection()
            .accessibilityIdentifier("collection-\(identifier)")
        }
    }
}

struct TVSavedTile: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.tvNavigate) private var navigate
    let entry: UserLibraryEntry
    var selectResumes = false
    @State private var playTask: Task<Void, Never>?
    @State private var isOpening = false

    private var movie: MovieMetadata? { entry.movie ?? app.movieCache.movie(for: entry.key) }
    private var title: String { movie?.displayTitle ?? "Saved movie" }
    private var owned: Bool { app.owns(entry.key) }
    private var resume: Double? { app.savedResumePosition(for: entry.key) }
    private var route: TVRoute {
        .movie(movie ?? MovieMetadata(mediaID: entry.key.mediaID, title: title), key: entry.key)
    }

    var body: some View {
        TVPosterCell(title: title, detail: detail) {
            Group {
                if selectResumes && owned {
                    Button { play(.resume) } label: { artwork }
                } else {
                    NavigationLink(value: route) { artwork }
                }
            }
            .buttonStyle(.card)
            .disabled(isOpening)
            .accessibilityLabel(selectResumes && owned ? "Resume \(title)" : title)
            .accessibilityValue(detail)
            .accessibilityIdentifier("saved-movie-\(entry.key.mediaID)")
            .contextMenu { actions }
        }
        .onDisappear { playTask?.cancel(); isOpening = false }
    }

    private var artwork: some View {
        TVPosterArtwork(artworkPath: owned ? movie?.remoteArtworkPath : nil, progress: progress)
            .overlay {
                if isOpening { ProgressView().padding(24).background(.black.opacity(0.6), in: Circle()) }
            }
    }

    @ViewBuilder
    private var actions: some View {
        if owned {
            Button(resume == nil ? "Play" : "Resume", systemImage: "play.fill") { play(.resume) }
            if resume != nil {
                Button("Start Over", systemImage: "arrow.counterclockwise") { play(.startOver) }
            }
        }
        if selectResumes {
            Button("Movie Details", systemImage: "info.circle") { navigate(route) }
        }
        Button(entry.isFavorite ? "Remove from Favorites" : "Add to Favorites",
               systemImage: entry.isFavorite ? "heart.slash" : "heart") {
            app.userLibrary.setFavorite(!entry.isFavorite, movie: movie, for: entry.key)
        }
        if resume != nil {
            Button("Remove from Continue Watching", systemImage: "eye.slash") {
                app.userLibrary.removeFromContinueWatching(for: entry.key)
            }
        }
    }

    private var progress: Double? {
        guard let position = resume,
              let duration = app.savedDuration(for: entry.key, fallback: movie?.durationSeconds),
              duration.isFinite, duration > 0 else { return nil }
        return position / duration
    }

    private var detail: String {
        if !owned { return "Reconnect to watch" }
        if let remaining = app.timeRemaining(for: entry.key, duration: movie?.durationSeconds) { return remaining }
        if entry.lastCompletedAt != nil { return "Watched" }
        if let duration = app.savedDuration(for: entry.key, fallback: movie?.durationSeconds),
           duration.isFinite, duration > 0 {
            return "\(max(1, Int(ceil(duration / 60)))) min"
        }
        return ""
    }

    private func play(_ start: PlaybackStart) {
        playTask?.cancel()
        isOpening = true
        playTask = Task {
            defer { isOpening = false }
            do { try await app.playSaved(entry.key, start: start) }
            catch { if !Task.isCancelled { app.report(error) } }
        }
    }
}
