import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingDisconnect = false

    var body: some View {
        List {
            Section {
                connectionValue("Address", value: app.settings.serverAddress)
                connectionValue("User", value: app.settings.username)
                Button("Edit Connection") { app.showingConnection = true }
                Button(role: .destructive) { showingDisconnect = true } label: {
                    Text("Forget Connection")
                        .foregroundStyle(colorScheme == .dark ? Color.red : Color(red: 0.72, green: 0.08, blue: 0.06))
                }
            } header: {
                sectionTitle("Server")
            }

            Section {
                SelectionPicker(title: "Quality", selection: Binding(
                        get: { app.playbackPreferences.preferredQualityID },
                        set: { app.playbackPreferences.preferredQualityID = $0 }
                    ), options: qualityOptions, listIdentifier: "quality-choice-list") {
                    preferenceLabel("Quality", value: qualityLabel)
                }
                .accessibilityIdentifier("preferred-quality")
                .accessibilityLabel("Quality")
                .accessibilityValue(qualityLabel)
                if app.library.capabilities != nil, let notice = qualityResolution.notice {
                    Text(notice).font(.footnote).foregroundStyle(Color.primary.opacity(0.75))
                }
                SelectionPicker(title: "Audio Language", selection: Binding(
                        get: { app.playbackPreferences.preferredAudioLanguage },
                        set: { app.playbackPreferences.preferredAudioLanguage = $0 }
                    ), options: [SelectionOption(value: String?.none, title: "Default")]
                        + audioLanguages.map { SelectionOption(value: Optional($0),
                            title: Locale.current.localizedString(forLanguageCode: $0) ?? $0) },
                    listIdentifier: "audio-language-list") {
                    preferenceLabel("Audio language", value: audioLanguageLabel)
                }
                .accessibilityIdentifier("preferred-audio-language")
                .accessibilityLabel("Audio language")
                .accessibilityValue(audioLanguageLabel)
                Text("Applies to your next movie. Lower quality uses less data.")
                    .font(.footnote).foregroundStyle(Color.primary.opacity(0.75))
            } header: {
                sectionTitle("Playback")
            }

            Section {
                LabeledContent("Saved copies") {
                    Text("\(app.downloads.completed.count)").foregroundStyle(Color.primary.opacity(0.75))
                }
                LabeledContent("Storage used") {
                    Text(storageUsed).foregroundStyle(Color.primary.opacity(0.75))
                }
                Text("Offline copies aren’t included in iCloud Backup.")
                    .font(.footnote)
                    .foregroundStyle(Color.primary.opacity(0.75))
            } header: {
                sectionTitle("Offline Storage")
            }

            Section {
                Menu {
                    Button {
                        app.settings.allowCellularDownloads = true
                    } label: {
                        HStack {
                            Text("Wi-Fi & Cellular")
                            if app.settings.allowCellularDownloads { Image(systemName: "checkmark") }
                        }
                    }
                    Button {
                        app.settings.allowCellularDownloads = false
                    } label: {
                        HStack {
                            Text("Wi-Fi Only")
                            if !app.settings.allowCellularDownloads { Image(systemName: "checkmark") }
                        }
                    }
                } label: {
                    preferenceLabel(
                        "Network",
                        value: app.settings.allowCellularDownloads ? "Wi-Fi & Cellular" : "Wi-Fi Only"
                    )
                }
                .accessibilityIdentifier("download-network-menu")
                .accessibilityLabel("Movie Download Network")
                .accessibilityValue(app.settings.allowCellularDownloads ? "Wi-Fi and Cellular" : "Wi-Fi Only")
                .accessibilityHint("Choose whether movie downloads may use cellular data")
            } header: {
                sectionTitle("Downloads")
            } footer: {
                if !app.settings.allowCellularDownloads {
                    Text("Downloads resume when Wi-Fi is available.")
                        .foregroundStyle(Color.primary.opacity(0.75))
                }
            }

            Section {
                LabeledContent("App") {
                    Text(appVersion).foregroundStyle(Color.primary.opacity(0.75))
                }
                Link(destination: URL(string: "https://rustyview-support.vburenin.chatgpt.site/privacy")!) {
                    Text("Privacy Policy")
                        .foregroundStyle(Color.primary)
                        .underline()
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
            } header: {
                sectionTitle("About")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Forget this server?", isPresented: $showingDisconnect, titleVisibility: .visible) {
            Button("Forget Connection", role: .destructive) { app.disconnect() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your saved password will be removed. Downloads stay on this device.")
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).foregroundStyle(Color.primary.opacity(0.75))
    }

    private var qualityResolution: PlaybackQualityResolution {
        app.playbackPreferences.quality(in: app.library.capabilities?.qualityProfiles ?? [])
    }

    private var qualityOptions: [SelectionOption<String>] {
        [SelectionOption(value: "auto", title: "Auto")]
            + (app.library.capabilities?.qualityProfiles.filter { $0.id != "auto" } ?? [])
                .map { SelectionOption(value: $0.id, title: $0.label) }
            + (qualityResolution.notice == nil ? [] : [SelectionOption(
                value: app.playbackPreferences.preferredQualityID, title: "Saved quality")])
    }

    private var qualityLabel: String {
        if app.playbackPreferences.preferredQualityID == "auto" { return "Auto" }
        return app.library.capabilities?.qualityProfiles.first {
            $0.id == app.playbackPreferences.preferredQualityID
        }?.label.components(separatedBy: " · ").first ?? "Saved quality"
    }

    private var audioLanguageLabel: String {
        guard let language = app.playbackPreferences.preferredAudioLanguage else { return "Default" }
        return Locale.current.localizedString(forLanguageCode: language) ?? language
    }

    @ViewBuilder
    private func connectionValue(_ title: String, value: String) -> some View {
        if value.isEmpty {
            EmptyView()
        } else {
            settingsValueLabel(title, value: value)
                .accessibilityElement(children: .combine)
        }
    }

    private func preferenceLabel(_ title: String, value: String) -> some View {
        settingsValueLabel(title, value: value)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func settingsValueLabel(_ title: String, value: String) -> some View {
        let isAccessibility = dynamicTypeSize.isAccessibilitySize
        // Preserve the text elements when Dynamic Type changes the layout.
        let layout = isAccessibility
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            Text(title)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Text(value)
                .foregroundStyle(Color.primary.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: isAccessibility ? .leading : .trailing)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var audioLanguages: [String] {
        var values = Set(["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "ru", "uk", "ar", "hi"])
        if let saved = app.playbackPreferences.preferredAudioLanguage { values.insert(saved) }
        return values.sorted {
            (Locale.current.localizedString(forLanguageCode: $0) ?? $0)
                .localizedStandardCompare(Locale.current.localizedString(forLanguageCode: $1) ?? $1) == .orderedAscending
        }
    }

    private var storageUsed: String {
        ByteCountFormatter.string(fromByteCount: app.downloads.totalStoredBytes, countStyle: .file)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
