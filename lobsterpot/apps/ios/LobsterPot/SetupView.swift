import SwiftUI

/// First-run setup: enter bridge URL → show pairing code → confirm connection.
struct SetupView: View {

    @EnvironmentObject private var appState: AppState

    @State private var bridgeUrl = ""
    @State private var step: Step = .enterUrl
    @State private var pairingCode = ""
    @State private var pairingId = ""
    @State private var pairingCodeVerifier = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    enum Step { case enterUrl, showCode, done }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                header

                switch step {
                case .enterUrl:
                    urlForm
                case .showCode:
                    pairingCodeView
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
            .navigationTitle("Connect to Bridge")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Sub-views

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("LobsterPot")
                .font(.title.bold())
            Text("Connect your iOS app to your self-hosted LobsterPot bridge.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 16)
    }

    private var urlForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bridge URL")
                .font(.headline)
            TextField("https://my-bridge.fly.dev", text: $bridgeUrl)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)

            Text("Enter the public HTTPS URL of your LobsterPot bridge. Run `fly open` or check your Fly dashboard.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: startPairing) {
                Label(isWorking ? "Connecting…" : "Connect", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(bridgeUrl.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
        }
    }

    private var pairingCodeView: some View {
        VStack(spacing: 16) {
            Text("Enter this code in the bridge CLI or web UI to authorize this device:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(pairingCode)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .tracking(8)
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            Text("Code expires in 10 minutes.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button(action: finishPairing) {
                Label(isWorking ? "Verifying…" : "I've entered the code", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)

            Button("Start over", role: .cancel) {
                step = .enterUrl
                errorMessage = nil
            }
            .buttonStyle(.borderless)
        }
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Connected!")
                .font(.title2.bold())
            Text("Your app is now linked to the bridge. You can start messaging.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func startPairing() {
        errorMessage = nil
        isWorking = true

        let url = bridgeUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reuse a temporary BridgeClient with a placeholder token for the unauthenticated pairing call
        let tempConn = BridgeConnection(bridgeUrl: url, deviceToken: "")
        let client = BridgeClient(connection: tempConn)

        Task {
            defer { isWorking = false }
            do {
                let (resp, verifier) = try await client.startPairing()
                pairingId = resp.pairingId
                pairingCode = resp.code
                pairingCodeVerifier = verifier
                step = .showCode
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finishPairing() {
        errorMessage = nil
        isWorking = true

        let url = bridgeUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let tempConn = BridgeConnection(bridgeUrl: url, deviceToken: "")
        let client = BridgeClient(connection: tempConn)

        Task {
            defer { isWorking = false }
            do {
                let resp = try await client.finishPairing(pairingId: pairingId, code: pairingCode, codeVerifier: pairingCodeVerifier)
                let conn = BridgeConnection(bridgeUrl: url, deviceToken: resp.token)
                step = .done
                try? await Task.sleep(nanoseconds: 800_000_000)
                appState.connect(to: conn)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    SetupView().environmentObject(AppState())
}
