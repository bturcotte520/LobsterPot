import SwiftUI

@main
struct LobsterPotApp: App {

    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .onAppear {
                    appState.loadPersistedConnection()
                }
        }
    }
}

private struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.connection == nil {
            SetupView()
        } else {
            ContentView()
        }
    }
}
