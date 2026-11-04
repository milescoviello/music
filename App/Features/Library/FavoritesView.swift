import SwiftUI

struct FavoritesView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope
    @Environment(UserStateStore.self) private var userState

    @State private var starred: Starred2?
    @State private var isLoading = false

    // What the server sent, less what was unstarred since and it has not answered for:
    // the list showed what it was opened with until pulled to refresh.
    private var artists: [Artist] { (starred?.artists ?? []).filter { userState.isStarred($0) } }
    private var albums: [Album] { (starred?.albums ?? []).filter { userState.isStarred($0) } }
    private var songs: [Song] { (starred?.songs ?? []).filter { userState.isStarred($0) } }

    var body: some View {
        List {
            // The desktop's Favourites had starred artists, and this did not.
            if !artists.isEmpty {
                Section("Artists") {
                    ForEach(artists) { artist in
                        NavigationLink(value: Destination.artist(ArtistRef(artist))) {
                            HStack(spacing: Metrics.itemSpacing) {
                                ArtistArtwork(id: artist.coverArt, diameter: 40, initials: artist.name.monogram)
                                Text(artist.name).lineLimit(1)
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            FavoriteSwipeButton(id: artist.id, kind: .artist, serverValue: artist.starred != nil)
                        }
                    }
                }
            }

            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums) { album in
                        NavigationLink(value: Destination.album(AlbumRef(album))) {
                            HStack(spacing: Metrics.itemSpacing) {
                                ArtworkImage(
                                    id: album.coverArt,
                                    size: .thumb,
                                    cornerRadius: Metrics.radiusThumb
                                )
                                .frame(width: Metrics.thumbRow, height: Metrics.thumbRow)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.name).lineLimit(1)
                                    if let artist = album.artist {
                                        Text(artist)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        .albumFavorite(album)
                    }
                }
            }

            if !songs.isEmpty {
                Section("Songs") {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, _ in
                        PlayableSongRow(songs: songs, index: index, source: "Favourites")
                    }
                }
            }
        }
        .listStyle(.plain)
        .playerClearance()
        .navigationTitle("Favourites")
        .toolbar {
            if !songs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appState.player.play(
                            songs: songs, startingAt: 0, source: "Favourites", shuffled: true
                        )
                    } label: {
                        Image(systemName: "shuffle")
                    }
                    .accessibilityLabel("Shuffle favourites")
                }
            }
        }
        .overlay {
            if isLoading, starred == nil { ProgressView() }
        }
        .overlay {
            if !isLoading, starred != nil, songs.isEmpty, albums.isEmpty, artists.isEmpty {
                ContentUnavailableView(
                    "No Favourites",
                    systemImage: "heart",
                    description: Text("Starred songs, albums and artists appear here.")
                )
            }
        }
        .refreshable { await load() }
        .task(id: scope.generation) { await load() }
        // And when a star elsewhere reaches the server, so a new favourite shows up.
        .onChange(of: userState.starsDelivered) { Task { await load() } }
    }

    private func load() async {
        isLoading = true
        let client = appState.client
        let currentScope = scope.scope
        appState.beginLoadPass()
        // Shares its key with Home's favourites shelf, deliberately: same data, one copy.
        starred = await appState.cached(CacheKey.starred(currentScope.cacheKey)) {
            try await client.starred(scope: currentScope)
        }
        isLoading = false
    }
}
