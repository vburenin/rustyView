import SwiftUI

struct TVSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showingDisconnect = false

    var body: some View {
        List {
            Section("Server") {
                if !app.settings.serverAddress.isEmpty {
                    LabeledContent("Address", value: app.settings.serverAddress)
                }
                if !app.settings.username.isEmpty {
                    LabeledContent("User", value: app.settings.username)
                }
                Button(app.isConfigured ? "Edit Connection" : "Connect") { app.showingConnection = true }
                    .accessibilityIdentifier("settings-edit-connection")
                if app.isConfigured || !app.settings.serverAddress.isEmpty {
                    Button("Forget Connection", role: .destructive) { showingDisconnect = true }
                }
            }

            Section {
                NavigationLink {
                    TVChoiceList(title: "Quality", options: qualityOptions,
                                 selection: app.playbackPreferences.preferredQualityID) {
                        app.playbackPreferences.preferredQualityID = $0
                    }
                } label: { LabeledContent("Quality", value: qualityLabel) }
                .accessibilityIdentifier("preferred-quality")

                NavigationLink {
                    TVChoiceList(title: "Audio Language", options: [TVChoice(value: String?.none, title: "Default")]
                        + languages.map { TVChoice(value: Optional($0), title: languageName($0)) },
                                 selection: app.playbackPreferences.preferredAudioLanguage) {
                        app.playbackPreferences.preferredAudioLanguage = $0
                    }
                } label: {
                    LabeledContent("Audio Language",
                                   value: app.playbackPreferences.preferredAudioLanguage.map(languageName) ?? "Default")
                }
                .accessibilityIdentifier("preferred-audio-language")

                NavigationLink {
                    TVChoiceList(title: "Subtitles", options: SubtitlePreferenceMode.allCases.map {
                        TVChoice(value: $0, title: $0.label)
                    }, selection: app.playbackPreferences.subtitleMode) {
                        app.playbackPreferences.subtitleMode = $0
                    }
                } label: { LabeledContent("Subtitles", value: app.playbackPreferences.subtitleMode.label) }
                .accessibilityIdentifier("preferred-subtitles")

                if app.playbackPreferences.subtitleMode == .always {
                    NavigationLink {
                        TVChoiceList(title: "Subtitle Language", options: [TVChoice(value: String?.none, title: "Automatic")]
                            + languages.map { TVChoice(value: Optional($0), title: languageName($0)) },
                                     selection: app.playbackPreferences.preferredSubtitleLanguage) {
                            app.playbackPreferences.preferredSubtitleLanguage = $0
                        }
                    } label: {
                        LabeledContent("Subtitle Language",
                                       value: app.playbackPreferences.preferredSubtitleLanguage.map(languageName) ?? "Automatic")
                    }
                    .accessibilityIdentifier("preferred-subtitle-language")
                }
            } header: {
                Text("Playback")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if app.library.capabilities != nil, let notice = qualityResolution.notice { Text(notice) }
                    Text("Applies to your next movie. Lower quality uses less data. Automatic subtitles follow the video’s defaults and your Apple TV caption settings.")
                }
            }

            Section("About") {
                LabeledContent("App", value: appVersion)
                LabeledContent("Privacy Policy", value: "rustyview-support.vburenin.chatgpt.site/privacy")
            }
        }
        .navigationTitle("Settings")
        .alert("Forget this server?", isPresented: $showingDisconnect) {
            Button("Forget Connection", role: .destructive) { app.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your saved password will be removed from this Apple TV.")
        }
    }

    private var qualityResolution: PlaybackQualityResolution {
        app.playbackPreferences.quality(in: app.library.capabilities?.qualityProfiles ?? [])
    }

    private var qualityOptions: [TVChoice<String>] {
        [TVChoice(value: "auto", title: "Auto")]
            + (app.library.capabilities?.qualityProfiles.filter { $0.id != "auto" } ?? []).map { TVChoice(value: $0.id, title: $0.label) }
            + (qualityResolution.notice == nil ? [] : [TVChoice(value: app.playbackPreferences.preferredQualityID,
                                                                title: "Saved quality")])
    }

    private var qualityLabel: String {
        if app.playbackPreferences.preferredQualityID == "auto" { return "Auto" }
        return app.library.capabilities?.qualityProfiles.first { $0.id == app.playbackPreferences.preferredQualityID }?
            .label.components(separatedBy: " · ").first ?? "Saved quality"
    }

    private var languages: [String] {
        var values = Set(["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "ru", "uk", "ar", "hi"])
        if let saved = app.playbackPreferences.preferredAudioLanguage { values.insert(saved) }
        if let saved = app.playbackPreferences.preferredSubtitleLanguage { values.insert(saved) }
        return values.sorted { languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending }
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
