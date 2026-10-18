import SwiftUI

@main
struct MusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(appState.artwork)
                .environment(appState.playlistArtwork)
                .environment(appState.history)
                .environment(appState.scope)
                .environment(appState.userState)
                .environment(appState.playlistStore)
                .environment(appState.requests)
                .environment(appState.queueSync)
                .environment(appState.playlistSync)
                .environment(appState.downloads)
                .environment(appState.reachability)
                .environment(appState.sleepTimer)
                .environment(appState.audio)
                .environment(appState.streaming)
                .environment(appState.playerSettings)
                .environment(appState.autoplay)
                .environment(appState.guestDJ)
                .environment(appState.stations)
                .environment(appState.libraryIndex)
                .environment(appState.streamCache)
                .environment(appState.spectrum)
                .preferredColorScheme(.dark)
                .tint(.appTint)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Some apps interrupt playback and then never release the
                        // session, so `.ended` never arrives and coming back here is the
                        // only signal that the interruption is over.
                        appState.player.appBecameActive()
                        // iOS clears the idle-timer flag when the app leaves the
                        // foreground, so it has to be set again on the way back.
                        appState.screenAwake.apply()
                        // Coming back is the most likely moment to have a network
                        // again after listening offline.
                        Task { await appState.flushOutbox() }
                        Task { await appState.refreshRequests() }
                        Task { await appState.playlistSync.sync() }
                        Task {
                            await appState.queueSync.check(
                                localSavedAt: appState.player.lastSavedAt
                            )
                        }
                    case .background:
                        // Backgrounding does not kill the app while audio plays, but
                        // termination while paused is common and silent.
                        appState.player.persistNow()
                        appState.history.saveNow()
                        appState.screenAwake.release()
                    default:
                        break
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.phase {
        case .loading:
            ProgressView()
                .controlSize(.large)
        case .needsSetup:
            ServerSetupView()
        case .ready:
            MainTabView()
        }
    }
}
