import SwiftUI

struct WorkspacePickerView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var showAddWorkspace: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(appState.workspaceStore.workspaces) { ws in
                        workspaceRow(ws)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                appState.switchWorkspace(to: ws.id)
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

    private func workspaceRow(_ ws: Workspace) -> some View {
        let isActive = appState.activeWorkspaceId == ws.id
        let isConnected = isActive && appState.isConnected

        return HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(ws.color.opacity(0.18))
                    .frame(width: 44, height: 44)
                Text(ws.initials)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(ws.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(ws.name)
                    .font(.body.weight(isActive ? .semibold : .regular))
                Text(ws.normalizedUrl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if isActive {
                HStack(spacing: 4) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                        .font(.caption.bold())
                }
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            if appState.workspaceStore.workspaces.count > 1 {
                Button(role: .destructive) {
                    appState.removeWorkspace(ws.id)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }
}
