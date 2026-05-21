import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showWorkspacePicker = false
    @State private var showAddWorkspace = false
    @State private var selectedSessionKey: String?
    @State private var showNotConnectedAlert = false

    var body: some View {
        NavigationSplitView {
            ConversationListView(selectedSessionKey: $selectedSessionKey)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        workspaceButton
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        newSessionButton
                    }
                }
        } detail: {
            if let key = selectedSessionKey {
                ChatView(sessionKey: key)
            } else {
                emptyDetail
            }
        }
        .sheet(isPresented: $showWorkspacePicker) {
            WorkspacePickerView(showAddWorkspace: $showAddWorkspace)
        }
        .sheet(isPresented: $showAddWorkspace) {
            SetupView(isAddingWorkspace: true)
        }
        .alert("Not Connected", isPresented: $showNotConnectedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Connect to a gateway first. Check Settings → Workspaces for the connection status.")
        }
    }

    private var workspaceButton: some View {
        Button {
            showWorkspacePicker = true
        } label: {
            HStack(spacing: 6) {
                workspaceAvatar
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
        }
    }

    private var workspaceAvatar: some View {
        let name = appState.activeWorkspace?.initials ?? "?"
        let connected: Bool
        if case .connected = appState.activeConnectionState { connected = true } else { connected = false }

        return ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(.blue.opacity(0.15))
                .frame(width: 30, height: 30)
                .overlay(
                    Text(name)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.blue)
                )
            Circle()
                .fill(connected ? .green : .red)
                .frame(width: 8, height: 8)
                .offset(x: 2, y: 2)
        }
    }

    private var newSessionButton: some View {
        Button {
            guard case .connected = appState.activeConnectionState else {
                showNotConnectedAlert = true
                return
            }
            // If a main session already exists, open it directly
            if let key = appState.mainSessionKey {
                selectedSessionKey = key
                return
            }
            // Otherwise create a fresh session
            Task {
                if let session = await appState.createSession() {
                    selectedSessionKey = session.id
                }
            }
        } label: {
            Image(systemName: "square.and.pencil")
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Select a conversation")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}
