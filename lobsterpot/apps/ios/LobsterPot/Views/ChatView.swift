import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    let sessionKey: String

    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    private var messages: [LPMessage] {
        appState.messages[sessionKey] ?? []
    }

    private var isSending: Bool {
        appState.sendingInSession == sessionKey
    }

    private var sessionName: String {
        appState.activeSessions.first { $0.id == sessionKey }?.displayName ?? "Chat"
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            inputBar
        }
        .navigationTitle(sessionName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await appState.loadMessages(sessionKey: sessionKey)
        }
        .onDisappear {
            Task { await appState.unloadMessages(sessionKey: sessionKey) }
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if appState.loadingMessageSession == sessionKey {
                        ProgressView()
                            .padding(.top, 20)
                    }
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .focused($inputFocused)
                .disabled(isSending)

            Button(action: send) {
                Image(systemName: isSending ? "ellipsis.circle" : "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? .blue : .gray)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        Task {
            await appState.sendMessage(sessionKey: sessionKey, text: text)
        }
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: LPMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                bubble
                timestamp
            }
            if message.role != .user { Spacer(minLength: 60) }
        }
        .padding(.vertical, 2)
    }

    private var bubble: some View {
        HStack(spacing: 4) {
            Text(message.text.isEmpty ? " " : message.text)
                .font(.body)
                .foregroundStyle(message.role == .user ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

            if message.status == .streaming {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.trailing, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(bubbleColor)
        )
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user: return .blue
        case .assistant: return Color(.secondarySystemBackground)
        default: return Color(.tertiarySystemBackground)
        }
    }

    private var timestamp: some View {
        Text(message.timestamp.formatted(date: .omitted, time: .shortened))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
