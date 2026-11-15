import SwiftUI

struct TVRootView: View {
    @EnvironmentObject private var app: AppModel
    @State private var resolvedInitialDestination = false

    private var connectionIdentity: String {
        "\(app.client.connection?.serverIdentity ?? "")|\(app.client.connection?.username ?? "")"
    }

    /// With no server and nothing saved, connecting is the only thing the app
    /// can do, so the connection screen is its top level rather than a cover.
    /// The Siri Remote's Menu button then returns to the Home screen, as App
    /// Review expects; a cover with nowhere to return to would swallow it.
    private var connectionIsTopLevel: Bool {
        !app.isConfigured && app.userLibrary.entries.isEmpty && !app.userLibrary.isRestoring
    }

    var body: some View {
        root
            .onAppear {
                resolveInitialDestination()
                if app.isConfigured && app.library.entries.isEmpty {
                    Task { await app.library.reloadReportingErrors() }
                }
            }
            .onChange(of: app.userLibrary.isRestoring) { _, _ in resolveInitialDestination() }
            .onChange(of: app.isConfigured) { _, configured in
                app.showingConnection = false
                if configured {
                    app.selectedTab = .library
                } else if !app.userLibrary.entries.isEmpty {
                    app.selectedTab = .saved
                }
            }
            .sheet(isPresented: $app.showingCompatibilityHelp) { compatibilityHelp }
            .alert(app.presentedError?.title ?? "Something went wrong", isPresented: Binding(
                get: { app.presentedError != nil }, set: { if !$0 { app.presentedError = nil } }
            )) {
                if let error = app.presentedError {
                    ForEach(error.tvRecoveryActions.filter { $0 != .retry }) { action in
                        Button(action.title) { app.performRecovery(action) }
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(app.presentedError?.message ?? "")
            }
            .background {
                // A separate host keeps the player cover independent of the
                // connection cover attached to the tabs.
                Color.clear.fullScreenCover(isPresented: Binding(
                    get: { app.player.isPresented },
                    set: { if !$0 { app.player.stop() } }
                )) {
                    TVPlayerView()
                }
            }
    }

    @ViewBuilder
    private var root: some View {
        if connectionIsTopLevel {
            TVConnectionView(canDismiss: false)
        } else {
            tabs.fullScreenCover(isPresented: Binding(
                get: { app.showingConnection && !connectionIsTopLevel },
                set: { app.showingConnection = $0 }
            )) {
                TVConnectionView(canDismiss: true)
            }
        }
    }

    private var tabs: some View {
        TabView(selection: $app.selectedTab) {
            TVTabStack { TVLibraryView() }
                .id("library|\(connectionIdentity)")
                .tabItem { Label("Library", systemImage: "film.stack") }
                .tag(AppTab.library)

            TVTabStack { TVSearchView(client: app.client) }
                .id("search|\(connectionIdentity)")
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppTab.search)

            TVTabStack { TVMyMoviesView() }
                .tabItem { Label("My Movies", systemImage: "heart") }
                .tag(AppTab.saved)

            TVTabStack { TVSettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }

    private var compatibilityHelp: some View {
        NavigationStack {
            List {
                Text("Update rustyView or your server, then reconnect.")
                Text("rustyView needs the rustyDLNA web API schema 2 over HTTPS.")
                    .foregroundStyle(.secondary)
                Button("Edit Connection") {
                    app.showingCompatibilityHelp = false
                    app.showingConnection = true
                }
                .accessibilityIdentifier("compatibility-edit-connection")
            }
            .navigationTitle("Compatibility Help")
        }
    }

    private func resolveInitialDestination() {
        guard !resolvedInitialDestination else { return }
        if app.userLibrary.isRestoring && !app.isConfigured { return }
        resolvedInitialDestination = true
        // Without either, `connectionIsTopLevel` already shows the connection screen.
        if app.isConfigured {
            app.selectedTab = .library
        } else if !app.userLibrary.entries.isEmpty {
            app.selectedTab = .saved
        }
    }
}
