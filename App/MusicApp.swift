import SwiftUI

@main
struct MusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var appState: AppState
    @State private var remotePlayers: RemotePlayers

    init() {
        let appState = AppState()
        _appState = State(initialValue: appState)
        // Where every stretch of the log starts: which build, on what.
        let launched = "launched \(SettingsView.version) on \(LogReport.currentSystem)"
        Task { await Diagnostics.shared.record("app", launched) }
        _remotePlayers = State(initialValue: RemotePlayers(appState: appState, browser: NetworkRemoteBrowser()))
        // The desktop can play to the phone too, when it is allowed in Settings.
        RemoteControlServer.shared.start(app: appState, advertiser: BonjourAdvertiser())
    }

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
                .environment(appState.recentPlays)
                .environment(appState.sonic)
                .environment(appState.video)
                .environment(appState.streamCache)
                .environment(remotePlayers)
                .remotePairingPrompt()
                .preferredColorScheme(.dark)
                .tint(.appTint)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Whether the app was on screen when something went wrong.
                        Task { await Diagnostics.shared.record("app", "foreground") }
                        // Some apps interrupt playback and then never release the
                        // session, so `.ended` never arrives and coming back here is the
                        // only signal that the interruption is over.
                        appState.player.appBecameActive()
                        remotePlayers.appBecameActive()
                        RemoteControlServer.shared.appBecameActive()
                        // iOS clears the idle-timer flag when the app leaves the
                        // foreground, so it has to be set again on the way back.
                        appState.screenAwake.apply()
                        // Coming back is the most likely moment to have a network
                        // again after listening offline.
                        Task { await appState.flushOutbox() }
                        Task { await appState.refreshRequests() }
                        Task { await appState.sonic.refreshStatus() }
                        Task { await appState.playlistSync.sync() }
                        appState.downloads.resumeWaiting()
                        Task { await appState.mostPlayed.refresh() }
                        Task { await appState.playlistStore.refreshIfStale() }
                        Task {
                            await appState.queueSync.check(
                                localSavedAt: appState.player.lastSavedAt
                            )
                        }
                    case .background:
                        Task { await Diagnostics.shared.record("app", "background") }
                        // Backgrounding does not kill the app while audio plays, but
                        // termination while paused is common and silent.
                        appState.player.persistNow()
                        appState.history.saveNow()
                        appState.downloads.flushCatalog()
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
