import SwiftUI

/// Navigation values shared by every tab's stack.
enum TVRoute: Hashable {
    /// `key` identifies a saved movie's owning server/account; nil means the
    /// current connection's library.
    case movie(MovieMetadata, key: MovieLibraryKey?)
}

/// Each tab owns its path so any focused control, including a context menu
/// action, can open a destination in the current tab.
struct TVTabStack<Content: View>: View {
    @State private var path = NavigationPath()
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack(path: $path) {
            content()
                .navigationDestination(for: TVRoute.self) { TVRouteDestination(route: $0) }
        }
        .environment(\.tvNavigate, TVNavigateAction { path.append($0) })
    }
}

struct TVNavigateAction {
    let push: (TVRoute) -> Void
    func callAsFunction(_ route: TVRoute) { push(route) }
}

private struct TVNavigateKey: EnvironmentKey {
    static let defaultValue = TVNavigateAction { _ in }
}

extension EnvironmentValues {
    var tvNavigate: TVNavigateAction {
        get { self[TVNavigateKey.self] }
        set { self[TVNavigateKey.self] = newValue }
    }
}

struct TVRouteDestination: View {
    let route: TVRoute

    var body: some View {
        switch route {
        case .movie(let movie, let key): TVMovieDetailView(movie: movie, savedKey: key)
        }
    }
}

struct TVChoice<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var subtitle: String? = nil
    var isEnabled = true
    var identifier = ""
    var id: Value { value }
}

/// One row per choice, as in Apple TV Settings. Choosing applies and returns.
struct TVChoiceList<Value: Hashable>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let options: [TVChoice<Value>]
    let selection: Value
    var footer: String? = nil
    let onSelect: (Value) -> Void

    var body: some View {
        List {
            Section {
                ForEach(options) { option in
                    Button {
                        onSelect(option.value)
                        dismiss()
                    } label: {
                        TVChoiceRow(title: option.title, subtitle: option.subtitle, selected: option.value == selection)
                    }
                    .disabled(!option.isEnabled)
                    .accessibilityIdentifier(option.identifier)
                }
            } footer: {
                if let footer { Text(footer) }
            }
        }
        .navigationTitle(title)
    }
}

struct TVChoiceRow: View {
    let title: String
    var subtitle: String? = nil
    let selected: Bool

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension UserFacingError {
    /// Apple TV has no offline copies or storage manager to send someone to.
    var tvRecoveryActions: [RecoveryAction] {
        recoveryActions(hasDownloads: false).filter { $0 != .watchDownloads && $0 != .manageStorage }
    }
}

extension AppModel {
    func performRecovery(_ action: RecoveryAction) {
        switch action {
        case .editConnection: showingConnection = true
        case .compatibilityHelp: showingCompatibilityHelp = true
        case .retry, .watchDownloads, .manageStorage: break
        }
    }
}

struct TVErrorRecoveryView: View {
    @EnvironmentObject private var app: AppModel
    let error: UserFacingError
    var isRetrying = false
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 64)).accessibilityHidden(true)
            Text(error.title).font(.title3.bold()).multilineTextAlignment(.center)
            Text(error.message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 1100)
            HStack(spacing: 32) {
                ForEach(error.tvRecoveryActions) { action in
                    if action == .retry {
                        if let retry {
                            Button(action: retry) {
                                if isRetrying { Label("Retrying…", systemImage: "hourglass") }
                                else { Label(action.title, systemImage: action.systemImage) }
                            }
                            .disabled(isRetrying)
                        }
                    } else {
                        Button { app.performRecovery(action) } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(48)
    }
}

/// Unsaved favorites, history or progress stay visible with a retry rather
/// than silently disappearing.
struct TVUserLibraryRecoveryBanner: View {
    @EnvironmentObject private var app: AppModel
    @State private var isRetrying = false

    var body: some View {
        if let failure = app.userLibrary.persistenceError {
            let error = UserFacingError(failure)
            HStack(spacing: 32) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Changes not saved").font(.headline)
                        Text(error.message).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "exclamationmark.triangle") }
                Spacer(minLength: 24)
                Button(isRetrying ? "Retrying…" : "Retry") {
                    guard !isRetrying else { return }
                    isRetrying = true
                    Task {
                        // flush retains the current failure for this banner.
                        try? await app.userLibrary.flush()
                        isRetrying = false
                    }
                }
                .disabled(isRetrying)
            }
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .accessibilityIdentifier("user-library-recovery")
        }
    }
}

struct TVConnectPrompt: View {
    @EnvironmentObject private var app: AppModel
    var message = "Connect to your rustyDLNA server to browse and watch your movies."

    var body: some View {
        ContentUnavailableView {
            Label("Connect to your server", systemImage: "network.slash")
        } description: {
            Text(message)
        } actions: {
            Button("Connect") { app.showingConnection = true }
                .accessibilityIdentifier("connect-prompt")
            if !app.userLibrary.entries.isEmpty {
                Button("My Movies") { app.selectedTab = .saved }
            }
        }
    }
}

/// Poster artwork with an optional viewing-progress bar. Callers wrap it in a
/// card-style Button or NavigationLink so the focus engine can lift it.
struct TVPosterArtwork: View {
    @EnvironmentObject private var app: AppModel
    let artworkPath: String?
    var isFolder = false
    var progress: Double? = nil

    var body: some View {
        PosterFrame {
            if isFolder {
                ZStack {
                    Rectangle().fill(.orange.opacity(0.16))
                    Image(systemName: "folder.fill").font(.system(size: 96)).foregroundStyle(.orange)
                }
            } else {
                AuthenticatedArtworkView(path: artworkPath, client: app.client)
            }
        }
        .overlay(alignment: .bottom) {
            if let progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.black.opacity(0.55))
                        Capsule().fill(Color("AccessibleAccent"))
                            .frame(width: proxy.size.width * min(1, max(0, progress)))
                    }
                }
                .frame(height: 8)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .accessibilityHidden(true)
            }
        }
    }
}

/// A focusable poster with its title beneath, as in the TV app.
struct TVPosterCell<Interactive: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let interactive: () -> Interactive

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            interactive()
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium)).lineLimit(2)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

enum TVLayout {
    static let posterColumns = [GridItem(.adaptive(minimum: 230, maximum: 290), spacing: 48, alignment: .top)]
    static let shelfPosterWidth: CGFloat = 230
}
