import UIKit

@MainActor
final class BackgroundSessionEvents {
    static let shared = BackgroundSessionEvents()
    private var handlers: [String: [() -> Void]] = [:]
    private var reconnect: ((String) -> Void)?

    func register(reconnect: @escaping (String) -> Void) {
        self.reconnect = reconnect
        for identifier in handlers.keys { reconnect(identifier) }
    }

    func store(identifier: String, _ completionHandler: @escaping () -> Void) {
        handlers[identifier, default: []].append(completionHandler)
        reconnect?(identifier)
    }

    func finish(identifier: String) {
        let callbacks = handlers.removeValue(forKey: identifier) ?? []
        for callback in callbacks { callback() }
    }
}

final class RustyViewAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            BackgroundSessionEvents.shared.store(identifier: identifier, completionHandler)
        }
    }
}
