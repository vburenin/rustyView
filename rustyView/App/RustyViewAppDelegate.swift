import UIKit

@MainActor
final class BackgroundSessionEvents {
    static let shared = BackgroundSessionEvents()
    private var completionHandler: (() -> Void)?

    func store(_ completionHandler: @escaping () -> Void) {
        self.completionHandler?()
        self.completionHandler = completionHandler
    }

    func finish() {
        let handler = completionHandler
        completionHandler = nil
        handler?()
    }
}

final class RustyViewAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            BackgroundSessionEvents.shared.store(completionHandler)
        }
    }
}
