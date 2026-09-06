import ImageIO
import SwiftUI

/// All file reads and thumbnail decoding happen serially off the main actor.
/// Package URLs are immutable, app-owned files supplied by the download store.
private actor LocalArtworkImages {
    static let shared = LocalArtworkImages()
    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 24 * 1_024 * 1_024
        return cache
    }()

    func image(at url: URL) -> UIImage? {
        guard url.isFileURL, !Task.isCancelled else { return nil }
        if let image = cache.object(forKey: url as NSURL) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary), !Task.isCancelled,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 600,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary), !Task.isCancelled else { return nil }
        let image = UIImage(cgImage: thumbnail)
        cache.setObject(image, forKey: url as NSURL,
                        cost: thumbnail.bytesPerRow * thumbnail.height)
        return image
    }
}

struct LocalArtworkView: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "film.stack")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await LocalArtworkImages.shared.image(at: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
