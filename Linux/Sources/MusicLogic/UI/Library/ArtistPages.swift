import CGtk
import Foundation

/// Every artist, A to Z, with a filter field and the phone's alphabet rail: a letter
/// jumps to the server's section for it.
@MainActor
enum ArtistList {
    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let filter = SearchEntry(placeholder: "Filter artists")
        var all: [Artist] = []
        /// The server's sections, each with where its first artist is in `all`. Its own,
        /// not letters worked out here: Navidrome files "La Roux" under R.
        var sections: [(letter: String, first: Int)] = []
        let list = ItemList<Artist, ArtistRowCell>(.list, setup: {
            let cell = ArtistRowCell(app)
            let reference = WeakReference(cell)
            cell.root.contextMenu {
                guard let artist = reference.value?.artist else { return nil }
                return Menus.artist(env, artist)
            }
            return (cell.root, cell)
        }, bind: { cell, artist, _ in
            cell.bind(artist)
        }, activate: { artist, _ in
            env.open(.artist(ArtistRef(artist)))
        })
        // Its own column beside the list, not over it, where it hid the album counts.
        let rail = Box.vertical(spacing: 0)
        rail.css("alphabet-rail").valign(GTK_ALIGN_CENTER).margin(horizontal: 4, vertical: 8)
        let stack = Stack()
        stack.add(Spinner().size(32).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER), name: "loading")
        stack.add(Box.horizontal(spacing: 0) {
            ScrolledWindow(list.view).hexpand().vexpand()
            rail
        }, name: "list")
        let empty = Bin()
        stack.add(empty, name: "empty")

        func apply() {
            let text = filter.text.trimmingCharacters(in: .whitespaces)
            let shown = text.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(text) }
            list.set(shown)
            // Only for the whole list, and only when it is long enough to need it.
            rail.removeAll()
            rail.isVisible = text.isEmpty && all.count > 40
            if rail.isVisible {
                for section in sections {
                    let first = section.first
                    rail.append(Button(section.letter, "flat", "alphabet-letter") { list.scroll(toTop: first) })
                }
            }
            if shown.isEmpty {
                empty.child = Loader.empty(all.isEmpty ? "No Artists" : "No Matches", icon: "avatar-default-symbolic")
                stack.visibleName = "empty"
            } else {
                stack.visibleName = "list"
            }
        }
        filter.onSearch { _ in apply() }

        let body = Box.vertical(spacing: 0) {
            Clamp(filter.margin(12), maximum: 600)
            stack.vexpand()
        }
        let alive = body.liveness
        body.observe {
            let scope = app.scope.scope
            _ = app.scope.generation
            stack.visibleName = "loading"
            Task { @MainActor in
                let client = app.client
                app.beginLoadPass()
                let indexes = await app.cached(CacheKey.artistIndex(scope.cacheKey)) {
                    try await client.artists(scope: scope)
                } ?? []
                guard alive.isAlive else { return }
                all = indexes.flatMap(\.artists)
                var position = 0
                sections = indexes.compactMap { index in
                    defer { position += index.artists.count }
                    return index.artists.isEmpty ? nil : (index.name, position)
                }
                apply()
            }
        }
        return Page.make("Artists", content: body, scrolls: false, clamp: nil) { bar in
            bar.end(ScopeMenu.make(app))
        }
    }
}

/// An artist as a row: round picture, name, a heart when favourited, album count.
@MainActor
final class ArtistRowCell {
    let root: Box
    private(set) var artist: Artist?
    private let app: AppState
    private let artwork: ArtworkView
    private let name = Label("").ellipsize()
    private let heart = Icon("music-heart-symbolic", size: 14).css("accent")
    private let count = Label("", "song-meta")
    private var marks: Observer?

    init(_ app: AppState) {
        self.app = app
        let artwork = ArtworkView(app, size: .thumb, side: 40, shape: .round)
        self.artwork = artwork
        let (name, heart, count) = (self.name, self.heart, self.count)
        root = Box.horizontal(spacing: 12) {
            artwork.root
            name.hexpand()
            heart
            count
        }
        root.margin(horizontal: 12, vertical: 4)
        root.keep(self)
    }

    func bind(_ artist: Artist) {
        self.artist = artist
        name.text = artist.name
        count.text = artist.albumCount.map(String.init) ?? ""
        artwork.show(artist.coverArt, fallback: artist.name)
        // Watched once the row has its artist, so a favourite from the menu shows here.
        marks?.cancel()
        let reference = WeakReference(self)
        marks = Observer {
            guard let row = reference.value, let artist = row.artist else { return }
            row.heart.isVisible = row.app.userState.isStarred(artist)
        }
    }
}

/// An artist, the phone's `ArtistDetailView`: the round picture (its initials: the server
/// has no artist images) centred over the name and album count, Play and Shuffle over the
/// whole discography; Popular five at a time; the discography split Plexamp's way —
/// Albums, Singles & EPs, Live, Compilations — what they appear on, who sounds like them,
/// and what the server knows about them.
@MainActor
enum ArtistPage {
    private static let popularStep = 5

    static func make(_ env: Env, artist: ArtistRef) -> NavigationPage {
        let app = env.app
        let favourite = Button(icon: Symbol.icon("heart"), "flat")
        let radio = Button(icon: Symbol.icon("dot.radiowaves.left.and.right"), "flat") {
            Task {
                let mix = await app.radio.artistMix(artist, scope: app.scope.scope)
                app.startRadio(named: "\(artist.name) Radio", songs: mix, station: .artistMix(ids: [artist.id], names: [artist.name]))
            }
        }
        radio.tooltip("Start Artist Radio")

        var discography: [Song] = []
        let picture = ArtworkView(app, size: .card, side: 112, shape: .round)
        picture.show(artist.coverArt, fallback: artist.name)
        let albumCount = Label("", "detail-artist").xalign(0.5)
        let buttons = PlayShuffle.make(
            play: { if !discography.isEmpty { env.play(discography, source: artist.name) } },
            shuffle: { if !discography.isEmpty { env.play(discography, source: artist.name, shuffled: true) } }
        )
        buttons.isSensitive = false
        let header = Box.vertical(spacing: 12) {
            picture.root
            Box.vertical(spacing: 4) {
                Label(artist.name, "detail-title").xalign(0.5).wrap().justify(GTK_JUSTIFY_CENTER)
                albumCount
            }
            buttons.margin(horizontal: 16, vertical: 0)
            HermesNoteView.make(env, subject: .artist(id: artist.id, name: artist.name), compact: true)
                .margin(horizontal: 16, vertical: 0)
        }.margins(top: 16)

        let body = Box.vertical(spacing: 28)
        body.append(header)
        let popularBox = Box.vertical(spacing: 8)
        let shelves = Box.vertical(spacing: 28)
        body.append(popularBox)
        body.append(shelves)

        let page = Page.make(artist.name, content: body.margins(bottom: 24), clamp: 1100, heading: false) { bar in
            bar.showsTitle(false)
            bar.end(radio)
            bar.end(favourite)
        }
        // The albums by kind, from the saved copy at once and then the server's.
        let kindShelves = Box.vertical(spacing: 28)
        shelves.append(kindShelves)
        func show(_ detail: ArtistDetail) {
            albumCount.text = detail.albumCount.map { $0 == 1 ? "1 album" : "\($0) albums" } ?? ""
            if let cover = detail.coverArt {
                picture.show(cover, fallback: artist.name)
                if page.coverArt == nil { page.coverArt = cover }
            }
            kindShelves.removeAll()
            for group in LibraryFacets.byReleaseKind(detail.album ?? []) {
                kindShelves.append(albumShelf(env, "\(group.kind.title)", artist: artist.name, group.albums))
            }
        }
        let alive = body.liveness
        Task { @MainActor in
            let client = app.client
            // As the album page: the saved copy while the server is asked, which it is
            // first, for the stars.
            let id = artist.id
            if let saved = await app.cache.load(ArtistDetail.self, for: CacheKey.artist(id)), alive.isAlive {
                show(saved)
            }
            let detail = await app.cached(CacheKey.artist(id)) { try await client.artistDetail(id: id) }
            guard alive.isAlive else { return }
            if let detail {
                show(detail)
                let starredOnServer = detail.starred != nil
                favourite.observe {
                    let starred = app.userState.isStarred(id: artist.id, serverValue: starredOnServer)
                    favourite.icon = Symbol.icon(starred ? "heart.fill" : "heart")
                    favourite.tooltip(starred ? "Remove Favourite" : "Favourite")
                }
                favourite.onClicked {
                    let starred = app.userState.isStarred(id: artist.id, serverValue: starredOnServer)
                    app.userState.toggleStar(id: artist.id, kind: .artist, currentlyStarred: starred)
                }
            }

            // The chart and the catalogue at once: the chart is one request, the catalogue
            // one per album and cached, so a second visit is instant and works offline.
            async let chart = try? client.topSongs(artist: artist.name, count: 50)
            async let catalogue: [Song]? = app.cached(CacheKey.artistSongs(id)) { try await client.artistSongs(id: id) }
            let all = await catalogue ?? []
            let popular = LibraryFacets.popular(chart: await chart ?? [], catalogue: all)
            guard alive.isAlive else { return }
            // Play and Shuffle are the whole discography, as on the phone.
            discography = all
            buttons.isSensitive = !all.isEmpty
            if !popular.isEmpty {
                showPopular(env, popular, artist: artist, in: popularBox, visible: popularStep)
            }

            async let about = try? client.artistInfo(id: id, similarCount: 15)
            async let found = try? client.search(query: artist.name, artistCount: 0, albumCount: 0, songCount: 200)
            let info = await about
            let sonic = await app.sonic.similarArtists(to: id) ?? []
            let own = Set((detail?.album ?? []).map(\.id))
            let appearsOn = LibraryFacets.appearsOn(await found?.songs ?? [], artistID: id, excluding: own)
            guard alive.isAlive else { return }
            if !appearsOn.isEmpty { shelves.append(albumShelf(env, "Appears On", artist: artist.name, appearsOn)) }
            if !sonic.isEmpty {
                shelves.append(Shelf.make("Sonically Similar", cards: sonic.map { Cards.artist(env, $0, side: 96) }))
            }
            let similar = (info?.similarArtists ?? []).filter { !$0.id.isEmpty }
            if !similar.isEmpty {
                shelves.append(Shelf.make("Similar Artists", cards: similar.map { Cards.artist(env, $0, side: 96) }))
            }
            if let biography = info?.plainBiography {
                // The phone's About: five lines, then More.
                let text = Label(biography, "detail-review").xalign(0).wrap().selectable()
                gtk_label_set_lines(text.widget.cast(), 5)
                gtk_label_set_ellipsize(text.widget.cast(), PANGO_ELLIPSIZE_END)
                let toggle = Button("More", "flat", "see-all")
                toggle.onClicked {
                    let expanded = gtk_label_get_lines(text.widget.cast()) == -1
                    gtk_label_set_lines(text.widget.cast(), expanded ? 5 : -1)
                    gtk_label_set_ellipsize(text.widget.cast(), expanded ? PANGO_ELLIPSIZE_END : PANGO_ELLIPSIZE_NONE)
                    toggle.label = expanded ? "More" : "Less"
                }
                shelves.append(Box.vertical(spacing: 8) {
                    Shelf.header("About")
                    text.margin(horizontal: 16, vertical: 0)
                    toggle.halign(GTK_ALIGN_START).margin(horizontal: 12, vertical: 0)
                })
            }
        }

        page.coverArt = artist.coverArt
        return page
    }

    /// Popular songs, five at a time; a row plays the whole list from there.
    private static func showPopular(_ env: Env, _ songs: [Song], artist: ArtistRef, in box: Box, visible: Int) {
        box.removeAll()
        box.append(Shelf.header("Popular"))
        let list = PlainList.list()
        for (index, song) in songs.prefix(visible).enumerated() {
            let row = SongRowView(env, style: .artwork, showsNavigation: false)
            row.bind(song)
            list.append(row.root) { env.play(songs, from: index, source: artist.name) }
        }
        box.append(list)
        if songs.count > popularStep {
            let hidden = songs.count - visible
            let title = hidden <= 0 ? "Show less" : "Show \(min(popularStep, hidden)) more"
            box.append(Button(title, icon: Symbol.icon(hidden <= 0 ? "chevron.up" : "chevron.down"), "flat", "see-all", "show-more") {
                showPopular(env, songs, artist: artist, in: box, visible: hidden <= 0 ? popularStep : visible + popularStep)
            }.halign(GTK_ALIGN_START).margin(horizontal: 12, vertical: 0))
        }
    }

    private static func albumShelf(_ env: Env, _ title: String, artist: String, _ albums: [Album]) -> Widget {
        var more: (@MainActor () -> Void)?
        if albums.count > 2 {
            more = { env.open(.albumCollection(title: "\(artist) · \(title)", albums: albums)) }
        }
        return Shelf.make(title, more: more, cards: albums.map { Cards.album(env, $0) })
    }
}
