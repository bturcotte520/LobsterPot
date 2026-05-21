import SwiftUI

@main
struct LobsterPotApp: App {

    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .task {
                    appState.connectAllWorkspaces()
                }
        }
    }
}

private struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.workspaceStore.workspaces.isEmpty {
            SetupView()
        } else {
            ContentView()
        }
    }
}
