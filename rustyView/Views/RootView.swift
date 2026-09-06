import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @State private var resolvedInitialDestination = false

    var body: some View {
        TabView(selection: $app.selectedTab) {
            NavigationStack {
                LibraryView()
            }
            .id("\(app.client.connection?.serverIdentity ?? "")|\(app.client.connection?.username ?? "")")
            .tabItem { Label("Library", systemImage: "rectangle.stack.fill") }
            .tag(AppTab.library)

            NavigationStack {
                DownloadsView()
            }
            .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
            .badge(app.downloads.active.count)
            .tag(AppTab.downloads)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(AppTab.settings)
        }
        .tint(Color("AccessibleAccent"))
        .onAppear {
            resolveInitialDestination()
            if app.isConfigured && app.library.entries.isEmpty {
                Task { await app.library.reloadReportingErrors() }
            }
        }
        .onChange(of: app.downloads.isRestoring) { _, _ in
            resolveInitialDestination()
        }
        .onChange(of: app.isConfigured) { _, configured in
            if configured {
                app.showingConnection = false
                app.selectedTab = .library
            } else if hasLocalWork {
                app.showingConnection = false
                app.selectedTab = .downloads
            } else if !app.downloads.isRestoring {
                app.showingConnection = true
            }
        }
        .sheet(isPresented: $app.showingConnection) {
            ConnectionSetupView(canDismiss: app.isConfigured || hasLocalWork)
                .interactiveDismissDisabled(!app.isConfigured && !hasLocalWork)
        }
        .sheet(isPresented: $app.showingCompatibilityHelp) {
            NavigationStack {
                List {
                    Text("Update rustyView or your server, then reconnect.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button { app.showingCompatibilityHelp = false; app.showingConnection = true } label: {
                        Text("Edit Connection").fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("compatibility-edit-connection")
                    Button { app.showingCompatibilityHelp = false; app.selectedTab = .downloads } label: {
                        Text("Watch Downloads").fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("compatibility-watch-downloads")
                    DisclosureGroup {
                        Text("rustyDLNA web API schema 2 over HTTPS.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } label: {
                        Text("Server requirements").fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                    }
                }
                .navigationTitle("Compatibility Help")
                .toolbar { Button("Done") { app.showingCompatibilityHelp = false } }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { app.player.isPresented },
            set: { if !$0 { app.player.stop() } }
        )) {
            PlayerScreen()
        }
        .alert(app.presentedError?.title ?? "Something went wrong", isPresented: Binding(
            get: { app.presentedError != nil }, set: { if !$0 { app.presentedError = nil } }
        )) {
            if let error = app.presentedError {
                ForEach(error.recoveryActions(hasDownloads: app.downloads.completed.contains(where: \.isReadyToWatch)).filter { $0 != .retry }) { action in
                    Button(action.title) { app.performRecovery(action) }
                }
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text(app.presentedError?.message ?? "")
        }
    }

    private var hasLocalWork: Bool {
        !app.downloads.completed.isEmpty || !app.downloads.active.isEmpty
    }

    private func resolveInitialDestination() {
        guard !resolvedInitialDestination else { return }
        if app.downloads.isRestoring && !app.isConfigured {
            app.selectedTab = .downloads
            return
        }
        resolvedInitialDestination = true
        if app.isConfigured {
            app.selectedTab = .library
        } else if hasLocalWork {
            app.selectedTab = .downloads
        } else {
            app.showingConnection = true
        }
    }
}
