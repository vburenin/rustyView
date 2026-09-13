import Foundation

/// Preparation measures server work; transferred bytes measure delivery to this device.
struct DownloadProgressPresentation {
    let phase: DownloadPhase
    let preparation: DownloadPreparationProgress?

    var activePreparation: DownloadPreparationProgress? {
        switch phase {
        case .queued, .preparing, .downloading:
            guard let preparation, !preparation.isComplete, preparation.fraction < 1 else { return nil }
            return preparation
        default: return nil
        }
    }

    var fraction: Double? { activePreparation?.fraction ?? phase.progress }

    var percent: Int? {
        fraction.map { Int((min(1, max(0, $0)) * 100).rounded(.down)) }
    }

    var byteText: String? {
        guard case .downloading(_, let received, let expected) = phase else { return nil }
        let bytes = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard let expected, expected > 0 else { return "\(bytes) downloaded" }
        let total = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
        return "\(bytes) of \(total)"
    }

    var remainingByteText: String? {
        guard case .downloading(_, let received, let expected) = phase,
              let expected, expected > 0 else { return nil }
        let remaining = ByteCountFormatter.string(fromByteCount: max(0, expected - max(0, received)), countStyle: .file)
        return "\(remaining) remaining"
    }
}
