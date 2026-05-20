import SwiftUI

struct ConversationListView: View {

    @EnvironmentObject private var appState: AppState
    @State private var showNewConversation = false
    @State private var newTitle = ""
    @State private var newPurpose = ""
    @State private var showSettings = false

    var body: some View {
        List {
            if !appState.pendingApprovals.isEmpty {
                Section("Needs your approval") {
                    ForEach(appState.pendingApprovals) { approval in
                        ApprovalRow(approval: approval)
                    }
                }
            }

            Section {
                ForEach(appState.conversations) { conv in
                    NavigationLink(value: conv.id) {
                        ConversationRow(conversation: conv)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await appState.pinConversation(conv.id, pinned: !conv.pinned) }
                        } label: {
                            Label(conv.pinned ? "Unpin" : "Pin", systemImage: conv.pinned ? "pin.slash" : "pin")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await appState.archiveConversation(conv.id) }
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { showSettings = true } label: {
                    Image(systemName: "gear")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    pluginStatusDot
                    Button { showNewConversation = true } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
        }
        .refreshable {
            await appState.refreshConversations()
        }
        .overlay {
            if appState.isLoadingConversations && appState.conversations.isEmpty {
                ProgressView("Loading…")
            }
        }
        .sheet(isPresented: $showNewConversation) {
            newConversationSheet
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    // MARK: - Plugin status indicator

    private var pluginStatusDot: some View {
        Circle()
            .fill(appState.pluginConnected ? Color.green : Color.red)
            .frame(width: 8, height: 8)
            .accessibilityLabel(appState.pluginConnected ? "OpenClaw connected" : "OpenClaw not connected")
    }

    // MARK: - New conversation sheet

    private var newConversationSheet: some View {
        NavigationStack {
            Form {
                Section("Conversation") {
                    TextField("Title", text: $newTitle)
                    TextField("Purpose (optional)", text: $newPurpose, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showNewConversation = false
                        resetForm()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let title = newTitle.trimmingCharacters(in: .whitespaces)
                        let purpose = newPurpose.trimmingCharacters(in: .whitespaces)
                        guard !title.isEmpty else { return }
                        Task {
                            let conv = await appState.createConversation(
                                title: title,
                                purpose: purpose.isEmpty ? nil : purpose
                            )
                            if conv != nil {
                                showNewConversation = false
                                resetForm()
                            }
                        }
                    }
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func resetForm() {
        newTitle = ""
        newPurpose = ""
    }
}

// MARK: - Row views

private struct ConversationRow: View {
    let conversation: LPConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if conversation.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(conversation.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            if let purpose = conversation.purpose, !purpose.isEmpty {
                Text(purpose)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ApprovalRow: View {
    @EnvironmentObject private var appState: AppState
    let approval: LPApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(approval.title)
                .font(.subheadline.weight(.semibold))
            if let body = approval.body {
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 12) {
                Button("Approve") {
                    Task {
                        await appState.respondToApproval(
                            conversationId: approval.conversationId,
                            approvalId: approval.approvalId,
                            decision: "approve"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Deny", role: .destructive) {
                    Task {
                        await appState.respondToApproval(
                            conversationId: approval.conversationId,
                            approvalId: approval.approvalId,
                            decision: "deny"
                        )
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        ConversationListView()
            .environmentObject(AppState())
    }
}
