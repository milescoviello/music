import Foundation

/// Where commands from outside the window find the running app: the command line
/// (`music --play-playlist NAME` reaching the instance already open) and the desktop
/// actions in the launcher. The phone's Siri intents arrive the same way.
@MainActor
enum MusicIntentBridge {
    static weak var appState: AppState?

    /// Waits briefly for the app to finish launching when a command opened it cold.
    static func state() async -> AppState? {
        for _ in 0..<20 {
            if let appState, appState.phase == .ready { return appState }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return appState
    }
}
