import SwiftUI

/// The long-press menu every song row gets, in one place so the options are
/// identical whether you found the track in an album, a playlist, search or
/// favourites. Divergent per-screen menus were one of the things that made the old
/// app feel improvised.
struct SongMenu: View {
    @Environment(AppState.self) private var appState
    @Environment(UserStateStore.self) private var userState
    @Environment(DownloadCenter.self) private var downloads
    @Environment(LibraryScopeStore.self) private var scope

    let song: Song
    /// Present only where "go to album/artist" would navigate somewhere you already
    /// are.
    var showsNavigation = true
    /// Set false where a rating control is already on screen — the player. Two ways to
    /// set the same 0–5 value, a foot apart, reads as a bug rather than a convenience.
    var showsRating = true

    private func startRadio() {
        Task {
            let songs = await appState.radio.mix(seed: song, scope: scope.scope)
            appState.startRadio(named: "\(song.title) Radio", songs: songs)
        }
    }

    var body: some View {
        // A header rather than a row: it is information, not an action, and it puts the
        // imported Plex counts somewhere they can finally be seen.
        if let count = song.playCount, count > 0 {
            Section("\(count) \(count == 1 ? "play" : "plays")") {
                EmptyView()
            }
        }

        QueueInsertItems(songs: [song])

        Divider()

        Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") {
            startRadio()
        }

        AddToPlaylistMenu(songs: [song], suggestedName: song.album ?? song.title)

        Divider()

        switch downloads.status(for: song.id) {
        case .none:
            Button("Download", systemImage: "arrow.down.circle") {
                downloads.download([song])
            }
        case .waiting, .downloading:
            Button("Cancel Download", systemImage: "xmark.circle") {
                downloads.remove([song.id])
            }
        case .downloaded:
            Button("Remove Download", systemImage: "trash", role: .destructive) {
                downloads.remove([song.id])
            }
        }

        Divider()

        Button(
            userState.isStarred(song) ? "Remove Favourite" : "Favourite",
            systemImage: userState.isStarred(song) ? "heart.slash" : "heart"
        ) {
            userState.toggleStar(song)
        }

        if showsRating {
            Menu("Rate", systemImage: "star.leadinghalf.filled") {
                // Highest first, so the list reads top-down like the stars do
                // left-to-right.
                ForEach((1...5).reversed(), id: \.self) { value in
                    Button {
                        userState.setRating(
                            id: song.id, to: value, current: userState.rating(song)
                        )
                    } label: {
                        if value == userState.rating(song) {
                            Label("\(value) Stars", systemImage: "checkmark")
                        } else {
                            Text("\(value) Star\(value == 1 ? "" : "s")")
                        }
                    }
                }
            }
        }

        if showsNavigation {
            Divider()

            if let albumId = song.albumId, let album = song.album {
                NavigationLink(
                    value: Destination.album(
                        AlbumRef(id: albumId, name: album, artist: song.artist,
                                 coverArt: song.coverArt)
                    )
                ) {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }

            if let artistId = song.artistId, let artist = song.artist {
                NavigationLink(
                    value: Destination.artist(ArtistRef(id: artistId, name: artist))
                ) {
                    Label("Go to Artist", systemImage: "music.mic")
                }
            }
        }
    }
}

/// Five taps, no gesture recognisers: a drag-across-the-stars control is a nice
/// flourish that fights `List` scrolling on a phone.
struct RatingStars: View {
    @Environment(UserStateStore.self) private var userState

    let songID: String
    let serverRating: Int?

    var body: some View {
        let current = userState.rating(id: songID, serverValue: serverRating)

        HStack(spacing: 10) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    userState.setRating(id: songID, to: value, current: current)
                } label: {
                    Image(systemName: value <= current ? "star.fill" : "star")
                        .font(.system(size: 18))
                        .foregroundStyle(value <= current ? Color.appTint : .secondary)
                        .contentShape(Rectangle())
                        .frame(width: 28, height: 32)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.snappy(duration: 0.15), value: current)
    }
}

/// A star that reflects the overlay rather than the fetched value, so it stays
/// correct after you tap it and navigate away and back.
struct FavoriteButton: View {
    @Environment(UserStateStore.self) private var userState

    let id: String
    let kind: SubsonicClient.StarKind
    let serverValue: Bool

    var body: some View {
        let starred = userState.isStarred(id: id, serverValue: serverValue)

        Button {
            userState.toggleStar(id: id, kind: kind, currentlyStarred: starred)
        } label: {
            Image(systemName: starred ? "heart.fill" : "heart")
                .foregroundStyle(starred ? Color.appTint : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(starred ? "Remove favourite" : "Add favourite")
    }
}

/// The swipe-to-favourite button, so a `swipeActions` block stays one line at each
/// call site and reads the overlay rather than the fetched value.
struct FavoriteSwipeButton: View {
    @Environment(UserStateStore.self) private var userState

    let id: String
    let kind: SubsonicClient.StarKind
    let serverValue: Bool

    var body: some View {
        let starred = userState.isStarred(id: id, serverValue: serverValue)

        Button {
            userState.toggleStar(id: id, kind: kind, currentlyStarred: starred)
        } label: {
            Label(
                starred ? "Unfavourite" : "Favourite",
                systemImage: starred ? "heart.slash.fill" : "heart.fill"
            )
        }
        .tint(starred ? .gray : .appTint)
    }
}

extension View {
    /// For an album row in a `List`: long-press for the menu, swipe to favourite.
    /// Both, because the swipe is faster and the menu is the one people find.
    func albumFavorite(_ album: Album) -> some View {
        modifier(AlbumFavoriteModifier(album: album, includesSwipe: true))
    }

    /// For an album card in a grid, where a swipe would be a no-op.
    func albumMenu(_ album: Album) -> some View {
        modifier(AlbumFavoriteModifier(album: album, includesSwipe: false))
    }
}

private struct AlbumFavoriteModifier: ViewModifier {
    @Environment(UserStateStore.self) private var userState
    @Environment(AppState.self) private var appState
    @Environment(DownloadCenter.self) private var downloads

    let album: Album
    let includesSwipe: Bool

    func body(content: Content) -> some View {
        let starred = userState.isStarred(album)

        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if includesSwipe {
                    FavoriteSwipeButton(
                        id: album.id, kind: .album, serverValue: album.isFavorite
                    )
                }
            }
            .contextMenu {
                Button("Play", systemImage: "play.fill") {
                    playAlbum(shuffled: false)
                }
                Button("Shuffle", systemImage: "shuffle") {
                    playAlbum(shuffled: true)
                }
                Button("Download", systemImage: "arrow.down.circle") {
                    downloadAlbum()
                }
                Divider()
                Button(
                    starred ? "Remove Favourite" : "Favourite",
                    systemImage: starred ? "heart.slash" : "heart"
                ) {
                    userState.toggleStar(album)
                }
            }
    }

    /// The album has to be fetched first: a row only carries the album, not its
    /// tracks, and the download is per song.
    private func downloadAlbum() {
        Task {
            guard let detail = try? await appState.client.albumDetail(id: album.id) else { return }
            downloads.download(detail.songs, groupID: album.id, groupName: album.name)
        }
    }

    private func playAlbum(shuffled: Bool) {
        Task {
            guard let detail = try? await appState.client.albumDetail(id: album.id),
                  !detail.songs.isEmpty
            else { return }

            appState.player.play(
                songs: detail.songs, startingAt: 0, source: album.name, shuffled: shuffled
            )
        }
    }
}
