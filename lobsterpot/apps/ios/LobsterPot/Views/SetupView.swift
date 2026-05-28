import SwiftUI

/// Bridge setup. Used both as first-run and as "Add workspace" sheet.
struct SetupView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var isAddingWorkspace = false

    @State private var workspaceName = ""
    @State private var bridgeUrl = ""
    @State private var step: Step = .form
    @State private var isWorking = false
    @State private var errorMessage: String?

    @State private var pairingId: String?
    @State private var pairingCode: String?
    @State private var codeVerifier: String?

    enum Step {
        case form
        case pairing(code: String)
        case done
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                header
                switch step {
                case .form: formView
                case .pairing(let code): pairingView(code: code)
                case .done: doneView
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
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("🦞").font(.system(size: 52))
            Text("LobsterPot").font(.title.bold())
            Text(isAddingWorkspace ? "Connect another OpenClaw" : "Connect to your LobsterPot bridge")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Workspace name").font(.subheadline.weight(.medium))
                TextField("Home, Work, …", text: $workspaceName)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                Text("How this workspace appears in your switcher.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Bridge URL").font(.subheadline.weight(.medium))
                TextField("https://my-bridge.fly.dev", text: $bridgeUrl)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Text("HTTPS address of your LobsterPot bridge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: startPairing) {
                Label(isWorking ? "Connecting…" : "Connect", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!formIsValid || isWorking)
        }
    }

    private func pairingView(code: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Pair this device").font(.title3.bold())
            Text("Tap accept to securely pair with your bridge.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(code)
                .font(.system(.title2, design: .monospaced).bold())
                .padding(16)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.orange)
                .textSelection(.enabled)

            Button(action: finishPairing) {
                Label(isWorking ? "Verifying…" : "Accept", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)

            Button("Back") {
                step = .form
                errorMessage = nil
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Connected!").font(.title2.bold())
            Text("\(workspaceName) is ready.").foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func startPairing() {
        errorMessage = nil
        isWorking = true
        let url = bridgeUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { isWorking = false }
            do {
                let tempConn = BridgeConnection(bridgeUrl: url, deviceToken: "")
                let client = BridgeClient(connection: tempConn)
                let (resp, verifier) = try await client.startPairing()
                pairingCode = resp.code
                pairingId = resp.pairingId
                codeVerifier = verifier
                step = .pairing(code: resp.code)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finishPairing() {
        guard let code = pairingCode, let verifier = codeVerifier, let pid = pairingId else {
            errorMessage = "Pairing state lost — please start over."
            step = .form
            return
        }
        errorMessage = nil
        isWorking = true
        let url = bridgeUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { isWorking = false }
            do {
                let tempConn = BridgeConnection(bridgeUrl: url, deviceToken: "")
                let client = BridgeClient(connection: tempConn)
                let resp = try await client.finishPairing(pairingId: pid, code: code, codeVerifier: verifier)
                appState.addWorkspace(
                    name: name.isEmpty ? "OpenClaw" : name,
                    bridgeUrl: url,
                    deviceToken: resp.token
                )
                step = .done
                try? await Task.sleep(nanoseconds: 800_000_000)
                if isAddingWorkspace { dismiss() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var formIsValid: Bool {
        let url = bridgeUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return (url.hasPrefix("http://") || url.hasPrefix("https://"))
            && !workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
