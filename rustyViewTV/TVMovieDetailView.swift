import SwiftUI

struct TVMovieDetailView: View {
    @EnvironmentObject private var app: AppModel
    let savedKey: MovieLibraryKey?

    @State private var movie: MovieMetadata
    @State private var item: MediaItem?
    @State private var loadedConnection: ServerConnection?
    @State private var qualityProfiles: [QualityProfile]?
    @State private var isLoading = false
    @State private var loadError: UserFacingError?
    @State private var selectedAudio = 0
    @State private var selectedQuality = "auto"
    @State private var qualityNotice: String?
    @State private var loadRequest = UUID()
    @State private var showingSummary = false
    @State private var choosing: Choice?
    @FocusState private var watchFocused: Bool

    private enum Choice: String, Identifiable { case audio, quality; var id: String { rawValue } }

    init(movie: MovieMetadata, savedKey: MovieLibraryKey? = nil) {
        self.savedKey = savedKey
        _movie = State(initialValue: movie)
    }

    private var mediaID: String { movie.mediaID }

    var body: some View {
        Group {
            if let savedKey, !app.owns(savedKey) {
                ContentUnavailableView {
                    Label(movie.displayTitle, systemImage: "film")
                } description: {
                    Text("Connect to this movie’s server and account to watch.")
                } actions: {
                    Button("Connect") { app.showingConnection = true }
                }
            } else {
                ScrollView { detail.padding(.bottom, 60) }
            }
        }
        .task(id: "\(mediaID)|\(app.client.connection?.serverIdentity ?? "")|\(app.client.connection?.username ?? "")") {
            await resolve()
        }
        .onDisappear { loadRequest = UUID() }
        .onChange(of: app.playbackPreferences.preferredQualityID) { _, _ in resolveQualityPreference() }
        .sheet(isPresented: $showingSummary) { summarySheet }
        .sheet(item: $choosing) { choice in
            NavigationStack {
                switch choice {
                case .audio: audioChoices
                case .quality: qualityChoices
                }
            }
        }
    }

    private var detail: some View {
        HStack(alignment: .top, spacing: 72) {
            TVPosterArtwork(artworkPath: movie.remoteArtworkPath)
                .frame(width: 420)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(movie.displayTitle).font(.title2.bold()).lineLimit(3)
                        .accessibilityIdentifier("detail-title")
                    metadataLine
                    if let remaining { Text(remaining).font(.callout).foregroundStyle(.secondary) }
                }

                primaryActions.focusSection()

                if let item, !item.audioTracks.isEmpty || !(qualityProfiles ?? []).isEmpty {
                    streamingChoices(item).focusSection()
                }
                if let qualityNotice {
                    Text(qualityNotice).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("quality-preference-notice")
                }
                status

                if let summary = movie.summary, !summary.isEmpty {
                    Button { showingSummary = true } label: {
                        Text(summary).font(.callout).lineLimit(4).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the full description")
                }

                if !movie.chapters.isEmpty { chapters }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 20)
    }

    private var metadataLine: some View {
        let parts = [
            movie.durationSeconds.map { PlaybackTimeline.displayTime($0) },
            movie.resolution,
            movie.hdr.flatMap { $0.isEmpty || $0.lowercased() == "sdr" ? nil : $0.uppercased() },
            movie.genre.flatMap { $0.isEmpty ? nil : $0 },
        ].compactMap { $0 }
        return Text(parts.joined(separator: "  ·  ")).font(.callout).foregroundStyle(.secondary)
    }

    private var primaryActions: some View {
        HStack(spacing: 32) {
            Button { watch(.resume) } label: {
                Label(resumePosition == nil ? "Watch" : "Resume", systemImage: "play.fill")
                    .frame(minWidth: 220)
            }
            .focused($watchFocused)
            .disabled(!canWatch)
            .accessibilityLabel(watchLabel)
            .accessibilityIdentifier("detail-watch")

            if resumePosition != nil {
                Button { watch(.startOver) } label: {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                }
                .disabled(!canWatch)
                .accessibilityIdentifier("detail-start-over")
            }

            if let libraryKey {
                let favorite = app.userLibrary.isFavorite(for: libraryKey)
                Button {
                    app.userLibrary.toggleFavorite(key: libraryKey, movie: movie)
                } label: {
                    Label(favorite ? "Favorite" : "Add to Favorites", systemImage: favorite ? "heart.fill" : "heart")
                }
                .accessibilityLabel(favorite ? "Remove from Favorites" : "Add to Favorites")
                .accessibilityIdentifier("detail-favorite")
            }
        }
        .defaultFocus($watchFocused, true)
    }

    private func streamingChoices(_ item: MediaItem) -> some View {
        HStack(spacing: 32) {
            if !item.audioTracks.isEmpty {
                Button { choosing = .audio } label: {
                    Label("Audio: \(selectedAudioLabel(item))", systemImage: "waveform")
                }
                .accessibilityIdentifier("detail-audio")
            }
            if let profiles = qualityProfiles, !profiles.isEmpty {
                Button { choosing = .quality } label: {
                    Label("Quality: \(selectedQualityLabel)", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("detail-quality")
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if app.player.isSavingStartOver { ProgressView("Saving Start Over…") }
        if app.player.isLoadingSavedPosition { ProgressView("Restoring saved position…") }
        if isLoading { ProgressView("Loading movie…") }
        if let requestError = app.player.requestError, !app.player.isPresented {
            HStack(spacing: 24) {
                Label(requestError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                Button("Dismiss") { app.player.requestError = nil }
            }
        }
        if let loadError {
            TVErrorRecoveryView(error: loadError, isRetrying: isLoading) { Task { await load() } }
        }
    }

    private var chapters: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Chapters").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    ForEach(movie.chapters) { chapter in
                        Button { watch(.position(chapter.startSeconds)) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(chapter.title).lineLimit(2)
                                Text(PlaybackTimeline.displayTime(chapter.startSeconds))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: 320, alignment: .leading)
                        }
                        .disabled(!canWatch)
                        .accessibilityIdentifier("detail-chapter-\(chapter.id)")
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    private var summarySheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(movie.displayTitle).font(.title3.bold())
                // A focusable body lets the Siri Remote scroll long text.
                Text(movie.summary ?? "").focusable()
            }
            .frame(maxWidth: 1200)
            .padding(60)
        }
    }

    private var audioChoices: some View {
        let tracks = item?.audioTracks ?? []
        return TVChoiceList(title: "Audio", options: tracks.map { track in
            TVChoice(value: track.index, title: track.displayName,
                     subtitle: track.technicalLabel + (track.default || track.index == item?.defaultAudioIndex ? " · Default" : ""),
                     identifier: "server-audio-\(track.index)")
        }, selection: selectedAudio) { index in
            selectedAudio = index
            if let language = tracks.first(where: { $0.index == index })?.language {
                app.playbackPreferences.preferredAudioLanguage = language
            }
        }
    }

    private var qualityChoices: some View {
        TVChoiceList(title: "Quality", options: (qualityProfiles ?? []).map {
            TVChoice(value: $0.id, title: $0.label, identifier: "quality-\($0.id)")
        }, selection: selectedQuality, footer: "Lower quality uses less data. Your choice applies to future movies too.") { quality in
            selectedQuality = quality
            qualityNotice = nil
            app.playbackPreferences.preferredQualityID = quality
        }
    }

    // MARK: Loading

    private func resolve() async {
        if let savedKey, !app.owns(savedKey) { return }
        if let cached = app.cachedMovie(mediaID: mediaID) { movie = cached }
        await app.movieCache.waitUntilRestored()
        guard !Task.isCancelled else { return }
        if let cached = app.cachedMovie(mediaID: mediaID) { movie = cached }
        await load()
    }

    private func load() async {
        let request = UUID()
        loadRequest = request
        isLoading = true
        loadError = nil
        defer { if request == loadRequest { isLoading = false } }
        do {
            let owner = try app.client.ownedConnection()
            let connection = owner.connection
            let capabilities: ServerCapabilities
            if let available = app.library.capabilities { capabilities = available }
            else { capabilities = try await owner.library(LibraryRequest(limit: 1)).capabilities }
            guard isCurrent(request, connection) else { return }
            let loaded = try await owner.item(id: mediaID)
            guard isCurrent(request, connection) else { return }
            item = loaded
            movie = MovieMetadata(item: loaded)
            if let connection { app.cacheMovie(loaded, connection: connection) }
            loadedConnection = connection
            qualityProfiles = capabilities.qualityProfiles
            selectedAudio = app.playbackPreferences.audioIndex(in: loaded)
            resolveQualityPreference()
        } catch is CancellationError {
            return
        } catch {
            guard request == loadRequest, !Task.isCancelled else { return }
            loadError = UserFacingError(error)
        }
    }

    private func isCurrent(_ request: UUID, _ connection: ServerConnection?) -> Bool {
        request == loadRequest && !Task.isCancelled
            && app.client.connection?.serverIdentity == connection?.serverIdentity
            && app.client.connection?.username == connection?.username
    }

    private func resolveQualityPreference() {
        guard let qualityProfiles else { return }
        let resolution = app.playbackPreferences.quality(in: qualityProfiles)
        selectedQuality = resolution.qualityID
        qualityNotice = resolution.notice
    }

    // MARK: Playback

    private var hasLoadedOnlineOwnership: Bool {
        guard let loadedConnection else { return false }
        return app.client.connection?.serverIdentity == loadedConnection.serverIdentity
            && app.client.connection?.username == loadedConnection.username
    }

    private var canWatch: Bool {
        !app.player.isSavingStartOver && !app.player.isLoadingSavedPosition && item != nil && hasLoadedOnlineOwnership
    }

    private var resumePosition: Double? { item.flatMap { app.player.resumePosition(for: $0) } }

    private var remaining: String? {
        guard let position = resumePosition, let total = movie.durationSeconds, total > position else { return nil }
        return "\(max(1, Int(ceil((total - position) / 60)))) min left"
    }

    private var libraryKey: MovieLibraryKey? {
        guard let connection = loadedConnection ?? app.client.connection else { return nil }
        return MovieLibraryKey(connection: connection, mediaID: mediaID)
    }

    private var watchLabel: String {
        resumePosition.map { "Resume at \(PlaybackTimeline.displayTime($0))" } ?? "Watch"
    }

    private var selectedQualityLabel: String {
        if selectedQuality == "auto" { return "Auto" }
        return qualityProfiles?.first { $0.id == selectedQuality }?.label.components(separatedBy: " · ").first ?? "Auto"
    }

    private func selectedAudioLabel(_ item: MediaItem) -> String {
        guard let track = item.audioTracks.first(where: { $0.index == selectedAudio }),
              track.displayName.uppercased() != "UND" else { return "Default" }
        return track.displayName
    }

    private func watch(_ start: PlaybackStart) {
        guard let item, let loadedConnection, canWatch else { return }
        app.player.play(.online(item: item, connection: loadedConnection, start: start,
                                quality: selectedQuality, audioIndex: selectedAudio,
                                qualityNotice: qualityNotice, qualityProfiles: qualityProfiles))
    }
}
