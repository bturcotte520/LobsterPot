import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    let conversationId: String

    @State private var inputText = ""
    @State private var didPerformInitialScroll = false
    @State private var didRevealInitialPosition = false
    @State private var isShowingFilePicker = false
    @State private var pendingAttachments: [PendingAttachment] = []
    @FocusState private var inputFocused: Bool

    private var messages: [LPMessage] {
        appState.messages[conversationId] ?? []
    }

    private var lastMessageId: String? {
        messages.last?.id
    }

    private var isTyping: Bool {
        appState.isTyping(conversationId: conversationId)
    }

    private var conversationTitle: String {
        appState.conversations.first { $0.id == conversationId }?.displayTitle ?? "Chat"
    }

    var body: some View {
        messageList
            .safeAreaInset(edge: .bottom) {
                inputBar
            }
        .navigationTitle(conversationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await appState.loadMessages(conversationId: conversationId)
        }
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFileSelection(result)
        }

    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if appState.loadingMessageConversation == conversationId {
                        ProgressView()
                            .padding(.top, 20)
                    } else if messages.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "bubble.left")
                                .font(.system(size: 34))
                                .foregroundStyle(.secondary)
                            Text("No messages yet")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("Send a message to start this thread.")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    }
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if isTyping {
                        TypingIndicator()
                            .id("typing-indicator")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .opacity(messages.isEmpty || didRevealInitialPosition ? 1 : 0)
            .onAppear {
                performInitialScrollIfNeeded(proxy)
            }
            .onChange(of: conversationId) { _, _ in
                didPerformInitialScroll = false
                didRevealInitialPosition = false
                performInitialScrollIfNeeded(proxy)
            }
            .onChange(of: lastMessageId) { _, _ in
                if didRevealInitialPosition {
                    scrollToBottom(proxy, animated: true)
                } else {
                    performInitialScrollIfNeeded(proxy)
                }
            }
            .onChange(of: isTyping) { _, typing in
                if typing && didRevealInitialPosition {
                    scrollToBottom(proxy, animated: true)
                }
            }
        }
    }

    private func performInitialScrollIfNeeded(_ proxy: ScrollViewProxy) {
        guard !didPerformInitialScroll, lastMessageId != nil else { return }
        didPerformInitialScroll = true
        DispatchQueue.main.async {
            scrollToBottom(proxy, animated: false)
            DispatchQueue.main.async {
                didRevealInitialPosition = true
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        let target = isTyping ? "typing-indicator" : lastMessageId
        guard let target else { return }
        let scroll = { proxy.scrollTo(target, anchor: .bottom) }
        if animated {
            withAnimation(.easeOut(duration: 0.25), scroll)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scroll()
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pendingAttachments.isEmpty {
                attachmentTray
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    isShowingFilePicker = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(.regularMaterial, in: Circle())
                }

                HStack(alignment: .center, spacing: 8) {
                    TextField("Message", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .focused($inputFocused)
                        .padding(.leading, 4)
                        .padding(.vertical, 9)

                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(canSend ? .blue : .gray)
                            .frame(width: 32, height: 32)
                    }
                    .disabled(!canSend)
                }
                .padding(.horizontal, 8)
                .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.clear)
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill")
                        Text(attachment.filename)
                            .lineLimit(1)
                        Button {
                            pendingAttachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
            }
        }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        inputText = ""
        pendingAttachments = []
        Task {
            await appState.sendMessage(conversationId: conversationId, text: text, attachments: attachments)
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let values = try url.resourceValues(forKeys: [.contentTypeKey, .localizedNameKey])
                let contentType = values.contentType?.preferredMIMEType ?? "application/octet-stream"
                let filename = values.localizedName ?? url.lastPathComponent
                pendingAttachments.append(PendingAttachment(filename: filename, contentType: contentType, data: data))
            }
        } catch {
            appState.lastError = error.localizedDescription
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
        HStack(alignment: .bottom, spacing: 4) {
            VStack(alignment: .leading, spacing: 8) {
                if !message.content.isEmpty {
                    MarkdownMessageText(text: message.content, isUser: message.role == .user)
                }
                ForEach(message.attachments) { attachment in
                    AttachmentPill(attachment: attachment, isUser: message.role == .user)
                }
            }
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

private struct MarkdownMessageText: View {
    let text: String
    let isUser: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(renderedBlocks.indices, id: \.self) { index in
                Text(renderedBlocks[index])
                    .font(.body)
                    .foregroundStyle(isUser ? .white : .primary)
                    .textSelection(.enabled)
            }
        }
    }

    private var renderedBlocks: [AttributedString] {
        let blocks = text
            .split(separator: /\n{2,}/)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let source = blocks.isEmpty ? [text] : blocks
        return source.map { block in
            let markdown = block.replacingOccurrences(of: "\n", with: "  \n")
            return (try? AttributedString(markdown: markdown)) ?? AttributedString(block)
        }
    }
}

private struct TypingIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(phase == index ? 1 : 0.35)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(.secondarySystemBackground), in: Capsule())
            Spacer(minLength: 60)
        }
        .padding(.vertical, 2)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 320_000_000)
                phase = (phase + 1) % 3
            }
        }
    }
}

private struct AttachmentPill: View {
    let attachment: LPAttachment
    let isUser: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(byteCount)
                    .font(.caption2)
                    .opacity(0.75)
            }
        }
        .foregroundStyle(isUser ? .white : .primary)
        .padding(8)
        .background((isUser ? Color.white.opacity(0.18) : Color(.tertiarySystemBackground)), in: RoundedRectangle(cornerRadius: 10))
    }

    private var byteCount: String {
        ByteCountFormatter.string(fromByteCount: Int64(attachment.byteSize), countStyle: .file)
    }
}
