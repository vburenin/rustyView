import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showingConnection = false
    @State private var showingDisconnect = false

    var body: some View {
        List {
            Section("Server") {
                LabeledContent("Address", value: app.settings.serverAddress)
                LabeledContent("User", value: app.settings.username)
                Button("Edit Connection") { showingConnection = true }
                Button("Forget Connection", role: .destructive) { showingDisconnect = true }
            }

            Section("Playback") {
                LabeledContent("Streaming", value: "Automatic")
                Text("rustyView plays supported originals directly and asks the server for a compatible stream when needed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Offline Storage") {
                LabeledContent("Movies", value: "\(app.downloads.completed.count)")
                LabeledContent("Used", value: storageUsed)
                Text("Offline files stay on this device and are excluded from iCloud Backup.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    LabeledContent(
                        "Movie Downloads",
                        value: app.settings.allowCellularDownloads ? "Wi-Fi & Cellular" : "Wi-Fi Only"
                    )
                }
                .accessibilityIdentifier("download-network-menu")
                .accessibilityLabel("Movie Download Network")
                .accessibilityValue(app.settings.allowCellularDownloads ? "Wi-Fi and Cellular" : "Wi-Fi Only")
                .accessibilityHint("Choose whether movie downloads may use cellular data")
            } header: {
                Text("Download Network")
            } footer: {
                Text(app.settings.allowCellularDownloads
                    ? "Downloads may use Wi-Fi or cellular data."
                    : "Downloads wait for Wi-Fi and resume automatically when it is available.")
            }

            Section("About") {
                LabeledContent("API", value: "rustyDLNA schema \(RustyDLNAClient.schemaVersion)")
                LabeledContent("App", value: appVersion)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showingConnection) {
            ConnectionSetupView(canDismiss: true)
        }
        .confirmationDialog("Forget this server?", isPresented: $showingDisconnect, titleVisibility: .visible) {
            Button("Forget Connection", role: .destructive) { app.disconnect() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The saved password is removed from Keychain. Existing offline downloads remain on this device.")
        }
    }

    private var storageUsed: String {
        let bytes = app.downloads.completed.reduce(Int64(0)) { partial, record in
            partial.addingReportingOverflow(record.byteCount).overflow ? Int64.max : partial + record.byteCount
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
