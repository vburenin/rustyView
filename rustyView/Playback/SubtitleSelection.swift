import Foundation

enum SubtitleDelivery: Equatable, Sendable {
    case native
    case appOverlay
}

/// Stable across an internal retry, scoped to the current movie's options.
/// The view never treats a server index as a native AV selection identifier.
struct SubtitleSelection: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let delivery: SubtitleDelivery
}

enum SubtitleSelectionState: Equatable, Sendable {
    case off
    case loading(SubtitleSelection)
    case active(SubtitleSelection)
    case failed(SubtitleSelection, message: String)

    var requested: SubtitleSelection? {
        switch self {
        case .off: nil
        case .loading(let selection), .active(let selection), .failed(let selection, _): selection
        }
    }

    var active: SubtitleSelection? {
        guard case .active(let selection) = self else { return nil }
        return selection
    }

    var accessibilityValue: String {
        switch self {
        case .off: "Off"
        case .loading(let selection): "Loading \(selection.label)"
        case .active(let selection): selection.label
        case .failed(let selection, _): "\(selection.label) unavailable"
        }
    }
}

/// Maps view-facing identifiers to a source that must still be owned by the
/// active movie before asynchronous work starts or commits.
enum SubtitleSource: Equatable, Sendable {
    case server(index: Int)
    case native(optionID: String)
    case offline(captionID: UUID)
}

struct PlaybackSubtitleOption: Identifiable, Equatable, Sendable {
    let selection: SubtitleSelection
    let source: SubtitleSource
    let language: String?
    let isForced: Bool
    let isAvailable: Bool
    var id: String { selection.id }
}
