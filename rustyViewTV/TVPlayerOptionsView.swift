import SwiftUI

enum TVPlayerOptionsPage: String, Identifiable {
    case subtitles, audio, chapters, settings
    var id: String { rawValue }
}

struct TVPlayerOptionsSheet: View {
    let page: TVPlayerOptionsPage

    var body: some View {
        NavigationStack {
            switch page {
            case .subtitles: TVSubtitleOptions()
            case .audio: TVAudioOptions()
            case .chapters: TVChapterOptions()
            case .settings: TVPlaybackSettingsOptions()
            }
        }
    }
}

private struct TVSubtitleOptions: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Button {
                    app.player.turnSubtitlesOff()
                    dismiss()
                } label: {
                    TVChoiceRow(title: "Off", selected: app.player.subtitleSelection == .off)
                }
                .accessibilityIdentifier("caption-off")
                ForEach(app.player.subtitleOptions) { option in
                    Button {
                        dismiss()
                        Task { await app.player.selectSubtitle(id: option.id) }
                    } label: {
                        TVChoiceRow(title: option.selection.label + (option.isForced ? " · Forced" : ""),
                                    subtitle: detail(option),
                                    selected: app.player.subtitleSelection.active?.id == option.id)
                    }
                    .disabled(!option.isAvailable)
                    .accessibilityIdentifier(identifier(option))
                }
            } footer: {
                if let notice = app.player.subtitlePreferenceNotice { Text(notice) }
            }
        }
        .navigationTitle("Subtitles")
    }

    private func detail(_ option: PlaybackSubtitleOption) -> String? {
        if !option.isAvailable { return "Unavailable on this device" }
        if app.player.subtitleSelection.requested?.id == option.id {
            if case .loading = app.player.subtitleSelection { return "Loading…" }
            if case .failed(_, let message) = app.player.subtitleSelection { return message }
        }
        return option.selection.delivery == .native ? "Included in video" : nil
    }

    private func identifier(_ option: PlaybackSubtitleOption) -> String {
        switch option.source {
        case .server(let index): "caption-track-\(index)"
        case .native, .offline: "local-caption-\(option.id)"
        }
    }
}

private struct TVAudioOptions: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let item = app.player.item
        let selected = app.player.selectedAudioIndex ?? item?.defaultAudioIndex
        List {
            ForEach(item?.audioTracks ?? []) { track in
                Button {
                    app.player.selectAudio(track.index)
                    dismiss()
                } label: {
                    TVChoiceRow(title: track.displayName,
                                subtitle: track.technicalLabel + (track.default || track.index == item?.defaultAudioIndex ? " · Default" : ""),
                                selected: track.index == selected)
                }
                .accessibilityIdentifier("server-audio-\(track.index)")
            }
        }
        .navigationTitle("Audio")
    }
}

private struct TVChapterOptions: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(app.player.chapters) { chapter in
                Button {
                    app.player.seek(toGlobalTime: chapter.startSeconds)
                    dismiss()
                } label: {
                    // The title owns its row; time and status sit beneath it.
                    TVChoiceRow(title: chapter.title,
                                subtitle: PlaybackTimeline.displayTime(chapter.startSeconds)
                                    + (chapter.id == app.player.currentChapterIndex ? " · Now playing" : ""),
                                selected: chapter.id == app.player.currentChapterIndex)
                }
                .accessibilityIdentifier("chapter-\(chapter.id)")
            }
        }
        .navigationTitle("Chapters")
    }
}

private struct TVPlaybackSettingsOptions: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: StreamingSettingsDraft?

    private static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    private var profiles: [QualityProfile] {
        app.player.qualityProfiles ?? app.library.capabilities?.qualityProfiles ?? []
    }

    var body: some View {
        List {
            Section("Viewing") {
                NavigationLink {
                    TVChoiceList(title: "Speed", options: Self.speeds.map { TVChoice(value: $0, title: Self.speedLabel($0)) },
                                 selection: app.player.playbackSpeed) { app.player.setPlaybackSpeed($0) }
                } label: { LabeledContent("Speed", value: Self.speedLabel(app.player.playbackSpeed)) }

                NavigationLink {
                    TVChoiceList(title: "Video Size", options: VideoResizeMode.allCases.map { TVChoice(value: $0, title: $0.label) },
                                 selection: app.player.resizeMode) { app.player.resizeMode = $0 }
                } label: { LabeledContent("Video Size", value: app.player.resizeMode.label) }
            }

            if app.player.item != nil, let draft {
                Section {
                    if let notice = app.player.qualityNotice { Text(notice).font(.caption) }
                    NavigationLink {
                        TVChoiceList(title: "Mode", options: PlaybackMode.allCases.map { TVChoice(value: $0, title: $0.label) },
                                     selection: draft.mode) { self.draft?.selectMode($0) }
                    } label: { LabeledContent("Mode", value: draft.mode.label) }
                    .accessibilityIdentifier("stream-mode")

                    NavigationLink {
                        TVChoiceList(title: "Quality", options: qualityOptions, selection: draft.quality) {
                            self.draft?.selectQuality($0)
                        }
                    } label: { LabeledContent("Quality", value: qualityLabel(draft.quality)) }
                    .accessibilityIdentifier("stream-quality")

                    Button("Apply Streaming Changes") {
                        if app.player.applyStreamingChanges(draft, profiles: profiles) { dismiss() }
                    }
                    .disabled(!draft.isValid(in: profiles) || draft == currentSettings)
                    .accessibilityIdentifier("stream-apply")
                } header: {
                    Text("Streaming")
                } footer: {
                    Text("Applying restarts the stream at the current position.")
                }
            }
        }
        .navigationTitle("Playback Options")
        .onAppear { if draft == nil { draft = currentSettings } }
    }

    private var currentSettings: StreamingSettingsDraft {
        StreamingSettingsDraft(mode: app.player.mode, quality: app.player.selectedQuality)
    }

    private var qualityOptions: [TVChoice<String>] {
        (profiles.contains { $0.id == "auto" } ? [] : [TVChoice(value: "auto", title: "Auto")])
            + profiles.map { TVChoice(value: $0.id, title: $0.label) }
    }

    private func qualityLabel(_ id: String) -> String {
        profiles.first { $0.id == id }?.label ?? "Auto"
    }

    private static func speedLabel(_ value: Float) -> String {
        value == 1 ? "Normal" : String(format: "%g×", value)
    }
}

/// Loading and failed subtitle choices stay visible with Retry and Off.
struct TVSubtitleFeedback: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        switch app.player.subtitleSelection {
        case .off, .active:
            EmptyView()
        case .loading(let selection):
            HStack(spacing: 24) {
                ProgressView()
                Text("Loading \(selection.label)…").font(.caption)
                Button("Off") { app.player.turnSubtitlesOff() }
                    .accessibilityLabel("Turn Subtitles Off")
            }
            .accessibilityIdentifier("subtitle-loading")
        case .failed(_, let message):
            HStack(spacing: 24) {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption)
                Button("Retry") { Task { await app.player.retrySubtitles() } }
                    .accessibilityLabel("Retry Subtitles")
                    .accessibilityIdentifier("retry-subtitles")
                Button("Off") { app.player.turnSubtitlesOff() }
                    .accessibilityLabel("Turn Subtitles Off")
            }
            .accessibilityIdentifier("subtitle-failure")
        }
    }
}
