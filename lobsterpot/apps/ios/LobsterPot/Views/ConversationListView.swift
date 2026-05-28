import SwiftUI

struct ConversationListView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selectedConversationId: String?
    @State private var searchText = ""

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayedConversations: [LPConversation] {
        isSearching ? (appState.searchResults?.conversations ?? []) : appState.conversations
    }

    var body: some View {
        List(selection: $selectedConversationId) {
            if displayedConversations.isEmpty {
                if isSearching {
                    searchEmptyState
                } else {
                    emptyState
                }
            } else {
                ForEach(displayedConversations) { conversation in
                    conversationRow(conversation)
                        .tag(conversation.id)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Messages")
        .refreshable {
            await appState.refreshConversations()
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search messages")
        .onChange(of: searchText) { _, newValue in
            Task { await appState.search(newValue) }
        }
        .overlay {
            if appState.isLoadingConversations && appState.conversations.isEmpty {
                ProgressView("Loading…")
            }
        }
    }

    private func conversationRow(_ conversation: LPConversation) -> some View {
        let msgs = appState.messages[conversation.id]
        let searchMatch = appState.searchResults?.messages.first { $0.conversationId == conversation.id }
        let lastMessage = searchMatch ?? msgs?.last
        let isMain = conversation.kind == .main
        let isMuted = appState.isMuted(conversation.id)

        return HStack(spacing: 12) {
            conversationAvatar(conversation)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conversation.displayTitle)
                        .font(.body.weight(.regular))
                        .lineLimit(1)
                    if conversation.pinned || isMain {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let ts = lastMessage?.timestamp {
                        Text(ts.relativeShort)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let match = searchMatch?.content, isSearching {
                    Text(match)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let purpose = conversation.purpose {
                    Text(purpose)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let preview = lastMessage?.content {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("No messages yet")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 64)
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isMain {
                Button(role: .destructive) {
                    if selectedConversationId == conversation.id { selectedConversationId = nil }
                    Task { await appState.deleteConversation(conversation.id) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                Button {
                    if selectedConversationId == conversation.id { selectedConversationId = nil }
                    Task { await appState.archiveConversation(conversation.id) }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.blue)

                Button {
                    Task { await appState.pinConversation(conversation.id, pinned: !conversation.pinned) }
                } label: {
                    Label(conversation.pinned ? "Unpin" : "Pin", systemImage: conversation.pinned ? "pin.slash" : "pin")
                }
                .tint(.orange)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                appState.setMuted(!isMuted, conversationId: conversation.id)
            } label: {
                Label(isMuted ? "Unmute" : "Mute", systemImage: isMuted ? "bell" : "bell.slash")
            }
            .tint(.gray)
        }
    }

    private func conversationAvatar(_ conversation: LPConversation) -> some View {
        let isMain = conversation.kind == .main
        return ZStack {
            Circle()
                .fill(isMain ? Color.blue.opacity(0.2) : Color.purple.opacity(0.15))
                .frame(width: 46, height: 46)
            Image(systemName: isMain ? "person.crop.circle.fill" : "sparkles")
                .font(.system(size: isMain ? 26 : 20))
                .foregroundStyle(isMain ? .blue : .purple)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No conversations yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Tap the compose button to start a new conversation.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Results")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Try a different message or thread name.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

// MARK: - Date formatting

private extension Date {
    var relativeShort: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) {
            let fmt = DateFormatter()
            fmt.timeStyle = .short
            fmt.dateStyle = .none
            return fmt.string(from: self)
        } else if cal.isDateInYesterday(self) {
            return "Yesterday"
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            return fmt.string(from: self)
        }
    }
}
