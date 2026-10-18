import SwiftUI

/// The hub. Six peer facets is exactly the case a tab bar cannot hold, which is why
/// Apple Music uses a list here too.
struct LibraryHubView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope
    @Environment(DownloadCenter.self) private var downloads

    @State private var recentlyAdded: [Album] = []

    private let gridColumns = [
        GridItem(.flexible(), spacing: Metrics.itemSpacing),
        GridItem(.flexible(), spacing: Metrics.itemSpacing),
    ]

    /// Driven by `Navigator`, so a jump out of the player can push into this tab.
    private var libraryPath: Binding<NavigationPath> {
        Binding(
            get: { appState.navigator.libraryPath },
            set: { appState.navigator.libraryPath = $0 }
        )
    }

    var body: some View {
        NavigationStack(path: libraryPath) {
            List {
                Section {
                    row("Playlists", "music.note.list", .playlists)
                    row("Artists", "music.microphone", .artists)
                    row("Albums", "square.stack", .albums(.alphabeticalByName))
                    row("Tracks", "music.note", .tracks)
                    row("Recently Played", "clock.arrow.circlepath", .albums(.recent))
                    row("Most Played", "chart.bar", .albums(.frequent))
                    row("Genres", "guitars", .genres)
                    row("Stations", "dot.radiowaves.left.and.right", .stations)
                    row("Charts", "chart.line.uptrend.xyaxis", .charts)
                }

                // Plexamp's other categories, cut from the whole album list.
                Section {
                    ForEach(LibraryFacet.allCases, id: \.self) { facet in
                        row(facet.title, facet.symbol, .libraryFacet(facet))
                    }
                    row("Folders", "folder", .folder(nil))
                }

                Section {
                    row("Favourites", "heart", .favorites)
                    // The one row whose contents live on this phone, so it is the
                    // one row where a count says something the screen does not.
                    row(
                        "Downloads",
                        "arrow.down.circle",
                        .downloads,
                        badge: downloads.catalog.entries.isEmpty
                            ? nil
                            : "\(downloads.catalog.entries.count)"
                    )
                    row("Rediscover", "clock.arrow.circlepath", .rediscover)
                    row("Make a Playlist", "sparkles", .vibePlaylist)
                    row("Lyric Search", "text.magnifyingglass", .lyricSearch(""))
                    row("Trip Mode", "airplane", .tripMode)
                    row("Stats", "chart.bar.xaxis", .stats)
                    row("Library Health", "stethoscope", .libraryHealth)
                    row("Request Music", "arrow.down.heart", .requestMusic(""))
                    row("Settings", "gearshape", .settings)
                }

                if !recentlyAdded.isEmpty {
                    Section {
                        // A grid inside a List works reliably as long as the row's
                        // insets and background are cleared.
                        LazyVGrid(columns: gridColumns, spacing: Metrics.itemSpacing) {
                            ForEach(recentlyAdded) { album in
                                NavigationLink(value: Destination.album(AlbumRef(album))) {
                                    AlbumCard(album: album)
                                }
                                .buttonStyle(.plain)
                                .albumMenu(album)
                            }
                        }
                        .listRowInsets(EdgeInsets(
                            top: 8, leading: Metrics.gutter,
                            bottom: 8, trailing: Metrics.gutter
                        ))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } header: {
                        HStack {
                            Text("Recently Added")
                            Spacer()
                            NavigationLink(value: Destination.albums(.newest)) {
                                Text("See All").font(.footnote)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .navigationTitle("Library")
            .musicDestinations()
            .offlineBanner()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { LibraryScopeMenu() }
            }
            .task(id: scope.generation) {
                recentlyAdded = (try? await appState.client.albums(
                    type: .newest, size: 6, scope: scope.scope
                )) ?? []
            }
        }
    }

    private func row(
        _ title: String,
        _ symbol: String,
        _ destination: Destination,
        badge: String? = nil
    ) -> some View {
        NavigationLink(value: destination) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(Color.appTint)
                    // Fixed icon width so every title shares a left edge.
                    .frame(width: 28, alignment: .center)
            }
        }
        .badge(badge)
        .frame(minHeight: Metrics.rowCategory)
    }
}
