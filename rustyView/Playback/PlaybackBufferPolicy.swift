import Foundation

/// AVFoundation keeps forward-buffered network media in memory. A platform
/// policy sizes `AVPlayerItem.preferredForwardBufferDuration` from a fixed byte
/// budget and the stream's estimated bitrate, so a modest stream can buffer
/// minutes ahead while a high-bitrate remux cannot claim unbounded memory.
/// A policy without a budget leaves AVFoundation's automatic choice in place.
struct PlaybackBufferPolicy: Equatable, Sendable {
    var memoryBudgetBytes: Int64?
    var minimumSeconds: Double = 30
    var maximumSeconds: Double = 300
    var unknownBitrateSeconds: Double = 120

    static let automatic = Self(memoryBudgetBytes: nil)

    static var platformDefault: Self {
        #if os(tvOS)
        // Apple TV is a stationary streaming device with more memory than a
        // phone. A deeper window rides out Wi-Fi and server preparation stalls.
        Self(memoryBudgetBytes: 512 * 1_024 * 1_024)
        #else
        .automatic
        #endif
    }

    /// Seconds for `preferredForwardBufferDuration`; zero requests AVFoundation's
    /// automatic buffering.
    func forwardBufferDuration(bitsPerSecond: Double?) -> TimeInterval {
        guard let memoryBudgetBytes, memoryBudgetBytes > 0 else { return 0 }
        guard let bitsPerSecond, bitsPerSecond.isFinite, bitsPerSecond > 0 else {
            return min(maximumSeconds, max(minimumSeconds, unknownBitrateSeconds))
        }
        let seconds = (Double(memoryBudgetBytes) * 8 / bitsPerSecond).rounded(.down)
        return min(maximumSeconds, max(minimumSeconds, seconds))
    }

    /// The source's average bitrate bounds a copied stream. A prepared quality
    /// profile can only lower it, so the smaller known value is used.
    static func estimatedBitsPerSecond(item: MediaItem, profile: QualityProfile?) -> Double? {
        var source: Double?
        if let duration = item.durationSeconds, duration > 0, item.sizeBytes > 0 {
            source = Double(item.sizeBytes) * 8 / Double(duration)
        }
        let prepared = profile.flatMap { $0.expectedBandwidthKbps > 0 ? Double($0.expectedBandwidthKbps) * 1_000 : nil }
        switch (source, prepared) {
        case let (source?, prepared?): return min(source, prepared)
        case let (source?, nil): return source
        case let (nil, prepared?): return prepared
        case (nil, nil): return nil
        }
    }
}
