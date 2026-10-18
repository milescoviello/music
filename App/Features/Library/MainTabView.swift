import SwiftUI

/// Home, Library, Downloads and Search. Downloads has its own tab — what is on this
/// phone is the one view that matters most when the server is out of reach, and it
/// should be a tap away rather than inside Library.
struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(QueueSync.self) private var queueSync

    private var navigator: Navigator { appState.navigator }

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
                    .transition(.move(edge: .bottom))
                    .zIndex(2)
            }
        }
        .overlay(alignment: .bottom) { toast }
        .safeAreaInset(edge: .top) { remoteQueueBanner }
        .animation(.snappy(duration: 0.25), value: playlistStore.lastMessage)
        .animation(.snappy(duration: 0.25), value: queueSync.available)
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

    /// Offered rather than applied. Another device's queue arriving unannounced and
    /// replacing what you were listening to would be worse than not syncing at all.
    @ViewBuilder
    private var remoteQueueBanner: some View {
        if let remote = queueSync.available {
            HStack(spacing: Metrics.itemSpacing) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Color.appTint)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Continue from \(remote.changedBy)?")
                        .font(.footnote.weight(.medium))
                    Text(remote.songs.first.map { song in
                        remote.songs.count == 1
                            ? song.title
                            : "\(song.title) + \(remote.songs.count - 1) more"
                    } ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button("Resume") { appState.adoptRemoteQueue() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button {
                    queueSync.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .transition(.move(edge: .top).combined(with: .opacity))
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
        }
    }

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
                    }
                }
            }
            .badge(appState.downloads.progress.count)

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
    @ViewBuilder
    private func hosted<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            content()
        } else {
            content()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    MiniPlayerBar(showsPlayer: showsPlayer)
                }
        }
    }
}
