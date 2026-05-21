import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showAddWorkspace = false
    @State private var confirmRemove: Workspace?

    var body: some View {
        NavigationStack {
            List {
                Section("Workspaces") {
                    ForEach(appState.workspaceStore.workspaces) { workspace in
                        workspaceRow(workspace)
                    }
                    Button {
                        showAddWorkspace = true
                    } label: {
                        Label("Add Workspace", systemImage: "plus.circle")
                    }
                }

                Section("Device") {
                    let identity = DeviceIdentity.loadOrCreate()
                    LabeledContent("Device ID") {
                        Text(String(identity.id.prefix(16)) + "…")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Device ID (full)")
                            .font(.caption)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = identity.id
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                    }
                    Text(identity.id)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Section("About") {
                    LabeledContent("Protocol", value: "OpenClaw Gateway v4")
                    LabeledContent("Role", value: "operator")
                    if let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                        LabeledContent("Version", value: ver)
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showAddWorkspace) {
                SetupView(isAddingWorkspace: true)
            }
            .alert("Remove workspace?", isPresented: .constant(confirmRemove != nil), presenting: confirmRemove) { ws in
                Button("Remove", role: .destructive) {
                    appState.removeWorkspace(ws)
                    confirmRemove = nil
                }
                Button("Cancel", role: .cancel) { confirmRemove = nil }
            } message: { ws in
                Text("Remove "\(ws.name)"? Your device token for this gateway will be deleted.")
            }
        }
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
        let state = appState.connectionStates[workspace.id] ?? .disconnected
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name).font(.body)
                Text(workspace.normalizedUrl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(stateColor(state))
                .frame(width: 8, height: 8)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                confirmRemove = workspace
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func stateColor(_ state: GatewayConnectionState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting, .waitingForPairing: return .orange
        default: return .red
        }
    }
}
