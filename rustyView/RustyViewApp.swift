import SwiftUI

@main
struct RustyViewApp: App {
    @UIApplicationDelegateAdaptor(RustyViewAppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
        }
    }
}
