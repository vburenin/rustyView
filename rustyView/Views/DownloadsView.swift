import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var pendingDeletion: DownloadRecord?
    @State private var managingCopies: MovieLibraryKey?
    @State private var copyToPlay: DownloadRecord?
    @State private var query = ""
    @State private var sort = OfflineCollectionSort.recent

    var body: some View {
        Group {
            if app.downloads.isRestoring && app.downloads.active.isEmpty && app.downloads.completed.isEmpty {
                ProgressView("Restoring your downloads…")
            } else if app.downloads.active.isEmpty && app.downloads.completed.isEmpty {
                ContentUnavailableView {
                    Label("No downloads yet", systemImage: "arrow.down.circle")
                } description: {
                    Text("Download a movie to watch offline.")
                } actions: {
                    Button { app.selectedTab = .library } label: {
                        Text("Browse Movies").frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("ActionFill"))
                }
            } else {
                List {
                    if !app.savedEntries(.continueWatching, offlineOnly: true).isEmpty && query.isEmpty {
                        Section {
                            NavigationLink { SavedMoviesView(collection: .continueWatching, offlineOnly: true) } label: {
                                Group {
                                    if dynamicTypeSize.isAccessibilitySize { Text("Continue Watching") }
                                    else { Label("Continue Watching", systemImage: "play.circle") }
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("collection-continue")
                        }
                    }
                    if !attention.isEmpty {
                        Section {
                            ForEach(attention) { group in movieRow(group) }
                        } header: {
                            if !transferring.isEmpty || !ready.isEmpty { Text("Needs Attention") }
                        }
                    }
                    if !transferring.isEmpty {
                        Section {
                            ForEach(transferring) { group in
                                movieRow(group)
                            }
                        } header: {
                            if !attention.isEmpty || !ready.isEmpty { Text("In Progress") }
                        }
                    }
                    if !ready.isEmpty {
                        Section {
                            ForEach(ready) { group in movieRow(group) }
                        } header: {
                            if !attention.isEmpty || !transferring.isEmpty { Text("Ready to Watch") }
                        }
                    }
                    if !query.isEmpty && matchingGroups.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("No matching downloads")
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            ClearSearchButton { query = "" }
                        }
                        .padding(.vertical, 8)
                    }
                    if query.isEmpty, !app.downloads.completed.isEmpty || app.downloads.totalStoredBytes > 0 {
                        Text("\(downloadedStorageSize) used")
                            .font(.footnote).foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .accessibilityLabel("Storage used: \(downloadedStorageSize)")
                            .accessibilityIdentifier("download-storage-used")
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .searchable(text: $query, prompt: Text("Search downloaded movies").foregroundColor(.primary.opacity(0.75)))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    SavedCollectionLinks(offlineOnly: true)
                } label: { Label("My Movies", systemImage: "heart.text.clipboard") }
                    .accessibilityIdentifier("collections-menu")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort Downloads", selection: $sort) {
                        ForEach(OfflineCollectionSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Label("Sort Downloads", systemImage: "arrow.up.arrow.down") }
            }
            if !app.isConfigured {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Connect") { app.showingConnection = true }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if app.downloads.errorMessage != nil {
                RecoveryBanner("Downloads need attention", identifier: "download-storage-recovery") { _ in
                    DownloadStorageRecoveryDetails()
                }
            }
            UserLibraryRecoveryView()
        }
        .alert("Delete offline copy?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let record = pendingDeletion { app.downloads.delete(record) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The movie will remain on the server.")
        }
        .sheet(isPresented: Binding(
            get: { managingCopies != nil },
            set: { if !$0 { managingCopies = nil } }
        ), onDismiss: {
            if let record = copyToPlay { copyToPlay = nil; app.playOffline(record) }
        }) {
            if let key = managingCopies { DownloadCopiesView(key: key) { copyToPlay = $0 } }
        }
    }

    private var downloadedStorageSize: String {
        ByteCountFormatter.string(fromByteCount: app.downloads.totalStoredBytes, countStyle: .file)
    }

    private var matchingGroups: [DownloadMovieGroup] {
        DownloadMovieGroup.collect(records: app.downloads.completed, transfers: app.downloads.active).filter { group in
            query.isEmpty || group.title.localizedStandardContains(query) || group.records.contains { record in
                [record.movieMetadata.summary ?? "", record.movieMetadata.genre ?? ""].contains { $0.localizedStandardContains(query) }
            }
        }.sorted { lhs, rhs in
            switch sort {
            case .title: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case .recent: return lhs.completedAt > rhs.completedAt
            case .remaining:
                let left = lhs.representativeRecord.map(remainingSeconds) ?? .greatestFiniteMagnitude
                let right = rhs.representativeRecord.map(remainingSeconds) ?? .greatestFiniteMagnitude
                return left == right ? lhs.completedAt > rhs.completedAt : left < right
            }
        }
    }
    private var ready: [DownloadMovieGroup] { matchingGroups.filter { $0.readyRecord != nil } }
    private var attention: [DownloadMovieGroup] { matchingGroups.filter(\.needsAttention) }
    private var transferring: [DownloadMovieGroup] { matchingGroups.filter { $0.readyRecord == nil && !$0.needsAttention } }
    private func remainingSeconds(_ record: DownloadRecord) -> Double {
        guard let duration = record.assetInspection?.durationSeconds ?? record.movieMetadata.durationSeconds else { return .greatestFiniteMagnitude }
        return duration - (app.player.resumePosition(for: record) ?? 0)
    }

    @ViewBuilder private func movieRow(_ group: DownloadMovieGroup) -> some View {
        if let record = group.representativeRecord, group.readyRecord != nil || group.transfers.isEmpty {
            savedRow(group, record: record)
        } else if let transfer = group.representativeTransfer {
            ActiveDownloadRow(download: transfer, manageCopies: group.copyCount > 1 ? { managingCopies = group.key } : nil)
                .accessibilityIdentifier("download-movie-\(group.key.mediaID)")
        }
    }

    private func savedRow(_ group: DownloadMovieGroup, record: DownloadRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink { MovieDetailView(record: record) } label: {
                DownloadedRow(record: record, copyCount: group.copyCount, transfer: group.representativeTransfer)
            }
                .buttonStyle(.plain)
                .accessibilityIdentifier("download-details-\(record.id.uuidString)")
                .accessibilityValue(record.kind.label)
            CollectionActionRow {
                if record.isReadyToWatch {
                    Button { app.playOffline(record) } label: {
                        Label(app.player.resumePosition(for: record) == nil ? "Play" : "Resume", systemImage: "play.fill")
                            .labelStyle(.titleAndIcon)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("play-download-\(record.id.uuidString)")
                    .accessibilityLabel("\(app.player.resumePosition(for: record) == nil ? "Play" : "Resume") offline copy of \(record.displayTitle)")
                }
            } secondary: {
                Menu {
                    if record.isReadyToWatch, app.player.resumePosition(for: record) != nil {
                        Button("Start Over", systemImage: "arrow.counterclockwise") { app.playOffline(record, start: .startOver) }
                    }
                    let key = app.key(for: record)
                    let favorite = app.userLibrary.isFavorite(for: key)
                    Button(favorite ? "Remove Favorite" : "Add Favorite", systemImage: favorite ? "heart.slash" : "heart") {
                        app.userLibrary.setFavorite(!favorite, movie: record.movieMetadata, for: key)
                    }
                    if group.copyCount > 1 {
                        Button("Manage Copies", systemImage: "square.on.square") { managingCopies = group.key }
                            .accessibilityIdentifier("download-copies-\(group.key.mediaID)")
                    } else {
                        Button("Delete Download", systemImage: "trash", role: .destructive) { pendingDeletion = record }
                            .accessibilityIdentifier("delete-download-\(record.id.uuidString)")
                            .accessibilityLabel("Delete offline copy of \(record.displayTitle)")
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("download-actions-\(record.id.uuidString)")
                .accessibilityLabel("Actions for \(record.displayTitle)")
                .accessibilityValue(record.kind.label)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("download-movie-\(group.key.mediaID)")
        .swipeActions {
            if group.copyCount > 1 { Button("Copies") { managingCopies = group.key } }
            else { Button("Delete", role: .destructive) { pendingDeletion = record } }
        }
    }
}

private enum OfflineCollectionSort: String, CaseIterable, Identifiable {
    case recent = "Recently Saved", title = "Title", remaining = "Time Remaining"
    var id: String { rawValue }
}

private struct ActiveDownloadRow: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingConnection = false
    @State private var showingFailure = false
    let download: ActiveDownload
    var manageCopies: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                MovieDetailView(mediaID: download.mediaID, title: download.title)
            } label: {
                HStack(spacing: 12) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        PosterFrame { LocalArtworkView(url: nil) }.frame(width: 56)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(download.displayTitle).font(.headline).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        status
                            .font(.subheadline)
                            .foregroundStyle(download.failure == nil ? Color.secondary : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("active-download-\(download.mediaID)")
            .disabled(!ownsDownload)
            .accessibilityHint(ownsDownload ? "Shows movie details and download status" : "Reconnect to this movie's server to view its details")

            if let fraction = progressFraction {
                ProgressView(value: fraction).accessibilityHidden(true)
            }
            CollectionActionRow {
                primaryAction
            } secondary: {
                Menu {
                    if let manageCopies {
                        Button("Manage Copies", systemImage: "square.on.square", action: manageCopies)
                            .accessibilityIdentifier("download-copies-\(download.mediaID)")
                    }
                    if case .failed = download.phase {
                        Button("Show Error", systemImage: "info.circle") { showingFailure = true }
                        if let failure = download.failure {
                            ForEach(failure.recoveryActions().filter { $0 != .retry }) { action in
                                Button(action.title, systemImage: action.systemImage) {
                                    if action == .editConnection { showingConnection = true }
                                    else { app.performRecovery(action) }
                                }
                            }
                        }
                        Button("Remove from Queue", systemImage: "trash", role: .destructive) { app.downloads.dismissFailure(download) }
                    } else {
                        if canPause { Button("Pause Download", systemImage: "pause") { app.downloads.pause(download) } }
                        Button("Cancel Download", systemImage: "xmark", role: .destructive) { app.downloads.cancel(download) }
                            .accessibilityLabel("Cancel download of \(download.displayTitle)")
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("active-download-actions-\(download.id.uuidString)")
                .accessibilityLabel("Download actions for \(download.displayTitle)")
                .disabled(download.phase == .cancelling)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .onChange(of: phaseAnnouncement) { _, message in
            guard UIAccessibility.isVoiceOverRunning else { return }
            UIAccessibility.post(notification: .announcement, argument: "\(download.displayTitle). \(message)")
        }
        .sheet(isPresented: $showingConnection) { ConnectionSetupView(canDismiss: true) }
        .alert("Download needs attention", isPresented: $showingFailure) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(failureMessage)
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch download.phase {
        case .failed, .retrying:
            Button { app.downloads.retry(download) } label: { actionLabel("Retry Now", icon: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Retry download of \(download.displayTitle)")
        case .paused:
            Button { app.downloads.resume(download) } label: { actionLabel("Resume", icon: "play.fill") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Resume download of \(download.displayTitle)")
        case .waiting(.credentials):
            Button { showingConnection = true } label: { actionLabel("Reconnect", icon: "person.crop.circle") }
                .buttonStyle(.borderless)
        case .queued, .downloading, .waiting:
            Button { app.downloads.pause(download) } label: { actionLabel("Pause", icon: "pause.fill") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Pause download of \(download.displayTitle)")
        case .pausing, .cancelling, .finishing:
            ProgressView().frame(width: 44, height: 44)
        }
    }

    private func actionLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).labelStyle(.titleAndIcon)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    @ViewBuilder private var status: some View {
        switch download.phase {
        case .queued:
            if let preparation = progressPresentation.activePreparation { preparationText(preparation) }
            else { Text("Queued") }
        case .pausing: Text("Pausing…")
        case .cancelling: Text("Cancelling…")
        case .paused: Text("Paused")
        case .waiting(let reason):
            switch reason {
            case .wifi: Text("Waiting for Wi-Fi")
            case .network: Text("Waiting for a connection")
            case .credentials: Text("Sign in to continue")
            case .turn: Text("Queued")
            }
        case .downloading:
            if let preparation = progressPresentation.activePreparation { preparationText(preparation) }
            else if let percent = progressPresentation.percent {
                Text("Downloading · \(percent)%")
                    .accessibilityIdentifier("download-transfer-status-\(download.mediaID)")
                    .accessibilityLabel("Downloading")
                    .accessibilityValue("\(percent)%")
            }
            else { Text("Downloading…") }
            if let bytes = progressPresentation.byteText {
                Text(bytes)
                    .accessibilityIdentifier("download-byte-progress-\(download.mediaID)")
            }
            if let remaining = progressPresentation.remainingByteText {
                Text(remaining)
                    .accessibilityIdentifier("download-bytes-remaining-\(download.mediaID)")
            }
        case .retrying(_, let scheduledAt, _): Text("Retrying \(scheduledAt, style: .relative)")
        case .finishing: Text("Saving…")
        case .failed: Text(download.failure?.title ?? "Download failed")
        }
    }

    private var progressPresentation: DownloadProgressPresentation {
        DownloadProgressPresentation(phase: download.phase,
            preparation: app.downloads.preparationProgress(for: download))
    }

    private var progressFraction: Double? { progressPresentation.fraction }

    private var canPause: Bool {
        switch download.phase {
        case .queued, .downloading, .retrying, .waiting: true
        case .pausing, .cancelling, .paused, .finishing, .failed: false
        }
    }

    /// Announce meaningful transitions, without announcing each byte update.
    private var phaseAnnouncement: String {
        switch download.phase {
        case .queued: "Queued"
        case .pausing: "Saving download progress"
        case .cancelling: "Cancelling download"
        case .paused: "Download paused"
        case .waiting(let reason): reason.message
        case .downloading: "Downloading"
        case .retrying: "Download will retry"
        case .finishing: "Saving movie"
        case .failed: "Download needs attention"
        }
    }

    private var failureMessage: String {
        if let failure = download.failure { return failure.message }
        if case .failed(let message) = download.phase { return message }
        return "Try the download again."
    }

    private var ownsDownload: Bool {
        app.client.connection?.owns(serverIdentity: download.serverOrigin, accountUsername: download.metadata.accountUsername) == true
    }

    private func preparationText(_ progress: DownloadPreparationProgress) -> some View {
        Text(progress.presentationText).accessibilityIdentifier("preparation-progress-\(download.mediaID)")
    }
}

private struct DownloadedRow: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let record: DownloadRecord
    var copyCount = 1
    var transfer: ActiveDownload? = nil

    var body: some View {
        HStack(spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                PosterFrame { LocalArtworkView(url: app.downloads.artworkURL(for: record)) }.frame(width: 56)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(record.displayTitle).font(.headline).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(summary).font(.subheadline)
                    .foregroundStyle(record.isReadyToWatch ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("download-readiness-\(record.mediaID)")
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private var summary: String {
        var parts: [String] = []
        if copyCount > 1 { parts.append("\(copyCount) copies") }
        if let transfer {
            switch transfer.phase {
            case .failed: parts.append("Copy needs attention")
            case .paused: parts.append("Copy paused")
            case .waiting(.credentials): parts.append("Sign in to finish copy")
            case .waiting(.wifi): parts.append("Waiting for Wi-Fi")
            case .queued, .waiting, .retrying: parts.append("Copy queued")
            case .pausing: parts.append("Pausing copy")
            case .cancelling: parts.append("Cancelling copy")
            case .downloading: parts.append("Downloading copy")
            case .finishing: parts.append("Saving copy")
            }
        } else if !record.isReadyToWatch {
            parts.append(record.assetInspection == nil ? "Checking copy" : record.packageIssue == nil ? "Compatible copy needed" : "Needs attention")
        } else if let remaining = app.timeRemaining(for: record) {
            parts.append(remaining)
        } else if let duration = record.assetInspection?.durationSeconds ?? record.movieMetadata.durationSeconds, duration.isFinite, duration > 0 {
            parts.append("\(max(1, Int(ceil(duration / 60)))) min")
        } else {
            parts.append("Saved offline")
        }
        return parts.joined(separator: " · ")
    }
}

/// Optional rendition management. The presenting screen starts selected
/// playback after this sheet dismisses, so two presentations cannot race.
struct DownloadCopiesView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let key: MovieLibraryKey
    let onPlay: (DownloadRecord) -> Void
    @State private var pendingDeletion: DownloadRecord?

    private var group: DownloadMovieGroup? {
        DownloadMovieGroup.collect(records: app.downloads.completed, transfers: app.downloads.active).first { $0.key == key }
    }

    var body: some View {
        NavigationStack {
            List {
                if let group {
                    ForEach(group.records) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(record.kind == .original ? "Original file" : "Compatible copy")
                                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                                Text(copyStatus(record))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(record.kind == .original ? "Original file" : "Compatible copy")
                            .accessibilityValue(copyStatus(record))
                            .accessibilityIdentifier("copy-summary-\(record.id.uuidString)")
                            CollectionActionRow {
                                if record.isReadyToWatch {
                                    Button { onPlay(record); dismiss() } label: {
                                        Label(app.player.resumePosition(for: record) == nil ? "Play" : "Resume", systemImage: "play.fill")
                                            .labelStyle(.titleAndIcon).fixedSize(horizontal: true, vertical: false)
                                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("play-copy-\(record.id.uuidString)")
                                    .accessibilityLabel("\(app.player.resumePosition(for: record) == nil ? "Play" : "Resume") \(record.kind == .original ? "original" : "compatible") copy of \(record.displayTitle)")
                                }
                            } secondary: {
                                Menu {
                                    NavigationLink { MovieDetailView(record: record) } label: {
                                        Label("Details", systemImage: "info.circle")
                                    }
                                    .accessibilityIdentifier("copy-details-\(record.id.uuidString)")
                                    Button("Delete Download", systemImage: "trash", role: .destructive) { pendingDeletion = record }
                                        .accessibilityIdentifier("delete-download-\(record.id.uuidString)")
                                        .accessibilityLabel("Delete \(record.kind == .original ? "original" : "compatible") copy of \(record.displayTitle)")
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("copy-actions-\(record.id.uuidString)")
                                .accessibilityLabel("Actions for \(record.kind == .original ? "original" : "compatible") copy of \(record.displayTitle)")
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("download-copy-\(record.id.uuidString)")
                        .swipeActions { Button("Delete", role: .destructive) { pendingDeletion = record } }
                    }
                    ForEach(group.transfers) { transfer in ActiveDownloadRow(download: transfer) }
                }
            }
            .navigationTitle("Saved Copies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.frame(minHeight: 44) } }
        }
        .onChange(of: group?.copyCount) { _, count in if count == nil || count == 0 { dismiss() } }
        .alert("Delete offline copy?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let record = pendingDeletion { app.downloads.delete(record) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Your other copies are kept.")
        }
    }

    private func copyStatus(_ record: DownloadRecord) -> String {
        "\(record.isReadyToWatch ? "" : "Needs attention · ")\(ByteCountFormatter.string(fromByteCount: record.packageStorageBytes ?? record.byteCount, countStyle: .file))"
    }
}
