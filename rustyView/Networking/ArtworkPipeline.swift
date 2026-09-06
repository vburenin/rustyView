import ImageIO
import UIKit

/// The actor owns the cache, fair transfer admission, and eager thumbnail
/// decoding. Suspended network requests do not prevent cancellation of waiters.
actor ArtworkPipeline {
    static let shared = ArtworkPipeline()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var active: Set<UUID> = []
    private var waiting: [Waiter] = []
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()

    func image(for request: URLRequest, client: RustyDLNAClient, owner: ServerConnection) async throws -> UIImage {
        try Task.checkCancellation()
        guard let url = request.url, client.connection == owner else { throw CancellationError() }
        let key = "\(owner.serverIdentity)|\(owner.username)|\(url.absoluteString)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let ticket = UUID()
        try await acquire(ticket)
        do {
            try Task.checkCancellation()
            guard client.connection == owner else { throw CancellationError() }
            // Another transfer may have filled this cache while this one waited.
            if let image = cache.object(forKey: key) {
                release(ticket)
                return image
            }
            let data = try await client.data(for: request, owner: owner)
            try Task.checkCancellation()
            let image = try autoreleasepool { try Self.decode(data) }
            try Task.checkCancellation()
            guard client.connection == owner else { throw CancellationError() }
            if let raster = image.cgImage {
                cache.setObject(image, forKey: key, cost: raster.bytesPerRow * raster.height)
            }
            release(ticket)
            return image
        } catch {
            release(ticket)
            throw error
        }
    }

    private func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if active.count < 4 {
                    active.insert(id)
                    continuation.resume()
                } else {
                    waiting.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        guard !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        active.insert(next.id)
        next.continuation.resume()
    }

    private static func decode(_ data: Data) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1_024,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw RustyDLNAError.invalidResponse }
        return UIImage(cgImage: thumbnail)
    }
}
