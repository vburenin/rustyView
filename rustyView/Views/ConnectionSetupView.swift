import SwiftUI

struct ConnectionSetupView: View {
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Text("Connect to your movies")
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 16) {
                        connectionField("Server") {
                            TextField("Server", text: $serverAddress, prompt: fieldPrompt("https://"))
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.next)
                                .onSubmit { focusedField = .username }
                                .multilineTextAlignment(.leading)
                                .focused($focusedField, equals: .server)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                                .simultaneousGesture(TapGesture().onEnded { focusedField = .server })
                                .accessibilityIdentifier("connection-server")
                                .accessibilityLabel("Server")
                        }
                        fieldError(.server)
                        Divider()
                        connectionField("User name") {
                            TextField("User name", text: $username, prompt: Text(""))
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                                .multilineTextAlignment(.leading)
                                .focused($focusedField, equals: .username)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                                .simultaneousGesture(TapGesture().onEnded { focusedField = .username })
                                .accessibilityIdentifier("connection-username")
                                .accessibilityLabel("User name")
                        }
                        fieldError(.username)
                        Divider()
                        connectionField("Password") {
                            SecureField("Password", text: $password,
                                        prompt: fieldPrompt(canReusePassword ? "Unchanged" : ""))
                                .textContentType(.password)
                                .submitLabel(.go)
                                .onSubmit(connect)
                                .multilineTextAlignment(.leading)
                                .focused($focusedField, equals: .password)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                                .simultaneousGesture(TapGesture().onEnded { focusedField = .password })
                                .accessibilityIdentifier("connection-password")
                                .accessibilityLabel("Password")
                        }
                        fieldError(.password)
                    }
                    .disabled(isConnecting)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                    if app.settings.credentialAvailability == .unavailable,
                       app.settings.isSavedAccount(serverAddress: serverAddress, username: username) {
                        VStack(spacing: 8) {
                            Text("Unlock your device or enter the password again.")
                                .font(.callout)
                            Button("Retry Saved Password") {
                                do {
                                    _ = try app.settings.savedConnection()
                                    app.connectionError = nil
                                } catch { app.connectionError = UserFacingError(error) }
                            }
                            .frame(minHeight: 44)
                        }
                    }

                    if let error = app.connectionError, error.category != .cancelled,
                       !fieldErrors.values.contains(error.message) {
                        Label(error.message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("connection-error")
                    }

                    Button(action: connect) {
                        HStack {
                            if isConnecting { ProgressView().tint(.white) }
                            Text(isConnecting ? "Connecting…" : "Connect")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("ActionFill"))
                    .disabled(isConnecting)
                    .accessibilityIdentifier("connection-submit")

                    if isConnecting {
                        Button("Cancel Connection", action: cancelAttempt)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("connection-cancel-attempt")
                    }
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canDismiss {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { cancelAttempt(); dismiss() }
                    }
                }
            }
        }
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
        let candidateAddress = serverAddress
        let candidateUsername = username
        let candidatePassword = password
        let identity = UUID()
        attemptID = identity
        focusedField = nil
        isConnecting = true
        connectionTask = Task {
            let succeeded = await app.connect(
                serverAddress: candidateAddress,
                username: candidateUsername,
                password: candidatePassword
            )
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

    private func connectionField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Color.primary).accessibilityHidden(true)
            content().font(.body).foregroundStyle(Color(uiColor: .label))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canReusePassword: Bool {
        app.settings.canReuseSavedPassword(serverAddress: serverAddress, username: username)
    }

    private func fieldPrompt(_ title: String) -> Text {
        Text(title).foregroundColor(Color(uiColor: .label).opacity(0.75))
    }

    @ViewBuilder
    private func fieldError(_ field: ConnectionField) -> some View {
        if let message = fieldErrors[field] {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("connection-\(field.rawValue)-error")
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
