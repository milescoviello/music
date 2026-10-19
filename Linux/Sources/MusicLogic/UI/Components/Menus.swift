import Foundation

/// The menus every song, album and selection gets — the phone's `SongMenu` and album
/// context menu, item for item, so a track offers the same things wherever it was found.
@MainActor
enum Menus {
    /// Plexamp's three ways into the queue.
    static func queueItems(_ env: Env, _ songs: [Song]) -> [Menu.Item] {
        let player = env.player
        var items: [Menu.Item] = [.action("Play Next") { player.playNext(songs) }]
        if player.canAddToUpNext {
            items.append(.action("Add to Up Next") { player.addToUpNext(songs) })
        }
        items.append(.action("Add to Queue") { player.append(songs) })
        return items
    }

    /// Add to Playlist, with New Playlist… first.
    static func playlistItem(_ env: Env, _ songs: [Song], suggestedName: String) -> Menu.Item {
        let store = env.app.playlistStore
        var existing: [Menu.Item] = store.playlists.map { playlist in
            .action(playlist.name) { Task { await store.add(songs, to: playlist) } }
        }
        if existing.isEmpty, !store.isLoading {
            Task { await store.loadIfNeeded() }
            existing = [.action("Loading playlists…", enabled: false) {}]
        }
        return .submenu("Add to Playlist", [
            [.action("New Playlist…") { newPlaylist(env, songs, suggested: suggestedName) }],
            existing,
        ])
    }

    static func newPlaylist(_ env: Env, _ songs: [Song], suggested: String) {
        Dialogs.prompt(
            "New Playlist",
            body: songs.isEmpty ? "An empty playlist you can add to later."
                : "\(songs.count) \(songs.count == 1 ? "song" : "songs") will be added.",
            placeholder: "Playlist name",
            text: suggested,
            confirm: "Create"
        ) { name in
            Task { _ = await env.app.playlistStore.create(name: name, songs: songs) }
        }
    }

    /// The long-press menu for one song.
    static func song(_ env: Env, _ song: Song, showsNavigation: Bool = true, showsRating: Bool = true) -> Menu {
        let app = env.app
        let user = app.userState
        let downloads = app.downloads
        var sections: [[Menu.Item]] = []

        if let count = song.playCount, count > 0 {
            sections.append([.action("\(count) \(count == 1 ? "play" : "plays")", enabled: false) {}])
        }
        sections.append(queueItems(env, [song]))

        var more: [Menu.Item] = [
            .action("Start Radio") { startRadio(app, from: song) },
        ]
        if showsNavigation {
            more.append(.action("Sonic Adventure…") { env.open(.sonicAdventure(song)) })
        }
        more.append(playlistItem(env, [song], suggestedName: song.album ?? song.title))
        sections.append(more)

        if downloads.isDownloaded(song.id) {
            sections.append([.action("Remove Download", destructive: true) { downloads.remove([song.id]) }])
        } else if downloads.isArriving(song.id) {
            sections.append([.action("Cancel Download") { downloads.remove([song.id]) }])
        } else {
            sections.append([.action("Download") { downloads.download([song]) }])
        }

        let starred = user.isStarred(song)
        var personal: [Menu.Item] = [
            .action(starred ? "Remove Favourite" : "Favourite") { user.toggleStar(song) },
        ]
        if showsRating {
            let current = user.rating(song)
            personal.append(.choice(
                "Rate",
                options: (1...5).reversed().map { ("\($0)", "\($0) Star\($0 == 1 ? "" : "s")") },
                selected: current > 0 ? "\(current)" : nil
            ) { value in
                user.setRating(id: song.id, to: Int(value) ?? 0, current: user.rating(song))
            })
        }
        sections.append(personal)

        sections.append(navigationItems(env, song, jumps: !showsNavigation))
        return Menu(sections)
    }

    /// Go to Album and Go to Artist. From inside the player they are jumps — close it,
    /// open the destination in Library — rather than pushes into nowhere.
    static func navigationItems(_ env: Env, _ song: Song, jumps: Bool) -> [Menu.Item] {
        var items: [Menu.Item] = []
        let open: (Destination) -> Void = jumps ? { env.app.navigator.open($0) } : { env.open($0) }
        if let albumID = song.albumId, let album = song.album {
            items.append(.action("Go to Album") {
                open(.album(AlbumRef(id: albumID, name: album, artist: song.artist, coverArt: song.coverArt)))
            })
        }
        if let artistID = song.artistId, let artist = song.artist {
            items.append(.action("Go to Artist") { open(.artist(ArtistRef(id: artistID, name: artist))) })
        }
        return items
    }

    static func startRadio(_ app: AppState, from song: Song) {
        Task {
            let songs = await app.radio.mix(seed: song, scope: app.scope.scope)
            app.startRadio(
                named: "\(song.title) Radio", songs: songs,
                station: .radio(seedIDs: [song.id], title: "\(song.title) Radio")
            )
        }
    }

    /// An album card's or row's menu: the album has to be fetched before it can be
    /// queued, since a card carries the album and not its tracks.
    static func album(_ env: Env, _ album: Album) -> Menu {
        let app = env.app
        let user = app.userState
        let downloads = app.downloads
        func withSongs(_ action: @escaping @MainActor ([Song]) -> Void) {
            Task {
                guard let detail = try? await app.client.albumDetail(id: album.id), !detail.songs.isEmpty else { return }
                action(detail.songs)
            }
        }
        let player = app.player
        var queue: [Menu.Item] = [.action("Play Next") { withSongs { player.playNext($0) } }]
        if player.canAddToUpNext {
            queue.append(.action("Add to Up Next") { withSongs { player.addToUpNext($0) } })
        }
        queue.append(.action("Add to Queue") { withSongs { player.append($0) } })

        let starred = user.isStarred(album)
        return Menu([
            [
                .action("Play") { withSongs { player.play(songs: $0, startingAt: 0, source: album.name) } },
                .action("Shuffle") { withSongs { player.play(songs: $0, startingAt: 0, source: album.name, shuffled: true) } },
            ],
            queue,
            [
                downloads.hasDownload(group: album.id)
                    ? .action("Remove Download", destructive: true) { downloads.removeGroup(album.id) }
                    : .action("Download") {
                        withSongs { downloads.download($0, groupID: album.id, groupName: album.name) }
                    },
            ],
            [
                .action(starred ? "Remove Favourite" : "Favourite") { user.toggleStar(album) },
                .action("Go to Artist", enabled: album.artistId != nil) {
                    if let id = album.artistId, let name = album.artist {
                        env.open(.artist(ArtistRef(id: id, name: name)))
                    }
                },
            ],
        ])
    }
}
