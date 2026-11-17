import CGtk
import Foundation

/// An album, the phone's `AlbumDetailView`: the cover centred over its name, artist and
/// year, Play and Shuffle; the tracks by disc as plain numbered rows; the release's facts
/// in small print; the review when the server's agents have one; what sounds like it; the
/// other library's copy; and more by the same artist.
@MainActor
enum AlbumPage {
    static func make(_ env: Env, album: AlbumRef) -> NavigationPage {
        let app = env.app
        let loader = Loader()
        var songs: [Song] = []

        let favourite = Button(icon: Symbol.icon("heart"), "flat")
        let selection = TrackSelection()
        let download = CollectionDownloadButton(env, groupID: album.id, groupName: album.name) { songs }
        // The phone's three: download, the heart, and the menu with Select Tracks in it.
        let menu = MenuButton(icon: Symbol.icon("ellipsis.circle"), "flat") {
            Menu([
                Menus.queueItems(env, songs),
                [
                    .action("Start Radio") { startRadio(app, album: album, songs: songs) },
                    Menus.playlistItem(env, songs, suggestedName: album.name),
                ],
                [.action("Select Tracks") { selection.begin() }],
            ])
        }
        let done = Button("Done", "flat") { selection.end() }
        done.observe { done.isVisible = selection.isActive }
        let page = Page.make(album.name, content: loader.bin, clamp: 860, heading: false) { bar in
            bar.showsTitle(false)
            bar.start(done)
            bar.end(menu)
            bar.end(favourite)
            bar.end(download.root)
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
                favourite.icon = Symbol.icon(starred ? "heart.fill" : "heart")
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

        let artwork = ArtworkView(app, size: .full, side: 200, shape: .player)
        artwork.show(album.coverArt ?? detail.coverArt, fallback: album.name)
        artwork.root.css("detail-art")

        var subtitle: [String] = []
        if let year = detail.year { subtitle.append(String(year)) }
        if let count = detail.songCount { subtitle.append("\(count) tracks") }
        if let duration = detail.duration { subtitle.append(duration.asLongDuration) }

        let artistButton = Button(child: Label(artist ?? "", "detail-artist").xalign(0.5), "flat", "np-plain")
        artistButton.halign(GTK_ALIGN_CENTER).isVisible = artist != nil
        if let id = detail.artistId, let artist {
            artistButton.onClicked { env.open(.artist(ArtistRef(id: id, name: artist))) }
        }

        let header = Box.vertical(spacing: 12) {
            artwork.root
            Box.vertical(spacing: 4) {
                Label(album.name, "detail-title").xalign(0.5).wrap().justify(GTK_JUSTIFY_CENTER)
                artistButton
                Label(subtitle.joined(separator: " · "), "detail-meta").xalign(0.5)
            }
            PlayShuffle.make(
                play: { env.play(songs, source: album.name) },
                shuffle: { env.play(songs, source: album.name, shuffled: true) }
            ).margin(horizontal: 16, vertical: 0)
            HermesNoteView.make(env, subject: .album(id: album.id, name: album.name, artist: artist)).margin(horizontal: 16, vertical: 0)
        }.margins(top: 8, bottom: 16)

        let tracks = Box.vertical(spacing: 0)
        tracks.append(selection.bar(env, all: { songs }, source: album.name))
        // By disc when there is more than one.
        let discs = Dictionary(grouping: songs) { $0.discNumber ?? 1 }.sorted { $0.key < $1.key }
        if discs.count > 1 {
            for (number, discSongs) in discs {
                tracks.append(PlainList.header("Disc \(number)"))
                tracks.append(numberedList(env, discSongs, all: songs, source: album.name, artist: artist, selection: selection))
            }
        } else {
            tracks.append(numberedList(env, songs, all: songs, source: album.name, artist: artist, selection: selection))
        }

        let facts = describe(detail, songs: songs)
        let body = Box.vertical(spacing: 0) {
            header
            tracks
            if !facts.isEmpty {
                Label(facts.joined(separator: " · "), "plain-subtitle").xalign(0).wrap().margins(top: 14, bottom: 0, start: 16, end: 16)
            }
        }
        let copies = Box.vertical(spacing: 0)

        // The review, the other copy, more by the artist and the sonic neighbours arrive
        // after the tracks.
        let extras = Box.vertical(spacing: 24).margins(top: 24)
        body.append(copies)
        body.append(extras)
        guard withExtras else { return body }
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
            if let review {
                // The phone's About This Album: five lines, then More.
                let text = Label(review, "detail-review").xalign(0).wrap().selectable()
                gtk_label_set_lines(text.widget.cast(), 5)
                gtk_label_set_ellipsize(text.widget.cast(), PANGO_ELLIPSIZE_END)
                let toggle = Button("More", "flat", "see-all")
                toggle.onClicked {
                    let expanded = gtk_label_get_lines(text.widget.cast()) == -1
                    gtk_label_set_lines(text.widget.cast(), expanded ? 5 : -1)
                    gtk_label_set_ellipsize(text.widget.cast(), expanded ? PANGO_ELLIPSIZE_END : PANGO_ELLIPSIZE_NONE)
                    toggle.label = expanded ? "More" : "Less"
                }
                extras.append(Box.vertical(spacing: 6) {
                    PlainList.header("About This Album")
                    text.margin(horizontal: 16, vertical: 0)
                    toggle.halign(GTK_ALIGN_START).margin(horizontal: 12, vertical: 0)
                })
            }
            if let similar, !similar.isEmpty {
                extras.append(Shelf.make("Sonically Similar", cards: similar.map { item in
                    Cards.album(env, item.album, single: item.single)
                }))
            }
            if let pair {
                // The other library's copy (the phone keeps both under one name).
                let others = pair.copies.filter { $0.albumId != album.id }
                if !others.isEmpty {
                    let list = PlainList.list()
                    for copy in others {
                        list.append(PlainList.row(leading: nil, title: "\(copy.library) · \(copy.format)",
                                                  subtitle: "\(copy.tracks) songs · \(copy.plays) plays", minHeight: 56)) {
                            env.open(.album(AlbumRef(id: copy.albumId, name: copy.name, artist: copy.artist)))
                        }
                    }
                    copies.append(PlainList.header(others.count == 1 ? "Also in \(others[0].library)" : "Other Copies"))
                    copies.append(list)
                }
            }
            if !more.isEmpty, let artist {
                extras.append(Shelf.make("More by \(artist)", cards: more.map { Cards.album(env, $0) }))
            }
        }
        return body
    }

    /// Tracks by number, where activating one plays the whole album from there.
    private static func numberedList(_ env: Env, _ songs: [Song], all: [Song], source: String, artist: String?, selection: TrackSelection) -> Widget {
        let list = PlainList.list()
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
