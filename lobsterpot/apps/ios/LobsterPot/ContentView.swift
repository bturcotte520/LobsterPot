import SwiftUI

/// Root view shown once a bridge connection exists.
struct ContentView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ConversationListView()
                .navigationDestination(for: String.self) { conversationId in
                    ChatView(conversationId: conversationId)
                }
        }
        .overlay(alignment: .bottom) {
            if let error = appState.lastError {
                ErrorToast(message: error) {
                    appState.lastError = nil
                }
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: appState.lastError)
    }
}

private struct ErrorToast: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .lineLimit(2)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .shadow(radius: 6)
    }
}

#Preview {
    ContentView().environmentObject(AppState())
}
