import SwiftUI

struct AddOpenClawView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var token: String?
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let token {
                    Section("Plugin Config") {
                        Text(configSnippet(token: token))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy Config") {
                            UIPasteboard.general.string = configSnippet(token: token)
                        }
                    }
                    Section {
                        Text("Paste this config into the OpenClaw machine you want to connect, then restart `openclaw gateway run`.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        TextField("MacBook OpenClaw", text: $name)
                            .textInputAutocapitalization(.words)
                    } header: {
                        Text("Name")
                    } footer: {
                        Text("This name appears in LobsterPot and identifies which Claw is connected.")
                    }

                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Add OpenClaw")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(token == nil ? "Cancel" : "Done") { dismiss() }
                }
                if token == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isCreating ? "Creating..." : "Create") { create() }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                    }
                }
            }
        }
    }

    private func create() {
        isCreating = true
        errorMessage = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { isCreating = false }
            if let created = await appState.createOpenClaw(name: trimmed) {
                token = created.token
            } else {
                errorMessage = appState.lastError ?? "Failed to create OpenClaw"
            }
        }
    }

    private func configSnippet(token: String) -> String {
        let bridgeUrl = appState.activeWorkspace?.normalizedUrl ?? "https://your-lobsterpot-hub.example"
        return """
        {
          "channels": {
            "lobsterpot": {
              "enabled": true,
              "bridgeUrl": "\(bridgeUrl)",
              "token": "\(token)",
              "dmPolicy": "allowlist",
              "allowFrom": ["ios:primary"]
            }
          }
        }
        """
    }
}
