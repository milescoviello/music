import SwiftUI

/// Home, Library, Downloads and Search. Downloads has its own tab — what is on this
/// phone is the one view that matters most when the server is out of reach, and it
/// should be a tap away rather than inside Library.
struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaylistStore.self) private var playlistStore

    private var navigator: Navigator { appState.navigator }

    /// Everything the widget's details show, as one value that changes when any of them does.
    private var widgetDetailsKey: String {
        guard let song = appState.player.currentSong else { return "" }
        let queue = appState.player.queue
        let rating = appState.userState.rating(id: song.id, serverValue: song.userRating)
        let starred = appState.userState.isStarred(id: song.id, serverValue: song.isFavorite)
        let next = queue.upcoming(4).map(\.id).joined(separator: ",")
        return "\(song.id)|\(rating)|\(starred)|\(next)"
    }

    private var pinnedPlaylists: [Playlist] {
        appState.playlistArrangement.arranged(playlistStore.playlists).pinned
    }

    /// A YouTube result from search, full screen until it is closed or shrunk into the mini
    /// player, where it plays on.
    private var watching: Binding<VideoClient.Video?> {
        Binding(
            get: { appState.video.isWatchingMinimized ? nil : appState.video.watching },
            set: { if $0 == nil, !appState.video.isWatchingMinimized { appState.video.stopWatching() } }
        )
    }

    private var showsPlayer: Binding<Bool> {
        Binding(
            get: { appState.navigator.showsPlayer },
            set: { appState.navigator.showsPlayer = $0 }
        )
    }

    /// Which tab is showing. Needed so a jump out of the player can select Library.
    @State private var selection = Tabs.home

    private enum Tabs: Hashable { case home, library, downloads, search }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                tabs
                    // The system's own slot for exactly this. It reserves the space
                    // itself, which a hand-rolled `safeAreaInset` did not do reliably
                    // -- the bar was covering the bottom of some screens.
                    .tabViewBottomAccessory {
                        MiniPlayerBar(showsPlayer: showsPlayer, isSystemAccessory: true)
                            .accessibilityHidden(navigator.showsPlayer)
                    }
            } else {
                tabs
            }
        }
        // Layered over the library rather than presented as a modal. A
        // `fullScreenCover` removes the presenting view from the hierarchy, so while the
        // player was being dragged down there was nothing behind it -- it slid away over
        // an empty screen. As a sibling in a `ZStack` the library is genuinely there,
        // and drops back slightly as the player comes up, which is what gives the
        // gesture somewhere to go.
        .overlay {
            if navigator.showsPlayer {
                NowPlayingView(onDismiss: { navigator.showsPlayer = false })
                    .accessibilityAddTraits(.isModal)
                    .transition(.move(edge: .bottom))
                    .zIndex(2)
            }
        }
        .overlay(alignment: .bottom) { toast }
        // The accent follows the playing song's cover, as on Linux; read here so the
        // whole app redraws in it when the song changes.
        .tint(Color.appTint)
        #if targetEnvironment(simulator)
        .task { await openFromLaunchEnvironment() }
        #endif
        .task(id: appState.player.currentSong?.coverArt) {
            await CoverTint.shared.follow(appState.player.currentSong?.coverArt, artwork: appState.artwork)
        }
        // The watch app's view of the phone.
        .watchBridge()
        // The widget's stars, heart and Up Next, whenever one of them changes.
        .task(id: widgetDetailsKey) {
            guard let song = appState.player.currentSong else { return }
            WidgetPublisher.shared.details(
                rating: appState.userState.rating(id: song.id, serverValue: song.userRating),
                isFavourite: appState.userState.isStarred(id: song.id, serverValue: song.isFavorite),
                upNext: appState.player.queue.upcoming(4)
            )
        }
        // What the Now Playing widget offers when nothing is playing.
        .task(id: pinnedPlaylists.map { $0.id + $0.name }) {
            await WidgetPublisher.shared.pinned(pinnedPlaylists, artwork: appState.artwork, custom: appState.playlistArtwork)
        }
        // Full screen over everything, the player included: watching it is the point.
        .fullScreenCover(item: watching) { video in
            VideoFullScreenView(watching: video)
        }
        // Over the player too, which is an overlay here rather than a modal.
        .playlistPicker(host: "root")
        .animation(.snappy(duration: 0.25), value: playlistStore.lastMessage)
        .animation(.snappy(duration: 0.25), value: appState.grab.landed?.id)
        // Matched to the drag's own spring so opening and closing feel like the same
        // movement whether it was a tap or a swipe.
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: navigator.showsPlayer)
        // A jump out of the player asks for Library; the switch happens here because the
        // selection lives with the tabs.
        .onChange(of: navigator.wantsLibraryTab) { _, wants in
            guard wants else { return }
            selection = .library
            navigator.didSelectLibraryTab()
        }
    }

    /// Added a song to a playlist? Say so. Menus give no feedback of their own, so
    /// without this the action is indistinguishable from nothing happening.
    @ViewBuilder
    private var toast: some View {
        if let message = playlistStore.lastMessage {
            Text(message)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 8, y: 2)
                .padding(.bottom, 120)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(2.2))
                    playlistStore.lastMessage = nil
                }
        } else if let landed = appState.grab.landed {
            // Music asked for from Soulseek is in the library: said once, wherever he is.
            Text("“\(landed.title ?? "")” is in your library")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 8, y: 2)
                .padding(.bottom, 120)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: landed.id) {
                    try? await Task.sleep(for: .seconds(4))
                    appState.grab.dismissLanded()
                }
        }
    }

    #if targetEnvironment(simulator)
    /// Simulator only (the Duo look check on GitHub): `SIMCTL_CHILD_MUSIC_SHOW=stats` or `=wrapped`
    /// opens Stats once the tabs are up, and Stats then opens its Wrapped story, so a screenshot
    /// can show them with nothing tapping. None of this exists in a device build.
    private func openFromLaunchEnvironment() async {
        guard let show = ProcessInfo.processInfo.environment["MUSIC_SHOW"], show == "stats" || show == "wrapped" else { return }
        try? await Task.sleep(for: .seconds(3))
        selection = .library
        navigator.open(.stats)
    }
    #endif

    private var tabs: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: Tabs.home) {
                hosted { HomeView() }
            }

            Tab("Library", systemImage: "square.stack", value: Tabs.library) {
                hosted { LibraryHubView() }
            }

            Tab("Downloads", systemImage: "arrow.down.circle", value: Tabs.downloads) {
                hosted {
                    NavigationStack {
                        DownloadsView()
                            .musicDestinations()
                            .pageBackdrop()
                    }
                }
            }
            .badge(appState.downloads.activeCount)

            Tab(value: Tabs.search, role: .search) {
                hosted { SearchView() }
            }
        }
    }

    /// Before iOS 26 there is no accessory slot, so the bar is inset into each tab.
    /// It has to be *inside* the tab rather than on the `TabView`: inside a tab the tab
    /// bar is already part of the safe area, so the bar lands directly above it and
    /// every scroll view in that tab gets the extra bottom inset. Applied to the
    /// `TabView` it renders underneath the tab bar instead.
    ///
    /// Also where the tab is hidden from VoiceOver while the player is up. The player is
    /// an overlay, so the screen under it stays in the accessibility tree, and VoiceOver
    /// walked straight off the player into a page that could not be seen. It has to be
    /// here, in each tab: each one is hosted by its own controller, and the same modifier
    /// on the `TabView` never reached inside them.
    @ViewBuilder
    private func hosted<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            content()
                .accessibilityHidden(navigator.showsPlayer)
        } else {
            content()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    MiniPlayerBar(showsPlayer: showsPlayer)
                }
                .accessibilityHidden(navigator.showsPlayer)
        }
    }
}
