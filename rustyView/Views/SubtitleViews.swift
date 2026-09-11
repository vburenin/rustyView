import SwiftUI

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
