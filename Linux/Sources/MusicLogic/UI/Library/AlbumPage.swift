import CGtk
import Foundation

/// An album: its cover and the essentials over the cover's own colours, Play and Shuffle,
/// the tracks by disc as plain rows, and beside them a column of what the files are, the
/// other library's copy and what sounds like it; under them the review when the server's
/// agents have one, and more by the same artist.
@MainActor
enum AlbumPage {
    static func make(_ env: Env, album: AlbumRef) -> NavigationPage {
        let app = env.app
        let loader = Loader()
        var songs: [Song] = []

        let favourite = Button(icon: "music-heart-symbolic", "flat")
        let selection = TrackSelection()
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
        let page = Page.make(album.name, content: loader.bin, heading: false) { bar in
            bar.end(menu)
            bar.end(favourite)
            bar.end(download.root)
            bar.end(selection.button())
        }

        page.coverArt = album.coverArt
        var answered = false

        loader.run({ () -> AlbumDetail? in
            let id = album.id
            let client = app.client
            return await app.cached(CacheKey.album(id)) { try await client.albumDetail(id: id) }
        }, failure: {
            Loader.empty("Couldn't Load This Album", icon: "network-offline-symbolic", description: "It could not be loaded, and there is no saved copy.")
        }) { detail in
            answered = true
            songs = detail.songs
            download.songsChanged()
            if page.coverArt == nil { page.coverArt = detail.coverArt }
            favourite.observe {
                let starred = app.userState.isStarred(id: album.id, serverValue: detail.starred != nil)
                favourite.setCSS("accent", starred)
                favourite.tooltip(starred ? "Remove Favourite" : "Favourite")
            }
            favourite.onClicked {
                let starred = app.userState.isStarred(id: album.id, serverValue: detail.starred != nil)
                app.userState.toggleStar(id: album.id, kind: .album, currentlyStarred: starred)
            }
            return content(env, album: album, detail: detail, selection: selection)
        }
        // The copy saved last time at once, the server's in its place when it answers: the
        // server is asked first, as stars and play counts change on the other devices, but
        // waiting on it put a spinner on every album opened, for as long as the round trip
        // over the tailnet took. The saved copy shows the tracks, without the extras.
        Task { @MainActor in
            guard let saved = await app.cache.load(AlbumDetail.self, for: CacheKey.album(album.id)), !answered
            else { return }
            songs = saved.songs
            download.songsChanged()
            if page.coverArt == nil { page.coverArt = saved.coverArt }
            loader.bin.child = content(env, album: album, detail: saved, selection: selection, extras: false)
        }
        return page
    }

    private static func content(
        _ env: Env, album: AlbumRef, detail: AlbumDetail, selection: TrackSelection, extras withExtras: Bool = true
    ) -> Widget {
        let app = env.app
        let songs = detail.songs
        let artist = album.artist ?? detail.artist

        let artwork = ArtworkView(app, size: .full, side: 232, shape: .player)
        artwork.show(album.coverArt ?? detail.coverArt, fallback: album.name)

        var subtitle: [String] = []
        if let year = detail.year { subtitle.append(String(year)) }
        if let count = detail.songCount { subtitle.append(count == 1 ? "1 song" : "\(count) songs") }
        if let duration = detail.duration { subtitle.append(duration.asLongDuration) }

        let artistButton = Button(artist ?? "", "flat", "link-button", "hero-artist")
        artistButton.halign(GTK_ALIGN_START).isVisible = artist != nil
        if let id = detail.artistId, let artist {
            artistButton.onClicked { env.open(.artist(ArtistRef(id: id, name: artist))) }
        }

        let header = Box.horizontal(spacing: 28) {
            artwork.root
            Box.vertical(spacing: 4) {
                Label(songs.count == 1 ? "Single" : "Album", "hero-kind").xalign(0)
                Label(album.name, "hero-title").wrap().xalign(0).lines(2).ellipsize()
                artistButton
                Label(subtitle.joined(separator: " · "), "hero-meta").xalign(0)
                Box.horizontal(spacing: 10) {
                    Button("Play", icon: "media-playback-start-symbolic", "suggested-action", "pill") {
                        env.play(songs, source: album.name)
                    }
                    Button("Shuffle", icon: "media-playlist-shuffle-symbolic", "pill", "glass-pill") {
                        env.play(songs, source: album.name, shuffled: true)
                    }
                }.margins(top: 14)
            }.valign(GTK_ALIGN_END).hexpand()
        }

        let tracks = Box.vertical(spacing: 12)
        tracks.append(selection.bar(env, all: { songs }, source: album.name))
        // By disc when there is more than one.
        let discs = Dictionary(grouping: songs) { $0.discNumber ?? 1 }.sorted { $0.key < $1.key }
        if discs.count > 1 {
            for (number, discSongs) in discs {
                tracks.append(Label("Disc \(number)", "heading").xalign(0).margins(top: 6, bottom: 0, start: 8, end: 0))
                tracks.append(numberedList(env, discSongs, all: songs, source: album.name, artist: artist, selection: selection))
            }
        } else {
            tracks.append(numberedList(env, songs, all: songs, source: album.name, artist: artist, selection: selection))
        }

        let side = Box.vertical(spacing: 14).hexpand(false)
        side.size(width: 300, height: -1)
        let facts = describe(detail, songs: songs)
        if !facts.isEmpty {
            let panel = Box.vertical(spacing: 6).css("glass", "side-panel")
            panel.append(Label("Details", "side-heading").xalign(0))
            for fact in facts { panel.append(Label(fact, "side-fact").xalign(0).wrap().maxWidthChars(30)) }
            side.append(panel)
        }
        let copies = Box.vertical(spacing: 6).css("glass", "side-panel").visible(false)
        let similarPanel = Box.vertical(spacing: 4).css("glass", "side-panel").visible(false)
        side.append(copies)
        side.append(similarPanel)

        // Side by side when there is room; the column under the tracks when there isn't.
        let columns = Box.horizontal(spacing: 28) {
            tracks.hexpand()
            side
        }
        let sizer = Widths.watch { width in
            let narrow = width < 860
            columns.orientation(narrow ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL)
            side.size(width: narrow ? -1 : 300, height: -1)
            // The cover over the title on a phone's width.
            header.orientation(width < 560 ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL)
            artwork.root.halign(width < 560 ? GTK_ALIGN_CENTER : GTK_ALIGN_FILL)
        }

        let body = Box.vertical(spacing: 22) {
            header
            HermesNoteView.make(env, subject: .album(id: album.id, name: album.name, artist: artist))
            sizer
            columns
        }

        // The review, the other copy, more by the artist and the sonic neighbours arrive
        // after the tracks.
        let extras = Box.vertical(spacing: 24)
        body.append(extras)
        guard withExtras else { return body.margin(horizontal: 12, vertical: 20) }
        let alive = extras.liveness
        Task { @MainActor in
            let client = app.client
            async let info = try? client.albumInfo(id: album.id)
            async let similarAlbums = app.sonic.similarAlbumsWithSingles(to: album.id, limit: 6)
            async let duplicates = DuplicatesCache.albums(app)
            var more: [Album] = []
            if let artistID = detail.artistId, let artist = try? await client.artistDetail(id: artistID) {
                more = SearchRanking.moreBy(artist.albums, than: Album(id: album.id, name: detail.name, artist: detail.artist))
            }
            let review = await info?.plainNotes
            let similar = await similarAlbums
            let pair = await duplicates?.first { $0.copies.contains { $0.albumId == album.id } }
            guard alive.isAlive else { return }
            if let pair {
                let others = pair.copies.filter { $0.albumId != album.id }
                copies.append(Label(others.count == 1 ? "Also in \(others[0].library)" : "Other Copies", "side-heading").xalign(0))
                for copy in others {
                    let row = Box.horizontal(spacing: 8) {
                        Box.vertical(spacing: 0) {
                            Label(copy.format, "side-fact").xalign(0)
                            Label("\(copy.tracks) songs · \(copy.plays) plays", "side-detail").xalign(0)
                        }.hexpand()
                        Icon("go-next-symbolic", size: 14).opacity(0.6)
                    }
                    copies.append(Button(child: row, "flat", "side-link") {
                        env.open(.album(AlbumRef(id: copy.albumId, name: copy.name, artist: copy.artist)))
                    })
                }
                copies.isVisible = !others.isEmpty
            }
            if let similar, !similar.isEmpty {
                similarPanel.append(Label("Sonically Similar", "side-heading").xalign(0))
                for item in similar.prefix(5) {
                    let cover = ArtworkView(app, size: .thumb, side: 40, shape: .thumb)
                    cover.show(item.album.coverArt, fallback: item.album.name)
                    let row = Box.horizontal(spacing: 10) {
                        cover.root
                        Box.vertical(spacing: 0) {
                            Label(item.album.name, "side-fact").xalign(0).ellipsize().maxWidthChars(1)
                            Label(item.album.artist ?? "", "side-detail").xalign(0).ellipsize().maxWidthChars(1)
                        }.hexpand().valign(GTK_ALIGN_CENTER)
                    }
                    let link = Button(child: row, "flat", "side-link") {
                        if let single = item.single {
                            env.play([single], source: "Sonically Similar")
                        } else {
                            env.open(.album(AlbumRef(item.album)))
                        }
                    }
                    similarPanel.append(link.contextMenu { Menus.album(env, item.album) })
                }
                similarPanel.isVisible = true
            }
            if let review {
                extras.append(PreferencesGroup("About This Album") {
                    Label(review, "dim").wrap().selectable().margin(12)
                })
            }
            if !more.isEmpty, let artist {
                extras.append(Shelf.make("More by \(artist)", cards: more.map { Cards.album(env, $0) }))
            }
        }
        return body.margin(horizontal: 12, vertical: 20)
    }

    /// Tracks by number, where activating one plays the whole album from there.
    private static func numberedList(_ env: Env, _ songs: [Song], all: [Song], source: String, artist: String?, selection: TrackSelection) -> Widget {
        let list = ListBox(boxed: false)
        list.css("track-list")
        for song in songs {
            let row = SongRowView(env, style: .numbered, showsNavigation: false)
            row.bind(song, albumArtist: artist)
            let index = all.firstIndex(of: song) ?? 0
            list.append(selection.row(row.root, song: song)) {
                selection.activate(song) { env.play(all, from: index, source: source) }
            }
        }
        return list
    }

    private static func describe(_ detail: AlbumDetail, songs: [Song]) -> [String] {
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
        // The phone's release facts: label, date, and every genre, not only the first.
        if let labels = detail.recordLabels?.map(\.name).filter({ !$0.isEmpty }), !labels.isEmpty {
            parts.append(labels.joined(separator: ", "))
        }
        if let released = (detail.originalReleaseDate ?? detail.releaseDate)?.spelledOut {
            parts.append("Released \(released)")
        }
        if let genres = detail.genres.map({ MainGenre.usable($0.map(\.name)) }), !genres.isEmpty {
            parts.append(genres.joined(separator: ", "))
        } else if let genre = detail.genre, !genre.isEmpty {
            parts.append(genre)
        }
        return parts
    }

    /// The albums in both libraries, for "Also in": the whole list is the service's one
    /// answer, so it is asked for once in ten minutes, not once per album opened.
    @MainActor
    enum DuplicatesCache {
        private static var list: [SonicClient.DuplicateAlbum]?
        private static var fetchedAt = Date.distantPast
        private static var inFlight: Task<[SonicClient.DuplicateAlbum]?, Never>?

        static func albums(_ app: AppState) async -> [SonicClient.DuplicateAlbum]? {
            if let list, Date.now.timeIntervalSince(fetchedAt) < 600 { return list }
            if let inFlight { return await inFlight.value }
            let client = SonicClient(configuration: app.sonic.configuration)
            let task = Task { try? await client.duplicateAlbums() }
            inFlight = task
            let fetched = await task.value
            inFlight = nil
            if let fetched {
                list = fetched
                fetchedAt = .now
            }
            return fetched ?? list
        }
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
