import SwiftUI

@MainActor
final class ArtworkModel: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    func load(path: String?, client: RustyDLNAClient) {
        cancel()
        image = nil
        failed = false
        guard let path, let owner = client.connection,
              let url = try? owner.resolve(serverPath: path) else { return }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.setValue(owner.authorizationHeader(), forHTTPHeaderField: "Authorization")
        let requestGeneration = generation
        task = Task { [weak self] in
            do {
                let decoded = try await ArtworkPipeline.shared.image(for: request, client: client, owner: owner)
                guard !Task.isCancelled, let self, self.generation == requestGeneration,
                      client.connection == owner else { return }
                self.image = decoded
            } catch {
                guard !Task.isCancelled, let self, self.generation == requestGeneration,
                      client.connection == owner else { return }
                self.failed = true
            }
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
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
