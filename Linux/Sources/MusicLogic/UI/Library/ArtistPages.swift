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

/// An artist: Play and Shuffle over the most popular songs, then the discography split
/// Plexamp's way — Albums, Singles & EPs, Live, Compilations — what they appear on, who
/// sounds like them, and what the server knows about them.
/// An artist's picture across the top of the page, cropped to fill, the name over its
/// lower edge. No picture: the name over the window's own colours.
@MainActor
final class ArtistHero {
    let root: Overlay
    private let picture = Picture().fit(GTK_CONTENT_FIT_COVER)
    private let app: AppState
    private var shown: String?

    init(_ app: AppState, name: String) {
        self.app = app
        gtk_picture_set_can_shrink(picture.widget.cast(), 1)
        let scrim = Box.vertical {}.css("hero-scrim").hexpand().vexpand()
        let title = Label(name, "hero-name").xalign(0).ellipsize().halign(GTK_ALIGN_FILL).valign(GTK_ALIGN_END)
        title.margins(top: 0, bottom: 18, start: 24, end: 24)
        root = Overlay(picture)
        root.add(scrim).add(title)
        root.css("artist-hero").clipped().size(width: -1, height: 280).hexpand()
        root.keep(self)
    }

    func show(_ cover: String?) {
        guard let cover, cover != shown else { return }
        shown = cover
        let alive = root.liveness
        Task { @MainActor in
            guard let texture = await app.artwork.image(for: cover, size: .full), alive.isAlive else { return }
            self.picture.set(texture)
        }
    }
}

@MainActor
enum ArtistPage {
    private static let popularStep = 5

    static func make(_ env: Env, artist: ArtistRef) -> NavigationPage {
        let app = env.app
        let favourite = Button(icon: "music-heart-symbolic", "flat")
        let radio = Button(icon: "network-wireless-symbolic", "flat") {
            Task {
                let mix = await app.radio.artistMix(artist, scope: app.scope.scope)
                app.startRadio(named: "\(artist.name) Radio", songs: mix, station: .artistMix(ids: [artist.id], names: [artist.name]))
            }
        }
        radio.tooltip("Start Artist Radio")

        let body = Box.vertical(spacing: 28)
        let albumCount = Label("", "hero-meta").xalign(0)
        let play = Button("Play", icon: "media-playback-start-symbolic", "suggested-action", "pill")
        let shuffle = Button("Shuffle", icon: "media-playlist-shuffle-symbolic", "pill", "glass-pill")
        let radioPill = Button("Radio", icon: "network-wireless-symbolic", "pill", "glass-pill") { gtk_widget_activate(radio.widget) }
        favourite.css("circular", "glass-pill")
        play.isSensitive = false
        shuffle.isSensitive = false
        let hero = ArtistHero(app, name: artist.name)
        hero.show(artist.coverArt)
        body.append(Box.vertical(spacing: 16) {
            hero.root
            Box.horizontal(spacing: 10) {
                play
                shuffle
                radioPill
                favourite.valign(GTK_ALIGN_CENTER)
                albumCount.hexpand().margins(top: 0, bottom: 0, start: 8, end: 0)
            }
        })
        body.append(HermesNoteView.make(env, subject: .artist(id: artist.id, name: artist.name), compact: true))

        let popularBox = Box.vertical(spacing: 8)
        let shelves = Box.vertical(spacing: 28)
        body.append(popularBox)
        body.append(shelves)

        let page = Page.make(artist.name, content: body.margin(horizontal: 12, vertical: 20), heading: false)
        // The albums by kind, from the saved copy at once and then the server's.
        let kindShelves = Box.vertical(spacing: 28)
        shelves.append(kindShelves)
        func show(_ detail: ArtistDetail) {
            albumCount.text = detail.albumCount.map { $0 == 1 ? "1 album" : "\($0) albums" } ?? ""
            if let cover = detail.coverArt {
                hero.show(cover)
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
            // first, for the stars; not saved at all before, so every artist waited on it.
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
                    favourite.setCSS("accent", starred)
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
            let popular = LibraryFacets.popular(chart: await chart ?? [], catalogue: await catalogue ?? [])
            guard alive.isAlive else { return }
            if !popular.isEmpty {
                play.isSensitive = true
                shuffle.isSensitive = true
                play.onClicked { env.play(popular, source: artist.name) }
                shuffle.onClicked { env.play(popular, source: artist.name, shuffled: true) }
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
                shelves.append(PreferencesGroup("About") { Label(biography, "dim").wrap().selectable().margin(12) })
            }
        }

        page.coverArt = artist.coverArt
        return page
    }

    /// Popular songs, five at a time; a row plays the whole list from there.
    private static func showPopular(_ env: Env, _ songs: [Song], artist: ArtistRef, in box: Box, visible: Int) {
        box.removeAll()
        box.append(Label("Top Songs", "shelf-title").xalign(0))
        let list = ListBox(boxed: false)
        list.css("track-list")
        for (index, song) in songs.prefix(visible).enumerated() {
            let row = SongRowView(env, style: .artwork, showsNavigation: false)
            row.bind(song)
            list.append(row.root) { env.play(songs, from: index, source: artist.name) }
        }
        box.append(list)
        if songs.count > popularStep {
            let hidden = songs.count - visible
            let title = hidden <= 0 ? "Show Less" : "Show \(min(popularStep, hidden)) More"
            box.append(Button(title, "flat") {
                showPopular(env, songs, artist: artist, in: box, visible: hidden <= 0 ? popularStep : visible + popularStep)
            }.halign(GTK_ALIGN_START))
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
