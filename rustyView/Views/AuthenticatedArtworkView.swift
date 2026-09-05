import SwiftUI

private final class ArtworkCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()
}

@MainActor
final class ArtworkModel: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    private var task: Task<Void, Never>?

    func load(path: String?, client: RustyDLNAClient) {
        task?.cancel()
        image = nil
        failed = false
        guard let path else { return }
        if let cached = ArtworkCache.shared.object(forKey: path as NSString) {
            image = cached
            return
        }
        task = Task {
            do {
                let data = try await client.data(serverPath: path)
                try Task.checkCancellation()
                guard let decoded = UIImage(data: data) else { throw RustyDLNAError.invalidResponse }
                ArtworkCache.shared.setObject(decoded, forKey: path as NSString, cost: data.count)
                image = decoded
            } catch is CancellationError {
                return
            } catch {
                failed = true
            }
        }
    }

    deinit { task?.cancel() }
}

struct AuthenticatedArtworkView: View {
    let path: String?
    let client: RustyDLNAClient
    @StateObject private var model = ArtworkModel()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.quaternary)
            if let image = model.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: model.failed ? "photo.badge.exclamationmark" : "film.stack")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityHidden(true)
        .task(id: path) { model.load(path: path, client: client) }
    }
}

/// Owns the poster's layout so unusually large or wide artwork cannot resize a
/// grid cell. The artwork is placed in an overlay because overlays receive the
/// resolved frame but do not contribute an intrinsic size of their own.
struct PosterFrame<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .contentShape(Rectangle())
    }
}
