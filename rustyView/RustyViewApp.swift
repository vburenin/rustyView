import SwiftUI

@main
struct RustyViewApp: App {
    @UIApplicationDelegateAdaptor(RustyViewAppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                #if DEBUG && targetEnvironment(simulator)
                .preferredColorScheme(testColorScheme)
                #endif
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    private var testColorScheme: ColorScheme? {
        guard let namespace = ProcessInfo.processInfo.environment["RUSTYVIEW_TEST_NAMESPACE"],
              UUID(uuidString: namespace) != nil else { return nil }
        // iOS does not apply this macOS preference to UIKit automatically.
        // Only an isolated UI-test launch may request an appearance override.
        switch UserDefaults.standard.string(forKey: "AppleInterfaceStyle") {
        case "Dark": return .dark
        case "Light": return .light
        default: return nil
        }
    }
    #endif
}
