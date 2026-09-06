import SwiftUI

struct ClearSearchButton: View {
    @Environment(\.dismissSearch) private var dismissSearch
    let clear: () -> Void
    var body: some View {
        Button { dismissSearch(); clear() } label: {
            Text("Clear Search").frame(minWidth: 44, minHeight: 44)
        }
    }
}

struct ErrorRecoveryView: View {
    @EnvironmentObject private var app: AppModel
    let error: UserFacingError
    var isRetrying = false
    var recoveryAction: ((RecoveryAction) -> Void)? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(error.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(error.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            ForEach(error.recoveryActions(hasDownloads: app.downloads.completed.contains(where: \.isReadyToWatch))) { action in
                if action != .retry || retry != nil {
                    Button {
                        if action == .retry { retry?() }
                        else if let recoveryAction { recoveryAction(action) }
                        else { app.performRecovery(action) }
                    } label: {
                        Group {
                            if action == .retry && isRetrying {
                                HStack { ProgressView(); Text("Retrying…") }
                            } else {
                                Label(action.title, systemImage: action.systemImage)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(action == .retry && isRetrying)
                }
            }
        }
    }
}

/// Keeps a persistent error reachable without reserving the viewport for its
/// explanation. Navigation actions wait until this sheet has closed.
struct RecoveryBanner<Details: View>: View {
    @EnvironmentObject private var app: AppModel
    @State private var showingDetails = false
    @State private var pendingAction: RecoveryAction?
    let title: String
    let identifier: String
    let details: (@escaping (RecoveryAction) -> Void) -> Details

    init(_ title: String, identifier: String,
         @ViewBuilder details: @escaping (@escaping (RecoveryAction) -> Void) -> Details) {
        self.title = title
        self.identifier = identifier
        self.details = details
    }

    var body: some View {
        Button { showingDetails = true } label: {
            HStack {
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .background(.regularMaterial, ignoresSafeAreaEdges: [])
        .accessibilityIdentifier(identifier)
        .accessibilityHint("Shows the error and recovery options")
        .sheet(isPresented: $showingDetails, onDismiss: {
            if let action = pendingAction {
                pendingAction = nil
                app.performRecovery(action)
            }
        }) {
            NavigationStack {
                ScrollView {
                    details { action in
                        pendingAction = action
                        showingDetails = false
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingDetails = false }
                    }
                }
            }
        }
    }
}

struct DownloadStorageRecoveryDetails: View {
    @EnvironmentObject private var app: AppModel
    @State private var isRetrying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = app.downloads.errorMessage {
                Text(error).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if isRetrying || app.downloads.isRestoring {
                ProgressView("Restoring downloads…")
                    .fixedSize(horizontal: false, vertical: true)
            } else if app.downloads.storageRecoveryAvailable {
                Button { retry(app.downloads.recoverStorageIndex) } label: {
                    Text("Recover Saved Files").fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("ActionFill"))
            } else if app.downloads.storageRetryAvailable {
                Button { retry(app.downloads.retryStorageRestoration) } label: {
                    Text("Retry Loading Downloads").fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("ActionFill"))
            } else {
                Button { app.downloads.errorMessage = nil } label: {
                    Text("Dismiss").frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func retry(_ action: () -> Void) {
        guard !isRetrying else { return }
        isRetrying = true
        action()
        Task {
            await app.downloads.waitForPendingOperations()
            isRetrying = false
        }
    }
}

extension AppModel {
    func performRecovery(_ action: RecoveryAction) {
        switch action {
        case .editConnection: showingConnection = true
        case .watchDownloads, .manageStorage: selectedTab = .downloads
        case .compatibilityHelp:
            showingCompatibilityHelp = true
        case .retry: break
        }
    }
}
