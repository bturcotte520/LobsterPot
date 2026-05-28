import SwiftUI
import UserNotifications

@main
struct LobsterPotApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(colorScheme(for: appState.appearanceMode))
                .onAppear {
                    appDelegate.appState = appState
                    UNUserNotificationCenter.current().delegate = appDelegate
                }
                .task {
                    appState.connectToActiveWorkspace()
                    await appState.requestPushNotifications()
                }
        }
    }

    private func colorScheme(for mode: AppearanceMode) -> ColorScheme? {
        switch mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

private struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.isSetupComplete {
            ContentView()
        } else {
            SetupView()
        }
    }
}
