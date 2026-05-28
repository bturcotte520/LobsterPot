import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showAddWorkspace = false
    @State private var showArchive = false
    @State private var confirmRemove: Workspace?

    var body: some View {
        NavigationStack {
            List {
                workspacesSection
                if appState.activeWorkspace != nil {
                    activeWorkspaceSection
                    archiveSection
                    pluginSection
                }
                appearanceSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddWorkspace) {
                SetupView(isAddingWorkspace: true)
            }
            .sheet(isPresented: $showArchive) {
                ArchiveView()
            }
            .alert(
                "Remove workspace?",
                isPresented: .init(
                    get: { confirmRemove != nil },
                    set: { if !$0 { confirmRemove = nil } }
                ),
                presenting: confirmRemove
            ) { ws in
                Button("Remove", role: .destructive) {
                    appState.removeWorkspace(ws.id)
                    confirmRemove = nil
                }
                Button("Cancel", role: .cancel) { confirmRemove = nil }
            } message: { ws in
                Text("Remove \(ws.name)? Your device token for this bridge will be deleted.")
            }
        }
    }

    private var workspacesSection: some View {
        Section("OpenClaws") {
            ForEach(appState.workspaceStore.workspaces) { ws in
                workspaceRow(ws)
            }
            Button {
                showAddWorkspace = true
            } label: {
                Label("Add Workspace", systemImage: "plus.circle")
            }
        }
    }

    private func workspaceRow(_ ws: Workspace) -> some View {
        let isActive = appState.activeWorkspaceId == ws.id
        return HStack {
            ZStack {
                Circle().fill(ws.color.opacity(0.18)).frame(width: 32, height: 32)
                Text(ws.initials).font(.caption.weight(.bold)).foregroundStyle(ws.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ws.name).font(.body)
                Text(ws.normalizedUrl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark").foregroundStyle(.blue)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                confirmRemove = ws
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private var activeWorkspaceSection: some View {
        Section("Active Bridge") {
            HStack {
                Circle()
                    .fill(appState.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(appState.isConnected ? "Connected" : "Disconnected")
                    .foregroundStyle(appState.isConnected ? .primary : .secondary)
            }
        }
    }

    private var archiveSection: some View {
        Section("Messages") {
            Button {
                showArchive = true
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }

    private var pluginSection: some View {
        Section("OpenClaw Plugin") {
            HStack {
                Circle()
                    .fill(appState.pluginConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(appState.pluginConnected ? "Plugin connected" : "Plugin not connected")
                    .foregroundStyle(appState.pluginConnected ? .primary : .secondary)
            }
            if !appState.pluginConnected {
                Text("Install the LobsterPot channel plugin in your OpenClaw and add the config snippet shown in the bridge admin UI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appState.appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text("System follows your iPhone setting. Light and Dark override it for LobsterPot.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Protocol", value: "LobsterPot v1")
            if let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                LabeledContent("Version", value: ver)
            }
        }
    }
}

private struct ArchiveView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if appState.archivedConversations.isEmpty {
                    emptyArchive
                } else {
                    ForEach(appState.archivedConversations) { conversation in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conversation.displayTitle)
                                .font(.body)
                                .lineLimit(1)
                            if let purpose = conversation.purpose {
                                Text(purpose)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await appState.deleteConversation(conversation.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                Task { await appState.unarchiveConversation(conversation.id) }
                            } label: {
                                Label("Unarchive", systemImage: "tray.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
            .navigationTitle("Archive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await appState.refreshArchivedConversations()
            }
            .refreshable {
                await appState.refreshArchivedConversations()
            }
        }
    }

    private var emptyArchive: some View {
        VStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No archived messages")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
