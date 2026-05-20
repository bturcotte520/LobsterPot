import SwiftUI

struct ChatView: View {

    @EnvironmentObject private var appState: AppState
    let conversationId: String

    @State private var input = ""
    @State private var scrollProxy: ScrollViewProxy?
    @FocusState private var inputFocused: Bool

    private var conversation: LPConversation? {
        appState.conversations.first { $0.id == conversationId }
    }

    private var messages: [LPMessage] {
        appState.messages[conversationId] ?? []
    }

    private var isSending: Bool {
        appState.sendingInConversation == conversationId
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                        if isSending {
                            TypingIndicator()
                                .id("typing")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .onAppear { scrollProxy = proxy }
                .onChange(of: messages.count) {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: isSending) {
                    scrollToBottom(proxy: proxy)
                }
            }

            Divider()
            inputBar
        }
        .navigationTitle(conversation?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if messages.isEmpty {
                await appState.loadMessages(conversationId: conversationId)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let conv = conversation {
                    Menu {
                        Button {
                            Task { await appState.pinConversation(conversationId, pinned: !conv.pinned) }
                        } label: {
                            Label(conv.pinned ? "Unpin" : "Pin", systemImage: conv.pinned ? "pin.slash" : "pin")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 18))
                .focused($inputFocused)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? .tint : .secondary)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.background)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    // MARK: - Actions

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        Task {
            await appState.sendMessage(conversationId: conversationId, text: text)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if isSending {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("typing", anchor: .bottom) }
        } else if let last = messages.last {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: LPMessage

    private var isUser: Bool { message.role == .user }
    private var isStreaming: Bool { message.status == .streaming }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isUser ? Color.tint : Color(.systemGray5), in: BubbleShape(isUser: isUser))
                    .foregroundStyle(isUser ? .white : .primary)

                if isStreaming {
                    Text("typing…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                if message.status == .failed {
                    Label("Failed", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                }
            }

            if !isUser { Spacer(minLength: 48) }
        }
    }
}

private struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 18
        let tailRadius: CGFloat = 4
        var path = Path()

        if isUser {
            // Round all corners, flatten bottom-right slightly for tail
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        } else {
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        }
        _ = tailRadius
        return path
    }
}

// MARK: - Typing indicator

private struct TypingIndicator: View {
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color(.systemGray3))
                    .frame(width: 8, height: 8)
                    .scaleEffect(1 + 0.4 * sin(phase + Double(i) * .pi / 1.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 18))
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}

#Preview {
    NavigationStack {
        ChatView(conversationId: "preview-id")
            .environmentObject(AppState())
    }
}
