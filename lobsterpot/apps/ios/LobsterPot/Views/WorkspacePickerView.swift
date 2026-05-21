import SwiftUI

struct WorkspacePickerView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var showAddWorkspace: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(appState.workspaceStore.workspaces) { workspace in
                        workspaceRow(workspace)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                appState.switchWorkspace(to: workspace.id)
                                dismiss()
                            }
                    }
                }

                Section {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showAddWorkspace = true
                        }
                    } label: {
                        Label("Add Workspace", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("Workspaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
        let state = appState.connectionStates[workspace.id] ?? .disconnected
        let isActive = appState.activeWorkspaceId == workspace.id

        return HStack(spacing: 14) {
            // Avatar
            Circle()
                .fill(.blue.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay(
                    Text(workspace.initials)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.blue)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.body.weight(isActive ? .semibold : .regular))
                Text(statusText(state))
                    .font(.caption)
                    .foregroundStyle(statusColor(state))
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark")
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusText(_ state: GatewayConnectionState) -> String {
        switch state {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .waitingForPairing(let id): return "Approve device \(String(id.prefix(8)))…"
        case .connected(let ver): return "Connected · v\(ver)"
        case .error(let msg): return msg
        }
    }

    private func statusColor(_ state: GatewayConnectionState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting, .waitingForPairing: return .orange
        case .disconnected, .error: return .secondary
        }
    }
}
