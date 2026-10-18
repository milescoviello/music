import CGtk
import Foundation

/// An album: its cover and the essentials, Play and Shuffle, the tracks by disc, what the
/// files are, the review when the server's agents have one, and what sounds like it or is
/// by the same artist.
@MainActor
enum AlbumPage {
    static func make(_ env: Env, album: AlbumRef) -> NavigationPage {
        let app = env.app
        let loader = Loader()
        var songs: [Song] = []

        let favourite = Button(icon: "emblem-favorite-symbolic", "flat")
        let download = CollectionDownloadButton(env, groupID: album.id, groupName: album.name) { songs }
        let menu = MenuButton(icon: "view-more-symbolic", "flat") {
            Menu([
                Menus.queueItems(env, songs),
                [
                    .action("Start Radio") { startRadio(app, album: album, songs: songs) },
                    Menus.playlistItem(env, songs, suggestedName: album.name),
                ],
            ])
        }
        let page = Page.make(album.name, content: loader.bin) { bar in
            bar.end(menu)
            bar.end(favourite)
            bar.end(download.root)
        }

        loader.run({ () -> AlbumDetail? in
            let id = album.id
            let client = app.client
            return await app.cached(CacheKey.album(id)) { try await client.albumDetail(id: id) }
        }, failure: {
            Loader.empty("Couldn't Load This Album", icon: "network-offline-symbolic", description: "It could not be loaded, and there is no saved copy.")
        }) { detail in
            songs = detail.songs
            favourite.observe {
                let starred = app.userState.isStarred(id: album.id, serverValue: detail.starred != nil)
                favourite.setCSS("accent", starred)
                favourite.tooltip(starred ? "Remove Favourite" : "Favourite")
            }
            favourite.onClicked {
                let starred = app.userState.isStarred(id: album.id, serverValue: detail.starred != nil)
                app.userState.toggleStar(id: album.id, kind: .album, currentlyStarred: starred)
            }
            return content(env, album: album, detail: detail)
        }
        return page
    }

    private static func content(_ env: Env, album: AlbumRef, detail: AlbumDetail) -> Widget {
        let app = env.app
        let songs = detail.songs
        let artist = album.artist ?? detail.artist

        let artwork = ArtworkView(app, size: .full, side: 220, shape: .player)
        artwork.show(album.coverArt ?? detail.coverArt, fallback: album.name)

        var subtitle: [String] = []
        if let year = detail.year { subtitle.append(String(year)) }
        if let count = detail.songCount { subtitle.append("\(count) tracks") }
        if let duration = detail.duration { subtitle.append(duration.asLongDuration) }

        let artistButton = Button(artist ?? "", "flat", "link-button", "page-subtitle")
        artistButton.halign(GTK_ALIGN_START).isVisible = artist != nil
        if let id = detail.artistId, let artist {
            artistButton.onClicked { env.open(.artist(ArtistRef(id: id, name: artist))) }
        }

        let header = Box.horizontal(spacing: 24) {
            artwork.root
            Box.vertical(spacing: 6) {
                Label(album.name, "page-title").wrap()
                artistButton
                Label(subtitle.joined(separator: " · "), "caption", "dim")
                Box.horizontal(spacing: 8) {
                    Button("Play", icon: "media-playback-start-symbolic", "suggested-action", "pill") {
                        env.play(songs, source: album.name)
                    }
                    Button("Shuffle", icon: "media-playlist-shuffle-symbolic", "pill") {
                        env.play(songs, source: album.name, shuffled: true)
                    }
                }.margins(top: 12)
            }.valign(GTK_ALIGN_END).hexpand()
        }

        let body = Box.vertical(spacing: 18) {
            header
            HermesNoteView.make(env, subject: .album(id: album.id, name: album.name, artist: artist))
        }

        // By disc when there is more than one.
        let discs = Dictionary(grouping: songs) { $0.discNumber ?? 1 }.sorted { $0.key < $1.key }
        if discs.count > 1 {
            for (number, discSongs) in discs {
                body.append(Label("Disc \(number)", "heading"))
                body.append(numberedList(env, discSongs, all: songs, source: album.name))
            }
        } else {
            body.append(numberedList(env, songs, all: songs, source: album.name))
        }

        let details = describe(detail, songs: songs)
        if !details.isEmpty { body.append(Label(details, "caption", "dim").wrap()) }

        // The review, more by the artist and the sonic neighbours arrive after the tracks.
        let extras = Box.vertical(spacing: 24)
        body.append(extras)
        let alive = extras.liveness
        Task { @MainActor in
            let client = app.client
            async let info = try? client.albumInfo(id: album.id)
            async let similarAlbums = app.sonic.similarAlbums(to: album.id)
            var more: [Album] = []
            if let artistID = detail.artistId, let artist = try? await client.artistDetail(id: artistID) {
                more = artist.albums.filter { $0.id != album.id }
            }
            let review = await info?.plainNotes
            let similar = await similarAlbums
            guard alive.isAlive else { return }
            if let review {
                extras.append(PreferencesGroup("About This Album") {
                    Label(review, "dim").wrap().selectable().margin(12)
                })
            }
            if let similar, !similar.isEmpty {
                extras.append(Shelf.make("Sonically Similar", cards: similar.map { Cards.album(env, $0) }))
            }
            if !more.isEmpty, let artist {
                extras.append(Shelf.make("More by \(artist)", cards: more.map { Cards.album(env, $0) }))
            }
        }
        return body.margin(horizontal: 12, vertical: 24)
    }

    /// Tracks by number, where activating one plays the whole album from there.
    private static func numberedList(_ env: Env, _ songs: [Song], all: [Song], source: String) -> Widget {
        let list = ListBox()
        for song in songs {
            let row = SongRowView(env, style: .numbered, showsNavigation: false)
            row.bind(song)
            let index = all.firstIndex(of: song) ?? 0
            list.append(row.root) { env.play(all, from: index, source: source) }
        }
        return list
    }

    private static func describe(_ detail: AlbumDetail, songs: [Song]) -> String {
        var parts: [String] = []
        if let first = songs.first, let suffix = first.suffix?.uppercased(),
           songs.allSatisfy({ $0.suffix?.uppercased() == suffix }) {
            if let depth = first.bitDepth, let rate = first.samplingRate, rate > 0, depth > 0,
               songs.allSatisfy({ $0.bitDepth == depth && $0.samplingRate == rate }) {
                let khz = Double(rate) / 1_000
                parts.append("\(suffix) \(depth)/\(khz == khz.rounded() ? String(Int(khz)) : String(format: "%.1f", khz))")
            } else {
                parts.append(suffix)
            }
        }
        if let genre = detail.genre, !genre.isEmpty { parts.append(genre) }
        return parts.joined(separator: " · ")
    }

    private static func startRadio(_ app: AppState, album: AlbumRef, songs: [Song]) {
        guard let seed = songs.randomElement() else { return }
        Task {
            let mix = await app.radio.mix(seed: seed, scope: app.scope.scope)
            app.startRadio(
                named: "\(album.name) Radio", songs: mix,
                station: .radio(seedIDs: songs.map(\.id), title: "\(album.name) Radio")
            )
        }
    }
}
