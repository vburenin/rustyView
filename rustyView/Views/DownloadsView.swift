import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var pendingDeletion: DownloadRecord?

    var body: some View {
        Group {
            if app.downloads.active.isEmpty && app.downloads.completed.isEmpty {
                ContentUnavailableView(
                    "No downloads yet",
                    systemImage: "arrow.down.circle",
                    description: Text("Download a compatible copy from any movie to watch without a connection.")
                )
            } else {
                List {
                    if !app.downloads.completed.isEmpty {
                        Section {
                            HStack {
                                Label("Downloaded video storage", systemImage: "internaldrive")
                                Spacer()
                                Text(downloadedStorageSize)
                                    .foregroundStyle(.secondary)
                            }
                        } footer: {
                            Text("Use the trash button or swipe left on a movie to free its space.")
                        }
                    }
                    if !app.downloads.active.isEmpty {
                        Section("In Progress") {
                            ForEach(app.downloads.active) { download in
                                ActiveDownloadRow(download: download)
                            }
                        }
                    }
                    if !app.downloads.completed.isEmpty {
                        Section("Available Offline") {
                            ForEach(app.downloads.completed) { record in
                                HStack(spacing: 8) {
                                    Button {
                                        app.player.playLocal(record: record, url: app.downloads.localURL(for: record))
                                    } label: {
                                        DownloadedRow(record: record)
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        pendingDeletion = record
                                    } label: {
                                        Image(systemName: "trash")
                                            .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.red)
                                    .accessibilityIdentifier("delete-download-\(record.id.uuidString)")
                                    .accessibilityLabel("Delete offline copy")
                                    .accessibilityHint("Frees the storage used by this movie")
                                }
                                .swipeActions {
                                    Button("Delete", role: .destructive) { pendingDeletion = record }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .safeAreaInset(edge: .bottom) {
            if let error = app.downloads.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
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
            Text("This frees the space used by this movie on this device. It does not change the server library.")
        }
    }

    private var downloadedStorageSize: String {
        let total = app.downloads.completed.reduce(Int64(0)) { partial, record in
            partial.addingReportingOverflow(record.byteCount).overflow
                ? Int64.max
                : partial + record.byteCount
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

private struct ActiveDownloadRow: View {
    @EnvironmentObject private var app: AppModel
    let download: ActiveDownload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                NavigationLink {
                    MovieDetailView(mediaID: download.mediaID, title: download.title)
                } label: {
                    VStack(alignment: .leading) {
                        Text(download.displayTitle)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text("Quality: \(download.metadata.videoQualityDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("download-quality-\(download.mediaID)")
                        Text("Audio: \(download.metadata.audioSelectionDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("download-audio-\(download.mediaID)")
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("active-download-\(download.mediaID)")
                .disabled(download.serverOrigin != app.client.connection?.baseURL.absoluteString)
                .accessibilityHint(download.serverOrigin == app.client.connection?.baseURL.absoluteString
                    ? "Shows movie details and download status"
                    : "Reconnect to this movie's server to view its details")
                Spacer()
                switch download.phase {
                case .failed:
                    Menu {
                        Button("Retry Now") { app.downloads.retry(download) }
                        Button("Remove from Queue", role: .destructive) {
                            app.downloads.dismissFailure(download)
                        }
                    } label: {
                        Label("Download actions", systemImage: "ellipsis.circle")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Download actions")
                default:
                    Button(role: .cancel) { app.downloads.cancel(download) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancel download")
                }
            }
            switch download.phase {
            case .queued:
                if let preparation = app.downloads.preparationProgress(for: download) {
                    ProgressView(value: preparation.fraction)
                    preparationProgressText(preparation)
                } else {
                    ProgressView("Waiting…")
                }
            case .downloading(let progress, let received, let expected):
                let preparation = app.downloads.preparationProgress(for: download)
                if expected == nil, let preparation {
                    ProgressView(value: preparation.fraction)
                } else if expected == nil {
                    ProgressView()
                } else {
                    ProgressView(value: progress)
                }
                if let preparation {
                    preparationProgressText(preparation)
                }
                Text(progressText(received: received, expected: expected, hasPreparation: preparation != nil))
                    .font(.caption).foregroundStyle(.secondary)
            case .retrying(let attempt, let scheduledAt, let reason):
                ProgressView()
                Text("Retry \(attempt) scheduled \(scheduledAt, style: .relative). \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .finishing:
                ProgressView("Saving…")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func progressText(received: Int64, expected: Int64?, hasPreparation: Bool) -> String {
        let receivedText = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard let expected else { return hasPreparation ? "\(receivedText) received" : receivedText }
        return "\(receivedText) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))"
    }

    private func preparationProgressText(_ progress: DownloadPreparationProgress) -> some View {
        Text(progress.presentationText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("preparation-progress-\(download.mediaID)")
    }
}

private struct DownloadedRow: View {
    let record: DownloadRecord

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "play.rectangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 44, height: 44)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayTitle).font(.headline).lineLimit(2)
                Text("Quality: \(record.videoQualityDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("downloaded-quality-\(record.mediaID)")
                Text("Audio: \(record.audioSelectionDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("downloaded-audio-\(record.mediaID)")
                Text("On device: \(ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "play.fill").foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
