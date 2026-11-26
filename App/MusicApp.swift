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
        let signed = "signed: \(SigningInfo.summary)"
        Task {
            await Diagnostics.shared.record("app", launched)
            await Diagnostics.shared.record("app", signed)
        }
        _remotePlayers = State(initialValue: RemotePlayers(appState: appState, browser: NetworkRemoteBrowser()))
        // The desktop can play to the phone too, when it is allowed in Settings.
        RemoteControlServer.shared.start(app: appState, advertiser: BonjourAdvertiser())
        // And a car: what only this app can serve it, covers to the spectrum (`CarProvider`).
        RemoteControlServer.shared.carProvider = CarProvider(app: appState)
        // The watch app's link, at launch: a command from the watch can start the app in
        // the background, before any screen exists.
        WatchBridge.shared.start(appState: appState)
        // The widgets' buttons, run here (`WidgetControl`).
        WidgetControl.handler = { action in
            guard let appState = await MusicIntentBridge.state() else { return }
            switch action {
            case .toggle: appState.player.togglePlayPause()
            case .next: appState.player.next()
            case .previous: appState.player.previous()
            case let .mix(number): _ = await appState.quickPlay(.madeForYou, mix: number)
            case let .playlist(id):
                await appState.playlistStore.loadIfNeeded()
                guard let target = appState.playlistStore.playlists.first(where: { $0.id == id }) else { return }
                _ = await appState.play(target, shuffled: false)
            }
        }
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
                // The desktop's pairing QR code, opened by the camera.
                .onOpenURL { url in
                    guard url.scheme == PairingLink.scheme else { return }
                    Task { await remotePlayers.pair(link: url) }
                }
                .alert(
                    remotePlayers.notice ?? "",
                    isPresented: Binding(
                        get: { remotePlayers.notice != nil },
                        set: { if !$0 { remotePlayers.notice = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) { remotePlayers.notice = nil }
                }
                // Today's mixes, for the Made for You widget, whenever they change.
                .task(id: appState.mixes.mixes.map(\.id)) {
                    await WidgetPublisher.shared.mixes(appState.mixes.mixes, artwork: appState.artwork)
                }
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
                        // again after listening offline: what is owed and what moved
                        // on, once a quick question says the server is there.
                        appState.cameBack()
                        // Siri's names for playlists, artists and albums, read again.
                        MusicShortcuts.refreshNamesIfStale()
                        SiriPlayMedia.askForSiriIfNeeded()
                        appState.handoff?.setActive(true)
                    case .background:
                        appState.handoff?.setActive(false)
                        // Tonight's catching up, on the charger (`OvernightSync`).
                        OvernightSync.schedule()
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
