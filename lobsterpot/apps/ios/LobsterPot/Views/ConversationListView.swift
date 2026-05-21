import SwiftUI

struct ConversationListView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selectedSessionKey: String?

    var body: some View {
        List(selection: $selectedSessionKey) {
            if appState.activeSessions.isEmpty {
                emptyState
            } else {
                ForEach(appState.activeSessions) { session in
                    sessionRow(session)
                        .tag(session.id)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Messages")
        .refreshable {
            if let id = appState.activeWorkspaceId {
                await appState.refreshSessions(for: id)
            }
        }
        .overlay {
            if appState.isLoadingSessions && appState.activeSessions.isEmpty {
                ProgressView("Loading…")
            }
        }
    }

    private func sessionRow(_ session: LPSession) -> some View {
        HStack(spacing: 12) {
            sessionAvatar(session)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.displayName)
                        .font(.body.weight(session.hasUnread ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer()
                    if let ts = session.lastMessageTs {
                        Text(ts.relativeShort)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(session.lastMessagePreview ?? "No messages yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func sessionAvatar(_ session: LPSession) -> some View {
        ZStack {
            Circle()
                .fill(session.isMain ? Color.blue.opacity(0.2) : Color.purple.opacity(0.15))
                .frame(width: 46, height: 46)
            Image(systemName: session.isMain ? "person.crop.circle.fill" : "sparkles")
                .font(.system(size: session.isMain ? 26 : 20))
                .foregroundStyle(session.isMain ? .blue : .purple)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No sessions yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Sessions appear here when your OpenClaw agent is active.")
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
