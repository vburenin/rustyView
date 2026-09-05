import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @State private var selectedTab = AppTab.library
    @State private var showingSetup = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                LibraryView()
            }
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
            showingSetup = !app.isConfigured
            if app.isConfigured && app.library.entries.isEmpty {
                Task { await app.library.reloadReportingErrors() }
            }
        }
        .onChange(of: app.isConfigured) { _, configured in
            showingSetup = !configured
            if configured { selectedTab = .library }
        }
        .sheet(isPresented: $showingSetup) {
            ConnectionSetupView(canDismiss: app.isConfigured)
                .interactiveDismissDisabled(!app.isConfigured)
        }
        .fullScreenCover(isPresented: Binding(
            get: { app.player.isPresented },
            set: { if !$0 { app.player.stop() } }
        )) {
            PlayerScreen()
        }
        .alert(item: $app.presentedError) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
    }
}

private enum AppTab: Hashable {
    case library
    case downloads
    case settings
}
