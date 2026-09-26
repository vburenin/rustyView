import SwiftUI

struct DownloadSubtitlesAction: View {
    @EnvironmentObject private var app: AppModel
    let record: DownloadRecord

    var body: some View {
        Button("Download Missing Subtitles", systemImage: "captions.bubble") {
            app.downloadMissingSubtitles(record)
        }
        .disabled(app.subtitleChecks.contains(record.id) || app.downloads.active.contains { $0.id == record.id })
        .accessibilityIdentifier("download-subtitles-\(record.id.uuidString)")
    }
}

struct OfflineSubtitleDownloadStatus: View {
    @EnvironmentObject private var app: AppModel
    let record: DownloadRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if app.subtitleChecks.contains(record.id) {
                ProgressView("Checking subtitles…")
                Button("Cancel") { app.cancelSubtitleCheck(record.id) }.frame(minHeight: 44)
            } else if let transfer = app.downloads.active.first(where: { $0.id == record.id && $0.metadata.subtitlesOnly == true }) {
                switch transfer.phase {
                case .failed(let message):
                    Text("Subtitles: \(message)").fixedSize(horizontal: false, vertical: true)
                    Button("Retry Subtitles") { app.downloads.retry(transfer) }.frame(minHeight: 44)
                case .paused:
                    Text("Subtitle download paused")
                    Button("Resume Subtitles") { app.downloads.resume(transfer) }.frame(minHeight: 44)
                case .waiting(let reason): Text("Subtitles: \(reason.message)")
                case .retrying: Text("Retrying subtitle download…")
                case .pausing: ProgressView("Pausing subtitles…")
                case .cancelling: ProgressView("Cancelling subtitles…")
                case .finishing: ProgressView("Saving subtitles…")
                default: ProgressView("Downloading subtitles…")
                }
                if transfer.phase != .cancelling && transfer.phase != .pausing && transfer.phase != .finishing {
                    HStack {
                        if case .failed = transfer.phase { } else if case .paused = transfer.phase { } else {
                            Button("Pause") { app.downloads.pause(transfer) }.frame(minHeight: 44)
                        }
                        Button("Cancel Subtitles") { app.downloads.cancel(transfer) }.frame(minHeight: 44)
                    }
                }
            }
            if let notice = app.subtitleDownloadNotices[record.id], !notice.isEmpty {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("offline-subtitle-status-\(record.id.uuidString)")
    }
}

/// Feedback appears beside both the primary menu and the expanded choices.
struct SubtitleFeedbackView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if let notice = app.player.subtitlePreferenceNotice {
            Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("subtitle-preference-notice")
        }
        switch app.player.subtitleSelection {
        case .off, .active:
            EmptyView()
        case .loading(let selection):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView {
                    Text("Loading " + selection.label + "…")
                        .fixedSize(horizontal: false, vertical: true)
                }
                offButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("subtitle-loading")
        case .failed(_, let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { recoveryButtons }
                    VStack(alignment: .leading) { recoveryButtons }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("subtitle-failure")
        }
    }

    @ViewBuilder private var recoveryButtons: some View {
        Button { Task { await app.player.retrySubtitles() } } label: {
            Text("Retry").fixedSize().frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
            .accessibilityLabel("Retry Subtitles")
            .accessibilityIdentifier("retry-subtitles")
        offButton
    }

    private var offButton: some View {
        Button { app.player.turnSubtitlesOff() } label: {
            Text("Off").fixedSize().frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Turn Subtitles Off")
    }
}

struct SubtitleOptionsSection: View {
    @EnvironmentObject private var app: AppModel
    let isOffline: Bool
    var dismissOnRequest = false
    let dismissOnSelection: () -> Void

    var body: some View {
        Section("Subtitles") {
            Button {
                app.player.turnSubtitlesOff()
                dismissOnSelection()
            } label: {
                HStack {
                    Text("Off")
                    Spacer()
                    if app.player.subtitleSelection == .off { Image(systemName: "checkmark") }
                }.frame(minHeight: 44)
            }
            .accessibilityIdentifier(isOffline ? "local-caption-off" : "caption-off")
            ForEach(app.player.subtitleOptions) { option in
                Button {
                    if dismissOnRequest { dismissOnSelection() }
                    Task {
                        await app.player.selectSubtitle(id: option.id)
                        if !dismissOnRequest, app.player.subtitleSelection.active?.id == option.id { dismissOnSelection() }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.selection.label + (option.isForced ? " · Forced" : ""))
                                .fixedSize(horizontal: false, vertical: true)
                            if !option.isAvailable || option.selection.delivery == .native {
                                Text(option.isAvailable ? "Included in video" : "Unavailable on this device")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        if app.player.subtitleSelection.active?.id == option.id {
                            Image(systemName: "checkmark")
                        } else if app.player.subtitleSelection.requested?.id == option.id {
                            Image(systemName: "ellipsis")
                        }
                    }.frame(minHeight: 44)
                }
                .foregroundStyle(.primary)
                .disabled(!option.isAvailable)
                .accessibilityIdentifier(identifier(for: option))
                .accessibilityValue(app.player.subtitleSelection.requested?.id == option.id
                                    ? app.player.subtitleSelection.accessibilityValue : "Not selected")
            }
            SubtitleFeedbackView()
            if let notice = app.player.subtitleOutputNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("subtitle-output-notice")
            }
            if app.player.subtitleOptions.isEmpty && !app.player.isLoadingLocalTracks {
                Text("No subtitles in this copy. Check Online in movie details.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func identifier(for option: PlaybackSubtitleOption) -> String {
        switch option.source {
        case .server(let index): "caption-track-\(index)"
        case .native, .offline: "local-caption-\(option.id)"
        }
    }
}
