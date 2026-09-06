import SwiftUI

struct MovieDetailView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    let mediaID: String
    let initialTitle: String
    private let initialRecord: DownloadRecord?

    @State private var item: MediaItem?
    @State private var movie: MovieMetadata
    @State private var localRecord: DownloadRecord?
    @State private var viewingOnline = false
    @State private var loadedConnection: ServerConnection?
    @State private var loadedQualityProfiles: [QualityProfile]?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadError: UserFacingError?
    @State private var selectedAudio = 0
    @State private var selectedQuality = "auto"
    @State private var qualityNotice: String?
    @State private var pendingDownloadDeletion: DownloadRecord?
    @State private var loadRequest = UUID()
    @State private var showingDownloadChoices = false
    @State private var deletingRecordID: UUID?
    @State private var managingCopies: MovieLibraryKey?
    @State private var pendingCopyPlayback: DownloadRecord?

    init(entry: LibraryEntry) {
        mediaID = entry.id
        initialTitle = entry.displayTitle
        initialRecord = nil
        _movie = State(initialValue: MovieMetadata(entry: entry))
    }

    init(mediaID: String, title: String) {
        self.mediaID = mediaID
        initialTitle = DisplayTitle.clean(title)
        initialRecord = nil
        _movie = State(initialValue: MovieMetadata(mediaID: mediaID, title: title))
    }

    init(record: DownloadRecord) {
        mediaID = record.mediaID
        initialTitle = record.displayTitle
        initialRecord = record
        _movie = State(initialValue: record.movieMetadata)
        _localRecord = State(initialValue: record)
    }

    private var usesCompactHeader: Bool {
        horizontalSizeClass == .compact && !dynamicTypeSize.isAccessibilitySize
    }

    private var availableLocalRecord: DownloadRecord? {
        localRecord ?? initialRecord ?? app.downloads.record(for: mediaID)
    }

    var body: some View {
        ScrollView {
            detail
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(initialTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: mediaID) { await resolveInitialSource() }
        .onDisappear { loadRequest = UUID() }
        .onChange(of: app.playbackPreferences.preferredQualityID) { _, _ in resolveQualityPreference() }
        .onChange(of: app.downloads.completed) { _, records in
            if let deletingRecordID, !records.contains(where: { $0.id == deletingRecordID }) { dismiss() }
            if let current = localRecord, let updated = records.first(where: { $0.id == current.id }) { localRecord = updated }
        }
        .sheet(isPresented: $showingDownloadChoices) {
            if let item {
                NavigationStack {
                    List {
                        downloadChoice(item, kind: .compatible)
                        downloadChoice(item, kind: .original)
                    }
                    .navigationTitle("Download")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showingDownloadChoices = false } } }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { managingCopies != nil }, set: { if !$0 { managingCopies = nil } }
        ), onDismiss: {
            if let record = pendingCopyPlayback {
                pendingCopyPlayback = nil
                app.playOffline(record)
            }
            if let record = localRecord, !app.downloads.completed.contains(where: { $0.id == record.id }) {
                localRecord = app.bestReadyRecord(for: app.key(for: record))
                if localRecord == nil && !viewingOnline { dismiss() }
            }
        }) {
            if let key = managingCopies {
                DownloadCopiesView(key: key) { pendingCopyPlayback = $0 }
            }
        }
        .alert("Remove offline copy?", isPresented: Binding(
            get: { pendingDownloadDeletion != nil },
            set: { if !$0 { pendingDownloadDeletion = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let record = pendingDownloadDeletion {
                    deletingRecordID = record.id
                    app.downloads.delete(record)
                }
                pendingDownloadDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDownloadDeletion = nil }
        } message: {
            Text("The movie will remain on the server.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: usesCompactHeader ? 16 : 24) {
            detailHeader

            controls

            if let requestError = app.player.requestError, !app.player.isPresented {
                Label(requestError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                Button("Dismiss") { app.player.requestError = nil }
            }

            if isLoading { ProgressView("Loading online options…") }
            if let loadError {
                ErrorRecoveryView(error: loadError, retry: { Task { await load() } })
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                Button("Try Again") { Task { await load() } }
            }

            if let about = movie.summary, !about.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About").font(.title2.bold())
                    Text(about).font(.body).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !movie.chapters.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(movie.chapters) { chapter in
                            Button {
                                watch(start: .position(chapter.startSeconds))
                            } label: {
                                Group {
                                    if dynamicTypeSize.isAccessibilitySize {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(chapter.title).fixedSize(horizontal: false, vertical: true)
                                            Text(Self.time(chapter.startSeconds)).font(.caption)
                                                .foregroundStyle(Color.primary.opacity(0.75))
                                        }
                                    } else {
                                        HStack {
                                            Text(chapter.title).multilineTextAlignment(.leading)
                                            Spacer()
                                            Text(Self.time(chapter.startSeconds))
                                                .foregroundStyle(Color.primary.opacity(0.75)).fixedSize()
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!canWatch)
                            .accessibilityIdentifier("detail-chapter-\(chapter.id)")
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    Text("Chapters (\(movie.chapters.count))").frame(minHeight: 44)
                }
                .font(.headline)
            }
        }
        .padding()
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var detailHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    artwork(maxWidth: 64).frame(width: 64)
                    Text(movie.displayTitle).font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("detail-title")
                }
                summary(compact: true, showsTitle: false)
            }
        } else if usesCompactHeader {
            HStack(alignment: .top, spacing: 16) {
                artwork(maxWidth: 108)
                    .frame(width: 108)
                summary(compact: true)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    artwork(maxWidth: 300)
                    summary(compact: false)
                }
                VStack(alignment: .leading, spacing: 20) {
                    artwork(maxWidth: 300)
                    summary(compact: false)
                }
            }
        }
    }

    private func artwork(maxWidth: CGFloat) -> some View {
        PosterFrame {
            if !viewingOnline || (availableLocalRecord != nil && !hasLoadedOnlineOwnership) {
                LocalArtworkView(url: availableLocalRecord.flatMap { app.downloads.artworkURL(for: $0) })
            } else {
                AuthenticatedArtworkView(path: movie.remoteArtworkPath, client: app.client)
            }
        }
            .frame(maxWidth: maxWidth)
            .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
    }

    private func summary(compact: Bool, showsTitle: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            if showsTitle {
                Text(movie.displayTitle)
                    .font(compact ? .title3.bold() : .largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits {
                HStack(spacing: 8) { metadataPills }
                VStack(alignment: .leading, spacing: 8) { metadataPills }
            }
            if let genre = movie.genre, !genre.isEmpty {
                Text(genre).foregroundStyle(Color(uiColor: .label))
            }
            if let size = movie.sourceSizeBytes {
            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .foregroundStyle(Color(uiColor: .label))
                .accessibilityIdentifier("media-file-size")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var metadataPills: some View {
        if let duration = movie.durationSeconds { MetadataPill(text: PlaybackTimeline.displayTime(duration)) }
        if let resolution = movie.resolution { MetadataPill(text: resolution) }
        if let hdr = movie.hdr, hdr.lowercased() != "sdr" { MetadataPill(text: hdr.uppercased()) }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if localRecord != nil {
                Picker("Playback source", selection: Binding(get: { viewingOnline }, set: chooseSource)) {
                    Text("On This Device").tag(false)
                    Text("Online").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("detail-playback-source")
            }
            HStack(spacing: 8) {
                Button { watch(start: .resume) } label: {
                    Label(resumePosition == nil ? "Watch" : "Resume", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("ActionFill"))
                .disabled(!canWatch)
                .accessibilityLabel(watchLabel)
                movieActions
            }

            if app.player.isSavingStartOver { ProgressView("Saving Start Over…") }
            if app.player.isLoadingSavedPosition { ProgressView("Restoring saved position…") }

            if let position = resumePosition, let total = playbackDuration, total > position {
                Text("\(max(1, Int(ceil((total - position) / 60)))) min left")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if viewingOnline, let item {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 12) {
                        audioPicker(item)
                        qualityPicker
                    }
                } else {
                    HStack(spacing: 12) {
                        audioPicker(item)
                        qualityPicker
                    }
                }
            }

            if let qualityNotice { Text(qualityNotice).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("quality-preference-notice") }

            downloadControl(item)
            } else if let record = localRecord {
                savedCopySummary(record)
                if !record.isReadyToWatch {
                    Text(record.validationMessage ?? record.readinessMessage).font(.callout)
                    Button("Try Offline Playback") { app.playOffline(record, start: .resume) }
                    Button("Online options") { chooseSource(true) }
                }
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var movieActions: some View {
        Menu {
            if resumePosition != nil {
                Button("Start Over", systemImage: "arrow.counterclockwise") { watch(start: .startOver) }
                    .disabled(!canWatch)
            }
            if let libraryKey {
                Button {
                    app.userLibrary.toggleFavorite(key: libraryKey, movie: movie)
                } label: {
                    Label(app.userLibrary.isFavorite(for: libraryKey) ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: app.userLibrary.isFavorite(for: libraryKey) ? "heart.fill" : "heart")
                }
                .accessibilityIdentifier("detail-favorite")
                .accessibilityValue(app.userLibrary.isFavorite(for: libraryKey) ? "Favorite" : "Not favorite")
            }
            if let record = localRecord ?? app.downloads.record(for: mediaID) {
                let key = app.key(for: record)
                let copies = DownloadMovieGroup.collect(records: app.downloads.completed, transfers: app.downloads.active)
                    .first { $0.key == key }?.copyCount ?? 0
                if viewingOnline, item != nil, hasLoadedOnlineOwnership {
                    Button("Download Another Copy", systemImage: "arrow.down.circle") { showingDownloadChoices = true }
                }
                if copies > 1 {
                    Button("Manage Copies", systemImage: "square.on.square") { managingCopies = key }
                } else {
                    Button("Remove Download", systemImage: "trash", role: .destructive) { pendingDownloadDeletion = record }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 22))
                .frame(width: 44, height: 48)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Movie actions")
        .accessibilityIdentifier("detail-actions")
    }

    private func savedCopySummary(_ record: DownloadRecord) -> some View {
        DisclosureGroup {
            downloadSelections(quality: record.videoQualityDescription, audio: record.audioSelectionDescription)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label("Copy details",
                      systemImage: record.isReadyToWatch ? "checkmark.circle" : "info.circle")
                Text(ByteCountFormatter.string(fromByteCount: record.packageStorageBytes ?? record.byteCount, countStyle: .file))
                    .font(.caption).foregroundStyle(Color.primary)
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("offline-copy-available")
        }
        .font(.subheadline)
    }

    private func audioPicker(_ item: MediaItem) -> some View {
        let selectedTrack = item.audioTracks.first { $0.index == selectedAudio }
        return Menu {
            Picker("Audio", selection: Binding(get: { selectedAudio }, set: { index in
                selectedAudio = index
                if let language = item.audioTracks.first(where: { $0.index == index })?.language {
                    app.playbackPreferences.preferredAudioLanguage = language
                }
            })) {
                ForEach(item.audioTracks) { track in
                    Text(track.selectionLabel(defaultIndex: item.defaultAudioIndex)).tag(track.index)
                }
            }
        } label: {
            selectionLabel(
                title: "Audio",
                value: selectedTrack.flatMap { $0.displayName.uppercased() == "UND" ? nil : $0.displayName } ?? "Default",
                systemImage: "waveform"
            )
        }
        .buttonStyle(.bordered)
        .disabled(item.audioTracks.isEmpty)
        .accessibilityLabel("Audio")
        .accessibilityValue(
            selectedTrack?.selectionLabel(defaultIndex: item.defaultAudioIndex) ?? "Default"
        )
    }

    private var qualityPicker: some View {
        Menu {
            Picker("Quality", selection: Binding(get: { selectedQuality }, set: { quality in
                selectedQuality = quality
                qualityNotice = nil
                app.playbackPreferences.preferredQualityID = quality
            })) {
                ForEach(loadedQualityProfiles ?? []) { profile in
                    Text(profile.label).tag(profile.id)
                }
            }
        } label: {
            selectionLabel(
                title: "Quality",
                value: selectedQuality == "auto" ? "Auto" : selectedQualityProfile?.label.components(separatedBy: " · ").first ?? selectedQuality,
                systemImage: "slider.horizontal.3"
            )
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Quality")
        .accessibilityValue(selectedQualityProfile?.label ?? "Auto")
    }

    @ViewBuilder
    private func downloadControl(_ item: MediaItem) -> some View {
        if let download = app.downloads.activeDownload(for: item.id) {
            let progress = DownloadProgressPresentation(phase: download.phase,
                preparation: app.downloads.preparationProgress(for: download))
            VStack(spacing: 8) {
                if let status = progress.activePreparation.map({ _ in "Preparing…" }) ?? downloadStatus(download) {
                    adaptiveDownloadRow {
                        Text(status)
                            .accessibilityIdentifier("detail-download-status-\(download.mediaID)")
                    } trailing: {
                        if let percent = progress.percent {
                            Text("\(percent)%")
                                .accessibilityIdentifier("detail-download-percent-\(download.mediaID)")
                        }
                    }
                }
                if let fraction = progress.fraction {
                    ProgressView(value: fraction).accessibilityHidden(true)
                } else if case .downloading = download.phase {
                    ProgressView()
                } else if download.phase == .finishing {
                    ProgressView()
                }
                if let preparation = progress.activePreparation {
                    Text("Prepared \(PlaybackTimeline.displayTime(preparation.producedSeconds)) of \(PlaybackTimeline.displayTime(preparation.totalSeconds))")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("detail-preparation-progress-\(download.mediaID)")
                        .accessibilityLabel(preparation.presentationText)
                }
                if let bytes = progress.byteText {
                    Text(bytes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("detail-download-bytes-\(download.mediaID)")
                }
                if case .failed(let message) = download.phase {
                    if let failure = download.failure {
                        ErrorRecoveryView(error: failure, retry: { app.downloads.retry(download) })
                    } else {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                    adaptiveDownloadRow {
                        if download.failure == nil {
                            Button { app.downloads.retry(download) } label: { downloadActionLabel("Retry Now") }
                        }
                    } trailing: {
                        Button(role: .destructive) {
                            app.downloads.dismissFailure(download)
                        } label: { downloadActionLabel("Remove from Queue") }
                    }
                    .font(.subheadline)
                    NavigationLink { DownloadsView() } label: { downloadActionLabel("Downloads") }
                        .font(.subheadline)
                } else if case .paused(let canResume) = download.phase {
                    if !canResume { Text("Resuming restarts this download.").font(.caption).foregroundStyle(.secondary) }
                    adaptiveDownloadRow {
                        Button { app.downloads.resume(download) } label: { downloadActionLabel("Resume") }
                            .accessibilityLabel("Resume Download")
                    } trailing: {
                        Button(role: .cancel) { app.downloads.cancel(download) } label: { downloadActionLabel("Cancel") }
                            .accessibilityLabel("Cancel Download")
                    }
                } else {
                    adaptiveDownloadRow {
                        if download.phase != .finishing && download.phase != .pausing {
                            Button { app.downloads.pause(download) } label: { downloadActionLabel("Pause") }
                                .accessibilityLabel("Pause Download")
                        }
                    } trailing: {
                        Button(role: .cancel) { app.downloads.cancel(download) } label: { downloadActionLabel("Cancel") }
                            .accessibilityLabel("Cancel Download")
                    }
                    .font(.subheadline)
                }
                DisclosureGroup {
                    downloadSelections(quality: download.metadata.videoQualityDescription, audio: download.metadata.audioSelectionDescription)
                } label: {
                    Text("Download details").frame(minHeight: 44)
                        .accessibilityIdentifier("active-download-details")
                }
                    .font(.subheadline)
            }
        } else if let record = app.downloads.record(for: item.id) {
            VStack(spacing: 10) {
                savedCopySummary(record)
                if !record.isReadyToWatch {
                    Text(record.validationMessage ?? record.readinessMessage)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let summary = DownloadOutputSummary(item: item, kind: .compatible, quality: selectedQuality,
                                                        profile: selectedQualityProfile, audioIndex: selectedAudio)
                    Text(summary.essential)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DisclosureGroup { outputFacts(item, kind: .compatible) } label: {
                        Text("Format details").frame(minHeight: 44)
                    }
                    .font(.subheadline)
                    Button("Download Compatible Copy") {
                        startDownload(item: item, kind: .compatible)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("ActionFill"))
                }
            }
        } else {
            Button { showingDownloadChoices = true } label: {
                Label("Download", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }

    private func adaptiveDownloadRow<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                leading().fixedSize(horizontal: true, vertical: true)
                Spacer(minLength: 8)
                trailing().fixedSize(horizontal: true, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                leading().fixedSize(horizontal: false, vertical: true)
                trailing().fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func downloadActionLabel(_ title: String) -> some View {
        Text(title)
            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func downloadChoice(_ item: MediaItem, kind: DownloadKind) -> some View {
        let summary = DownloadOutputSummary(item: item, kind: kind, quality: selectedQuality,
                                            profile: selectedQualityProfile, audioIndex: selectedAudio)
        return Section {
            Button {
                showingDownloadChoices = false
                startDownload(item: item, kind: kind)
            } label: {
                Text(kind == .compatible ? "Compatible copy" : "Original file")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .font(.headline)
            .accessibilityHint("Immediately adds this choice to Downloads")
            Text(summary.essential).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("download-summary-\(kind.rawValue)")
            DisclosureGroup { outputFacts(item, kind: kind) } label: {
                Text("Format details").fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                    .accessibilityLabel(kind == .compatible ? "Compatible format details" : "Original format details")
            }
                .font(.subheadline)
        }
    }

    private func outputFacts(_ item: MediaItem, kind: DownloadKind) -> some View {
        let summary = DownloadOutputSummary(item: item, kind: kind, quality: selectedQuality,
                                            profile: selectedQualityProfile, audioIndex: selectedAudio)
        return VStack(alignment: .leading, spacing: 8) {
            Text(summary.video)
            Text(summary.audio)
            Text(summary.subtitles)
            Text(summary.size).fontWeight(.semibold)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("download-format-\(kind.rawValue)")
    }

    private func chooseSource(_ online: Bool) {
        loadRequest = UUID()
        let request = loadRequest
        viewingOnline = online
        errorMessage = nil
        loadError = nil
        if online {
            Task {
                guard request == loadRequest, viewingOnline else { return }
                await load()
            }
        }
        else if let localRecord { movie = localRecord.movieMetadata; isLoading = false }
    }

    private func resolveInitialSource() async {
        let request = UUID()
        loadRequest = request
        let connection = app.client.connection
        // Keep already-owned details available immediately, including stored
        // originals that need an explicit choice of online recovery.
        if let initialRecord {
            localRecord = initialRecord
            movie = initialRecord.movieMetadata
            return
        }
        if let cached = app.cachedMovie(mediaID: mediaID) { movie = cached }
        await app.downloads.waitUntilRestored()
        guard request == loadRequest, !Task.isCancelled,
              app.client.connection?.serverIdentity == connection?.serverIdentity,
              app.client.connection?.username == connection?.username else { return }
        localRecord = app.downloads.record(for: mediaID)
        if let localRecord, localRecord.isReadyToWatch {
            movie = localRecord.movieMetadata
            viewingOnline = false
            return
        }
        await app.movieCache.waitUntilRestored()
        guard request == loadRequest, !Task.isCancelled,
              app.client.connection?.serverIdentity == connection?.serverIdentity,
              app.client.connection?.username == connection?.username else { return }
        if let cached = app.cachedMovie(mediaID: mediaID) { movie = cached }
        viewingOnline = true
        await load()
    }

    private func load() async {
        let request = UUID()
        loadRequest = request
        isLoading = true
        errorMessage = nil
        loadError = nil
        defer { if request == loadRequest { isLoading = false } }
        do {
            let owner = try app.client.ownedConnection()
            let connection = owner.connection
            if let record = localRecord, let connection,
               record.serverOrigin != connection.serverIdentity || record.accountUsername != connection.username {
                errorMessage = "Connect to the server and account that saved this movie to use its online options."
                return
            }
            let profiles: [QualityProfile]
            if let capabilities = app.library.capabilities { profiles = capabilities.qualityProfiles }
            else { profiles = try await owner.library(LibraryRequest(limit: 1)).capabilities.qualityProfiles }
            guard request == loadRequest, !Task.isCancelled, viewingOnline,
                  app.client.connection?.serverIdentity == connection?.serverIdentity,
                  app.client.connection?.username == connection?.username else { return }
            let loaded = try await owner.item(id: mediaID)
            guard request == loadRequest, !Task.isCancelled, viewingOnline,
                  app.client.connection?.serverIdentity == connection?.serverIdentity,
                  app.client.connection?.username == connection?.username else { return }
            item = loaded
            movie = MovieMetadata(item: loaded)
            if let connection { app.cacheMovie(loaded, connection: connection) }
            loadedConnection = connection
            loadedQualityProfiles = profiles
            selectedAudio = app.playbackPreferences.audioIndex(in: loaded)
            resolveQualityPreference()
        } catch is CancellationError {
            return
        } catch {
            guard request == loadRequest, !Task.isCancelled, viewingOnline else { return }
            loadError = UserFacingError(error)
        }
    }

    private func startDownload(item: MediaItem, kind: DownloadKind) {
        guard let loadedConnection,
              app.client.connection?.serverIdentity == loadedConnection.serverIdentity,
              app.client.connection?.username == loadedConnection.username else {
            errorMessage = "The connection changed. Reload online options before downloading."
            return
        }
        do {
            try app.downloads.start(
                item: item,
                kind: kind,
                client: app.client,
                quality: selectedQuality,
                qualityProfile: selectedQualityProfile,
                audioIndex: selectedAudio
            )
        } catch {
            app.report(error)
        }
    }

    private func downloadStatus(_ download: ActiveDownload) -> String? {
        switch download.phase {
        case .queued: "Queued"
        case .downloading: "Downloading…"
        case .retrying: "Retrying…"
        case .finishing: "Saving…"
        case .pausing: "Pausing…"
        case .paused: "Paused"
        case .waiting(let reason): reason.message
        case .failed: download.failure == nil ? "Download failed" : nil
        }
    }

    private var selectedQualityProfile: QualityProfile? {
        loadedQualityProfiles?.first { $0.id == selectedQuality }
    }

    private func resolveQualityPreference() {
        guard let loadedQualityProfiles else { return }
        let resolution = app.playbackPreferences.quality(in: loadedQualityProfiles)
        selectedQuality = resolution.qualityID
        qualityNotice = resolution.notice
    }

    private func selectionLabel(title: String, value: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color(uiColor: .label))
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .label))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: systemImage)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
    }

    private func downloadSelections(quality: String, audio: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Quality: \(quality)")
                .accessibilityIdentifier("active-download-quality")
            Text("Audio: \(audio)")
                .accessibilityIdentifier("active-download-audio")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canWatch: Bool {
        !app.player.isSavingStartOver && !app.player.isLoadingSavedPosition
            && (viewingOnline ? item != nil && hasLoadedOnlineOwnership : localRecord?.isReadyToWatch == true)
    }

    private var hasLoadedOnlineOwnership: Bool {
        guard let loadedConnection else { return false }
        return app.client.connection?.serverIdentity == loadedConnection.serverIdentity
            && app.client.connection?.username == loadedConnection.username
    }

    private var resumePosition: Double? {
        if !viewingOnline, let localRecord { return app.player.resumePosition(for: localRecord) }
        return item.flatMap { app.player.resumePosition(for: $0) }
    }

    private var libraryKey: MovieLibraryKey? {
        if !viewingOnline, let localRecord {
            return MovieLibraryKey(serverIdentity: localRecord.serverOrigin, accountUsername: localRecord.accountUsername, mediaID: mediaID)
        }
        guard let connection = loadedConnection ?? app.client.connection else { return nil }
        return MovieLibraryKey(connection: connection, mediaID: mediaID)
    }

    private var playbackDuration: Double? {
        if !viewingOnline, let duration = localRecord?.assetInspection?.durationSeconds, duration > 0 { return duration }
        return movie.durationSeconds
    }

    private var watchLabel: String {
        if let seconds = resumePosition {
            return "Resume at \(Self.time(seconds))"
        }
        return viewingOnline ? "Watch" : "Watch Offline"
    }

    private func watch(start: PlaybackStart) {
        if !viewingOnline, let localRecord {
            app.playOffline(localRecord, start: start)
        } else if let item, let loadedConnection {
            app.player.play(.online(item: item, connection: loadedConnection, start: start,
                                    quality: selectedQuality, audioIndex: selectedAudio,
                                    qualityNotice: qualityNotice,
                                    qualityProfiles: loadedQualityProfiles))
        }
    }

    private static func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
    }
}

private struct MetadataPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }
}
