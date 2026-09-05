import SwiftUI

private actor ArtworkRequests {
    static let shared = ArtworkRequests()
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if running < 4 { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
}

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
        guard let path, let request = try? client.authorizedRequest(serverPath: path),
              let url = request.url else { return }
        let key = "\(client.connection?.username ?? "")|\(url.absoluteString)" as NSString
        if let cached = ArtworkCache.shared.object(forKey: key) {
            image = cached
            return
        }
        task = Task {
            await ArtworkRequests.shared.acquire()
            do {
                try Task.checkCancellation()
                let data = try await client.data(for: request)
                try Task.checkCancellation()
                guard let decoded = UIImage(data: data) else { throw RustyDLNAError.invalidResponse }
                let pixels = decoded.size.width * decoded.size.height * decoded.scale * decoded.scale
                let cost = Int(min(CGFloat(Int.max / 2), pixels * 4))
                ArtworkCache.shared.setObject(decoded, forKey: key, cost: cost)
                image = decoded
            } catch {
                if !Task.isCancelled { failed = true }
            }
            await ArtworkRequests.shared.release()
        }
    }

    func cancel() { task?.cancel() }

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
        .task(id: "\(client.connection?.baseURL.absoluteString ?? "")|\(client.connection?.username ?? "")|\(path ?? "")") {
            model.load(path: path, client: client)
        }
        .onDisappear { model.cancel() }
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
