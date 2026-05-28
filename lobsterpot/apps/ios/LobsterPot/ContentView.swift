import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showWorkspacePicker = false
    @State private var showAddWorkspace = false
    @State private var showSettings = false
    @State private var showNewConversation = false
    @State private var selectedConversationId: String?

    var body: some View {
        NavigationSplitView {
            ConversationListView(selectedConversationId: $selectedConversationId)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        workspaceButton
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        Button {
                            showNewConversation = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                }
        } detail: {
            if let id = selectedConversationId {
                ChatView(conversationId: id)
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
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showNewConversation) {
            NewConversationView { conversation in
                selectedConversationId = conversation.id
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let conversation = appState.newSubagentConversation {
                    Button {
                        selectedConversationId = conversation.id
                        appState.newSubagentConversation = nil
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.2.wave.2.fill")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(conversation.displayTitle) is ready")
                                    .font(.headline)
                                Text("Tap to open")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let conversation = appState.recentlyArchivedConversation {
                    HStack(spacing: 10) {
                        Image(systemName: "archivebox")
                            .foregroundStyle(.secondary)
                        Text("Archived \(conversation.displayTitle)")
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Button("Undo") {
                            Task { await appState.unarchiveConversation(conversation.id) }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(radius: 10, y: 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: appState.newSubagentConversation?.id)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: appState.recentlyArchivedConversation?.id)
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
        let ws = appState.activeWorkspace
        let color = ws?.color ?? .gray
        let initials = ws?.initials ?? "?"
        return ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 30, height: 30)
                .overlay(
                    Text(initials)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(color)
                )
            Circle()
                .fill(appState.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .offset(x: 2, y: 2)
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
            if !appState.pluginConnected {
                Text("OpenClaw plugin not connected")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - New Conversation sheet

struct NewConversationView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var onCreated: (LPConversation) -> Void

    @State private var title = ""
    @State private var purpose = ""
    @State private var kind: LPConversation.ConversationKind = .specialist
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Purpose (optional)", text: $purpose, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section("Type") {
                    Picker("Conversation type", selection: $kind) {
                        Text("Specialist").tag(LPConversation.ConversationKind.specialist)
                        Text("Support").tag(LPConversation.ConversationKind.support)
                    }
                    .pickerStyle(.segmented)
                }
                if let err = errorMessage {
                    Section {
                        Text(err).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                }
            }
        }
    }

    private func create() {
        errorMessage = nil
        isCreating = true
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPurpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { isCreating = false }
            if let conv = await appState.createConversation(
                title: trimmedTitle,
                purpose: trimmedPurpose.isEmpty ? nil : trimmedPurpose,
                kind: kind
            ) {
                onCreated(conv)
                dismiss()
            } else {
                errorMessage = appState.lastError ?? "Failed to create conversation"
            }
        }
    }
}
