import SwiftUI

@main
struct RustyViewTVApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environmentObject(appModel)
        }
    }
}
