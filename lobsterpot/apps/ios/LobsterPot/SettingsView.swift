import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showDisconnectConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                if let conn = appState.connection {
                    Section("Bridge") {
                        LabeledContent("URL", value: conn.bridgeUrl)
                        HStack {
                            Text("Plugin")
                            Spacer()
                            Circle()
                                .fill(appState.pluginConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(appState.pluginConnected ? "Connected" : "Disconnected")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button("Refresh conversations") {
                        Task {
                            await appState.refreshConversations()
                            dismiss()
                        }
                    }
                }

                Section {
                    Button("Disconnect bridge", role: .destructive) {
                        showDisconnectConfirm = true
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Disconnect from bridge?",
                isPresented: $showDisconnectConfirm,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    appState.disconnect()
                    dismiss()
                }
            } message: {
                Text("You will need to re-pair this device to reconnect.")
            }
        }
    }
}

#Preview {
    SettingsView().environmentObject(AppState())
}
