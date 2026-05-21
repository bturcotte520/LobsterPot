import SwiftUI

/// Workspace setup / pairing flow.
///
/// Used both as the first-run screen (when no workspaces exist) and as the
/// "Add Workspace" sheet from the workspace picker.
struct SetupView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var isAddingWorkspace = false

    @State private var workspaceName = ""
    @State private var gatewayUrl = ""
    @State private var gatewayToken = ""
    @State private var step: Step = .form
    @State private var isWorking = false
    @State private var errorMessage: String?

    enum Step { case form, waitingPairing(deviceId: String), done }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                header
                switch step {
                case .form:
                    formView
                case .waitingPairing(let deviceId):
                    pairingView(deviceId: deviceId)
                case .done:
                    doneView
                }
                if let err = errorMessage {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()
            }
            .padding()
            .navigationTitle(isAddingWorkspace ? "Add Workspace" : "Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isAddingWorkspace {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .onChange(of: appState.activeConnectionState) { _, state in
            guard case .waitingForPairing(let id) = state else { return }
            step = .waitingPairing(deviceId: id)
        }
    }

    // MARK: - Sub-views

    private var header: some View {
        VStack(spacing: 8) {
            Text("🦞")
                .font(.system(size: 52))
            Text("LobsterPot")
                .font(.title.bold())
            Text("Connect to your OpenClaw Gateway")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 16) {
            labeledField("Workspace name", placeholder: "KiloClaw", text: $workspaceName)

            labeledField(
                "Gateway URL",
                placeholder: "wss://my-gateway.ts.net:18789",
                text: $gatewayUrl,
                keyboard: .URL,
                help: "The WebSocket address of your OpenClaw Gateway. Tailscale hostnames work great here."
            )

            labeledField(
                "Gateway token",
                placeholder: "From gateway.auth.token in openclaw.json",
                text: $gatewayToken,
                isSecure: true,
                help: "Found in ~/.openclaw/openclaw.json → gateway.auth.token on your gateway host."
            )

            Button(action: connect) {
                Label(isWorking ? "Connecting…" : "Connect", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!formIsValid || isWorking)
        }
    }

    private func pairingView(deviceId: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Approve this device")
                .font(.title3.bold())

            Text("SSH into your Gateway and run:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                codeBlock("openclaw devices list")
                codeBlock("openclaw devices approve \\\n  <request-id>")
            }

            VStack(spacing: 4) {
                Text("Your device ID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(deviceId)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Waiting for approval…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .padding()
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Connected!")
                .font(.title2.bold())
            Text("Your workspace is ready.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func connect() {
        errorMessage = nil
        let name = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = gatewayUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)

        let workspace = Workspace(
            name: name.isEmpty ? "My Gateway" : name,
            gatewayUrl: url,
            gatewayToken: token
        )
        appState.addWorkspace(workspace)

        // The connection state change drives the UI forward automatically
        // via the onChange modifier watching activeConnectionState.
        // Also watch for "connected" state to close setup.
        Task {
            for await _ in Timer.publish(every: 1, on: .main, in: .default).autoconnect().values {
                if case .connected = appState.activeConnectionState {
                    step = .done
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if isAddingWorkspace { dismiss() }
                    break
                } else if case .error(let msg) = appState.activeConnectionState {
                    errorMessage = msg
                    break
                }
            }
        }
    }

    // MARK: - Helpers

    private var formIsValid: Bool {
        !gatewayUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func labeledField(
        _ label: String,
        placeholder: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default,
        isSecure: Bool = false,
        help: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline.weight(.medium))
            if isSecure {
                SecureField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(keyboard)
            }
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func codeBlock(_ code: String) -> some View {
        Text(code)
            .font(.system(.footnote, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
    }
}
