import SwiftUI

struct TVConnectionView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let canDismiss: Bool

    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var attemptID = UUID()
    @State private var fieldErrors: [ConnectionField: String] = [:]
    @FocusState private var focusedField: ConnectionField?
    @FocusState private var connectFocused: Bool

    var body: some View {
        VStack(spacing: 40) {
            VStack(spacing: 12) {
                Text("Connect to your movies").font(.title2.bold())
                Text("Enter your rustyDLNA server address and account. You can type with the Siri Remote or an iPhone keyboard.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 20) {
                field("Server", error: .server) {
                    TextField("Server", text: $serverAddress, prompt: Text("server.example.com"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .server)
                        .onSubmit { focusedField = .username }
                        .accessibilityIdentifier("connection-server")
                }
                field("User name", error: .username) {
                    TextField("User name", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                        .onSubmit { focusedField = .password }
                        .accessibilityIdentifier("connection-username")
                }
                field("Password", error: .password) {
                    SecureField("Password", text: $password, prompt: Text(canReusePassword ? "Unchanged" : ""))
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .onSubmit { connectFocused = true }
                        .accessibilityIdentifier("connection-password")
                }
            }
            .disabled(isConnecting)
            .frame(maxWidth: 1000)

            if app.settings.credentialAvailability == .unavailable,
               app.settings.isSavedAccount(serverAddress: serverAddress, username: username) {
                HStack(spacing: 24) {
                    Text("The saved password is unavailable. Enter it again or retry.").font(.callout)
                    Button("Retry Saved Password") {
                        do {
                            _ = try app.settings.savedConnection()
                            app.connectionError = nil
                        } catch { app.connectionError = UserFacingError(error) }
                    }
                }
            }

            if let error = app.connectionError, error.category != .cancelled,
               !fieldErrors.values.contains(error.message) {
                Label(error.message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .accessibilityIdentifier("connection-error")
            }

            HStack(spacing: 40) {
                Button(action: connect) {
                    HStack(spacing: 16) {
                        if isConnecting { ProgressView() }
                        Text(isConnecting ? "Connecting…" : "Connect")
                    }
                    .frame(minWidth: 280)
                }
                .focused($connectFocused)
                .disabled(isConnecting)
                .accessibilityIdentifier("connection-submit")

                if isConnecting {
                    Button("Stop", action: cancelAttempt)
                        .accessibilityIdentifier("connection-cancel-attempt")
                } else if canDismiss {
                    Button("Cancel") { cancelAttempt(); dismiss() }
                }
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        // Menu stops an attempt or closes the cover. With neither, no handler
        // is installed, so Menu on the top-level screen reaches the Home screen.
        .onExitCommand(perform: isConnecting || canDismiss ? {
            if isConnecting { cancelAttempt() } else { dismiss() }
        } : nil)
        .onAppear {
            app.connectionError = nil
            serverAddress = app.settings.serverAddress
            username = app.settings.username
            focusedField = serverAddress.isEmpty ? .server : (username.isEmpty ? .username : .password)
        }
        .onDisappear { cancelAttempt() }
        .onChange(of: serverAddress) { _, _ in fieldErrors.removeValue(forKey: .server) }
        .onChange(of: username) { _, _ in fieldErrors.removeValue(forKey: .username) }
        .onChange(of: password) { _, _ in fieldErrors.removeValue(forKey: .password) }
    }

    private func field<Content: View>(_ title: String, error: ConnectionField,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            content()
            if let message = fieldErrors[error] {
                Label(message, systemImage: "exclamationmark.circle").font(.caption)
                    .accessibilityIdentifier("connection-\(error.rawValue)-error")
            }
        }
    }

    private var canReusePassword: Bool {
        app.settings.canReuseSavedPassword(serverAddress: serverAddress, username: username)
    }

    private func connect() {
        guard !isConnecting else { return }
        fieldErrors = [:]
        app.connectionError = nil
        do {
            _ = try ServerConnection(serverAddress: serverAddress, username: "validation", password: "")
        } catch { fieldErrors[.server] = UserFacingError(error).message }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors[.username] = ConnectionValidationError.missingUsername.localizedDescription
        }
        if password.isEmpty && !canReusePassword {
            fieldErrors[.password] = ConnectionValidationError.missingPassword.localizedDescription
        }
        if let invalid = [ConnectionField.server, .username, .password].first(where: { fieldErrors[$0] != nil }) {
            focusedField = invalid
            return
        }
        let candidate = (serverAddress, username, password)
        let identity = UUID()
        attemptID = identity
        isConnecting = true
        connectionTask = Task {
            let succeeded = await app.connect(serverAddress: candidate.0, username: candidate.1, password: candidate.2)
            guard attemptID == identity, !Task.isCancelled else { return }
            isConnecting = false
            connectionTask = nil
            if succeeded {
                dismiss()
            } else if let error = app.connectionError {
                let field = error.field ?? (error.category == .authentication ? .password
                    : error.category == .transportSecurity ? .server : nil)
                if let field {
                    fieldErrors[field] = error.message
                    focusedField = field
                }
            }
        }
    }

    private func cancelAttempt() {
        attemptID = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        isConnecting = false
        app.cancelConnectionAttempt()
    }
}
