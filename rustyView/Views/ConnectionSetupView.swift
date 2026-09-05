import SwiftUI

struct ConnectionSetupView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let canDismiss: Bool

    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 12) {
                        Image(systemName: "play.rectangle.on.rectangle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.orange.gradient)
                            .accessibilityHidden(true)
                        Text("Connect to your movies")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                        Text("Your password stays in this device's Keychain.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 16) {
                        LabeledContent("Server") {
                            TextField("https://example.com", text: $serverAddress)
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .server)
                        }
                        Divider()
                        LabeledContent("User name") {
                            TextField("User name", text: $username)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .username)
                        }
                        Divider()
                        LabeledContent("Password") {
                            SecureField(canDismiss ? "Unchanged" : "Password", text: $password)
                                .textContentType(.password)
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .password)
                        }
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                    Button(action: connect) {
                        HStack {
                            if isConnecting { ProgressView().tint(.white) }
                            Text(isConnecting ? "Connecting…" : "Connect")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isConnecting || serverAddress.isEmpty || username.isEmpty)
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canDismiss {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .onAppear {
            serverAddress = app.settings.serverAddress
            username = app.settings.username
            focusedField = serverAddress.isEmpty ? .server : (username.isEmpty ? .username : .password)
        }
    }

    private func connect() {
        focusedField = nil
        isConnecting = true
        Task {
            let succeeded = await app.connect(
                serverAddress: serverAddress,
                username: username,
                password: password
            )
            isConnecting = false
            if succeeded { dismiss() }
        }
    }

    private enum Field {
        case server, username, password
    }
}
