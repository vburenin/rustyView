import SwiftUI
import UIKit

/// Reports whether the Siri Remote's left or right press is held down.
///
/// SwiftUI's move command fires once per press and has no repeat or release
/// phase, so a held direction cannot keep scrubbing through it. This observer
/// watches presses from the window, never recognizes, and never cancels or
/// delays them: focus movement and move commands behave exactly as before.
struct TVDirectionalPressObserver: UIViewRepresentable {
    /// -1 while left is held, 1 while right is held, nil once released.
    let onChange: @MainActor (Int?) -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.recognizer.onChange = onChange
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.recognizer.onChange = onChange
    }

    static func dismantleUIView(_ view: ObserverView, coordinator: ()) {
        view.detach()
    }

    final class ObserverView: UIView {
        let recognizer = DirectionalPressRecognizer()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            window?.addGestureRecognizer(recognizer)
        }

        func detach() {
            recognizer.view?.removeGestureRecognizer(recognizer)
            recognizer.releaseHeldPress()
        }
    }
}

final class DirectionalPressRecognizer: UIGestureRecognizer {
    var onChange: (@MainActor (Int?) -> Void)?
    private var held: UIPress?

    init() {
        super.init(target: nil, action: nil)
        allowedPressTypes = [UIPress.PressType.leftArrow, .rightArrow].map { NSNumber(value: $0.rawValue) }
        allowedTouchTypes = []
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        guard held == nil,
              let press = presses.first(where: { $0.type == .leftArrow || $0.type == .rightArrow })
        else { return }
        held = press
        onChange?(press.type == .leftArrow ? -1 : 1)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        release(presses)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        release(presses)
    }

    override func reset() {
        super.reset()
        releaseHeldPress()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func releaseHeldPress() {
        guard held != nil else { return }
        held = nil
        onChange?(nil)
    }

    private func release(_ presses: Set<UIPress>) {
        guard let held, presses.contains(held) else { return }
        releaseHeldPress()
        // Never claim the press; failing lets UIKit reset for the next one.
        state = .failed
    }
}
