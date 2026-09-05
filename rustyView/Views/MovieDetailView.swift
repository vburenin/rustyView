import SwiftUI

struct MovieDetailView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let mediaID: String
    let initialTitle: String

    @State private var item: MediaItem?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedAudio = 0
    @State private var selectedQuality = "auto"
    @State private var pendingDownloadDeletion: DownloadRecord?
    @State private var loadRequest = UUID()

    init(entry: LibraryEntry) {
        mediaID = entry.id
        initialTitle = entry.displayTitle
    }

    init(mediaID: String, title: String) {
        self.mediaID = mediaID
        initialTitle = DisplayTitle.clean(title)
    }

    private var usesCompactHeader: Bool {
        horizontalSizeClass == .compact && !dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView("Loading details…")
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Details unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if let item {
                detail(item)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(initialTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: mediaID) { await load() }
        .alert("Remove offline copy?", isPresented: Binding(
            get: { pendingDownloadDeletion != nil },
            set: { if !$0 { pendingDownloadDeletion = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let record = pendingDownloadDeletion { app.downloads.delete(record) }
                pendingDownloadDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDownloadDeletion = nil }
        } message: {
            Text("This frees the space used by this movie on this device. It does not change the server library.")
        }
    }

    @ViewBuilder
    private func detail(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: usesCompactHeader ? 16 : 24) {
            detailHeader(item)

            controls(item)

            if let about = item.about, !about.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About").font(.title2.bold())
                    Text(about).font(.body).textSelection(.enabled)
                }
            }

            if !item.chapters.isEmpty {
                DisclosureGroup("Chapters (\(item.chapters.count))") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(item.chapters) { chapter in
                            Button {
                                app.player.play(
                                    item,
                                    quality: selectedQuality,
                                    audioIndex: selectedAudio,
                                    startAt: chapter.startSeconds
                                )
                            } label: {
                                HStack {
                                    Text(chapter.title).multilineTextAlignment(.leading)
                                    Spacer()
                                    Text(Self.time(chapter.startSeconds)).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 12)
                }
                .font(.headline)
            }
        }
        .padding()
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func detailHeader(_ item: MediaItem) -> some View {
        if usesCompactHeader {
            HStack(alignment: .top, spacing: 16) {
                artwork(item, maxWidth: 108)
                    .frame(width: 108)
                summary(item, compact: true)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    artwork(item, maxWidth: 300)
                    summary(item, compact: false)
                }
                VStack(alignment: .leading, spacing: 20) {
                    artwork(item, maxWidth: 300)
                    summary(item, compact: false)
                }
            }
        }
    }

    private func artwork(_ item: MediaItem, maxWidth: CGFloat) -> some View {
        PosterFrame {
            AuthenticatedArtworkView(path: item.artURL, client: app.client)
        }
            .frame(maxWidth: maxWidth)
            .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
    }

    private func summary(_ item: MediaItem, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            Text(item.displayTitle)
                .font(compact ? .title3.bold() : .largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits {
                HStack(spacing: 8) { metadataPills(item) }
                VStack(alignment: .leading, spacing: 8) { metadataPills(item) }
            }
            if let genre = item.genre, !genre.isEmpty {
                Text(genre).foregroundStyle(Color(uiColor: .label))
            }
            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: item.sizeBytes), countStyle: .file))
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .foregroundStyle(Color(uiColor: .label))
                .accessibilityIdentifier("media-file-size")
            if let record = app.downloads.record(for: item.id) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Available offline")
                            .font(.subheadline.weight(.semibold))
                        Text(record.videoQualityDescription)
                            .font(.caption)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .foregroundStyle(.green)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("offline-copy-available")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func metadataPills(_ item: MediaItem) -> some View {
        if let duration = item.duration { MetadataPill(text: duration.components(separatedBy: ".").first ?? duration) }
        if let resolution = item.resolution { MetadataPill(text: resolution) }
        if item.hdr.lowercased() != "sdr" { MetadataPill(text: item.hdr.uppercased()) }
    }

    private func controls(_ item: MediaItem) -> some View {
        VStack(spacing: 14) {
            Button {
                if let record = app.downloads.record(for: item.id) {
                    app.player.playLocal(record: record, url: app.downloads.localURL(for: record))
                } else {
                    app.player.play(item, quality: selectedQuality, audioIndex: selectedAudio)
                }
            } label: {
                Label(watchLabel(item), systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.64, green: 0.20, blue: 0.0))

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

            downloadControl(item)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func audioPicker(_ item: MediaItem) -> some View {
        let selectedTrack = item.audioTracks.first { $0.index == selectedAudio }
        return Menu {
            Picker("Audio", selection: $selectedAudio) {
                ForEach(item.audioTracks) { track in
                    Text(track.selectionLabel(defaultIndex: item.defaultAudioIndex)).tag(track.index)
                }
            }
        } label: {
            selectionLabel(
                title: "Audio",
                value: selectedTrack?.displayName ?? "Default",
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
            Picker("Quality", selection: $selectedQuality) {
                ForEach(app.library.capabilities?.qualityProfiles ?? []) { profile in
                    Text(profile.label).tag(profile.id)
                }
            }
        } label: {
            selectionLabel(
                title: "Quality",
                value: selectedQualityProfile?.label ?? "Auto",
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
            let preparation = app.downloads.preparationProgress(for: download)
            let visibleProgress = preparation?.fraction ?? download.phase.progress
            VStack(spacing: 8) {
                HStack {
                    Text(downloadStatus(download))
                    Spacer()
                    if let preparation {
                        Text("\(preparation.percent)%")
                    } else if let progress = download.phase.progress {
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                    }
                }
                downloadSelections(
                    quality: download.metadata.videoQualityDescription,
                    audio: download.metadata.audioSelectionDescription
                )
                if let progress = visibleProgress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
                if let preparation {
                    Text(preparation.presentationText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("detail-preparation-progress-\(download.mediaID)")
                }
                if case .failed(let message) = download.phase {
                    Text(message).font(.caption).foregroundStyle(.red)
                    HStack {
                        Button("Retry Now") { app.downloads.retry(download) }
                        Button("Remove from Queue", role: .destructive) {
                            app.downloads.dismissFailure(download)
                        }
                    }
                    .font(.subheadline)
                } else {
                    Button("Cancel Download", role: .cancel) { app.downloads.cancel(download) }
                        .font(.subheadline)
                }
            }
        } else if let record = app.downloads.record(for: item.id) {
            VStack(spacing: 10) {
                HStack {
                    Label("Available offline", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Quality: \(record.videoQualityDescription)")
                        Text("Audio: \(record.audioSelectionDescription)")
                        Text("On device: \(ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    pendingDownloadDeletion = record
                } label: {
                    Label("Remove Download", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        } else {
            Menu {
                Button {
                    startDownload(item: item, kind: .compatible)
                } label: {
                    Label("Compatible copy", systemImage: "iphone")
                }
                Button {
                    startDownload(item: item, kind: .original)
                } label: {
                    Label("Original file", systemImage: "doc")
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }

    private func load() async {
        let request = UUID()
        loadRequest = request
        isLoading = true
        errorMessage = nil
        defer { if request == loadRequest { isLoading = false } }
        do {
            let loaded = try await app.client.item(id: mediaID)
            guard request == loadRequest, !Task.isCancelled else { return }
            item = loaded
            selectedAudio = loaded.defaultAudioIndex
        } catch is CancellationError {
            return
        } catch {
            guard request == loadRequest, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func startDownload(item: MediaItem, kind: DownloadKind) {
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

    private func downloadStatus(_ download: ActiveDownload) -> String {
        switch download.phase {
        case .queued: "Queued for download"
        case .downloading: "Downloading…"
        case .retrying(let attempt, _, _): "Waiting to retry (attempt \(attempt))"
        case .finishing: "Saving for offline use…"
        case .failed: "Download needs attention"
        }
    }

    private var selectedQualityProfile: QualityProfile? {
        app.library.capabilities?.qualityProfiles.first { $0.id == selectedQuality }
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
                    .lineLimit(2)
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

    private func watchLabel(_ item: MediaItem) -> String {
        if app.downloads.record(for: item.id) != nil { return "Watch Offline" }
        if let seconds = app.player.resumePosition(for: item) {
            return "Resume at \(Self.time(seconds))"
        }
        return "Watch"
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
