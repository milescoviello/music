import CGtk
import Foundation

/// A song as a row: number or cover, title over artist, and on the right the marks that
/// matter — downloaded, favourite — and the length. The phone's `SongRow`.
@MainActor
final class SongRowView {
    enum Style {
        /// An album's tracks: the track number, no cover, no album line.
        case numbered
        /// Playlists, search, favourites: a cover instead of a number.
        case artwork
    }

    let root: Box
    private let env: Env
    private let style: Style
    private let number = Label("", "song-number").xalign(1).widthChars(3)
    private let playing = Icon("audio-volume-high-symbolic", size: 14).css("accent")
    private let artwork: ArtworkView?
    private let title = Label("", "title").ellipsize()
    private let subtitle = Label("", "caption", "dim").ellipsize()
    private let downloaded = Icon("folder-download-symbolic", size: 14).css("accent").tooltip("Downloaded")
    private let heart = Icon("music-heart-symbolic", size: 14).css("accent")
    private let trailing = Label("", "song-meta")
    private(set) var song: Song?
    /// The list's own items, before the song's: a playlist's Move and Remove. Here, not
    /// in a menu on a box around the row, which the row's own menu always won over, so
    /// a playlist's songs on the desktop could not be removed or moved at all.
    var ownItems: (@MainActor (Song) -> [Menu.Item])?

    init(_ env: Env, style: Style, showsNavigation: Bool = true) {
        var hoverChanged: (@MainActor (Bool) -> Void)?
        self.env = env
        self.style = style
        artwork = style == .artwork ? ArtworkView(env.app, size: .thumb, side: 40, shape: .thumb) : nil

        let leading: Widget
        if let artwork {
            leading = artwork.root
        } else {
            // Play in the number's place under the pointer, as a click there plays.
            let hoverPlay = Icon("media-playback-start-symbolic", size: 14).halign(GTK_ALIGN_END).opacity(0)
            let number = self.number
            let playing = self.playing
            leading = Overlay(number).add(playing.halign(GTK_ALIGN_END)).add(hoverPlay).size(width: 28)
            hoverChanged = { inside in
                let shows = inside && !playing.isVisible
                hoverPlay.opacity(shows ? 1 : 0)
                number.opacity(shows ? 0 : 1)
            }
        }
        let (title, subtitle, downloaded, heart, trailing) = (self.title, self.subtitle, self.downloaded, self.heart, self.trailing)
        root = Box.horizontal(spacing: 12) {
            leading
            Box.vertical(spacing: 2) {
                title
                subtitle
            }.hexpand().valign(GTK_ALIGN_CENTER)
            downloaded
            heart
            trailing
        }
        root.css("song-row").margin(horizontal: 0, vertical: 2)
        if let hover = hoverChanged { root.onHover(hover) }

        let reference = WeakReference(self)
        root.contextMenu {
            guard let row = reference.value, let song = row.song else { return nil }
            let menu = Menus.song(row.env, song, showsNavigation: showsNavigation)
            guard let own = row.ownItems?(song), !own.isEmpty else { return menu }
            return Menu([own] + menu.sections)
        }
        root.keep(self)
    }

    /// Fills the row. `trailing` replaces the duration when set — a last-played date in a
    /// list where that is the figure worth the space.
    /// `albumArtist`: an album's own artist, which its tracks then don't repeat.
    func bind(_ song: Song, number position: Int? = nil, trailing text: String? = nil, albumArtist: String? = nil) {
        self.song = song
        title.text = song.title
        switch style {
        case .numbered:
            subtitle.text = song.artist == albumArtist ? "" : song.artist ?? ""
            number.text = position.map(String.init) ?? song.track.map(String.init) ?? ""
        case .artwork:
            subtitle.text = [song.artist, song.album].compactMap { $0 }.joined(separator: " — ")
            artwork?.show(song.coverArt, fallback: song.album ?? song.title)
        }
        subtitle.isVisible = !subtitle.text.isEmpty
        trailing.text = text ?? song.duration.map(\.asDuration) ?? ""
        // The marks follow the player and the stores, so the song playing, a star or a
        // finished download shows in every row that has it without the list being rebuilt.
        // Watched from here, once the row has its song: watched from init, before it had
        // one, the observer read nothing, so nothing ever ran it again, and the red title
        // stayed on whatever was playing when the page was built.
        marks?.cancel()
        let reference = WeakReference(self)
        marks = Observer {
            guard let row = reference.value, let song = row.song else { return }
            row.refreshMarks(song)
        }
    }

    private var marks: Observer?

    private func refreshMarks(_ song: Song) {
        let app = env.app
        downloaded.isVisible = app.downloads.isDownloaded(song)
        heart.isVisible = app.userState.isStarred(song)
        let isCurrent = song.isSameRecording(as: app.player.currentSong)
        title.setCSS("current", isCurrent)
        title.setCSS("accent", isCurrent)
        if style == .numbered {
            playing.isVisible = isCurrent
            number.isVisible = !isCurrent
        }
    }
}

/// Songs as a boxed list where activating a row plays the whole list from there — the
/// phone's `PlayableSongRow`: tapping track 5 queues 5 to the end, not track 5 alone.
@MainActor
enum SongList {
    static func make(
        _ env: Env,
        _ songs: [Song],
        source: String,
        style: SongRowView.Style = .artwork,
        showsNavigation: Bool = true,
        trailing: ((Song) -> String?)? = nil
    ) -> ListBox {
        let list = ListBox()
        for (index, song) in songs.enumerated() {
            let row = SongRowView(env, style: style, showsNavigation: showsNavigation)
            row.bind(song, trailing: trailing?(song))
            list.append(row.root) {
                env.play(songs, from: index, source: source)
            }
        }
        return list
    }

    /// The same as a virtualised list, for thousands of songs: all tracks, a big genre.
    static func long(_ env: Env, source: String, style: SongRowView.Style = .artwork) -> ItemList<Song, SongRowView> {
        var list: ItemList<Song, SongRowView>?
        list = ItemList(.list, setup: {
            let row = SongRowView(env, style: style)
            return (row.root, row)
        }, bind: { row, song, _ in
            row.bind(song)
        }, activate: { _, index in
            guard let songs = list?.items else { return }
            env.play(songs, from: index, source: source)
        })
        return list!
    }
}

/// An album as a card: cover, name, artist.
@MainActor
final class AlbumCardView {
    let root: Box
    private let artwork: ArtworkView
    private let title = Label("", "card-title").ellipsize()
    private let subtitle = Label("", "card-subtitle").ellipsize()
    /// Set by `bind(_ album:)`, for a menu that follows whichever album the card shows.
    private(set) var album: Album?

    /// Five to a row of a wide window.
    static let side: Int32 = 196

    init(_ env: Env, side: Int32 = AlbumCardView.side) {
        let artwork = ArtworkView(env.app, size: .card, side: side, shape: .card)
        self.artwork = artwork
        let (title, subtitle) = (self.title, self.subtitle)
        root = Box.vertical(spacing: 6) {
            artwork.root
            title
            subtitle
        }
        root.size(width: side).halign(GTK_ALIGN_CENTER)
        title.maxWidthChars(1).hexpand()
        subtitle.maxWidthChars(1)
        root.keep(self)
    }

    func bind(title text: String, subtitle detail: String?, cover: String?, playlistID: String? = nil) {
        title.text = text
        subtitle.text = detail ?? ""
        subtitle.isVisible = detail?.isEmpty == false
        artwork.show(cover, playlistID: playlistID, fallback: text)
    }

    func bind(_ album: Album) {
        self.album = album
        bind(title: album.name, subtitle: album.artist, cover: album.coverArt)
    }
}

@MainActor
enum Cards {
    /// A clickable album card with its menu.
    /// `single`: the album's one song, when it has only one. Then the card plays it, and its
    /// menu is the song's, rather than opening an album page with one track on it.
    static func album(_ env: Env, _ album: Album, single: Song? = nil, side: Int32 = AlbumCardView.side) -> Widget {
        let card = AlbumCardView(env, side: side)
        card.bind(album)
        if let single {
            return Button(child: card.root, "card-button", "flat") {
                env.play([single], source: "Sonically Similar")
            }.contextMenu { Menus.song(env, single) }
        }
        return Button(child: card.root, "card-button", "flat") {
            env.open(.album(AlbumRef(album)))
        }.contextMenu { Menus.album(env, album) }
    }

    static func playlist(_ env: Env, _ playlist: Playlist, side: Int32 = AlbumCardView.side) -> Widget {
        let card = AlbumCardView(env, side: side)
        card.bind(
            title: playlist.name,
            subtitle: playlist.songCount.map { "\($0) songs" },
            cover: playlist.coverArt,
            playlistID: playlist.id
        )
        return Button(child: card.root, "card-button", "flat") {
            env.open(.playlist(PlaylistRef(playlist)))
        }
    }

    static func artist(_ env: Env, _ artist: Artist, side: Int32 = 140) -> Widget {
        let artwork = ArtworkView(env.app, size: .card, side: side, shape: .round)
        artwork.show(artist.coverArt, fallback: artist.name)
        let box = Box.vertical(spacing: 6) {
            artwork.root
            Label(artist.name, "card-title").ellipsize().xalign(0.5).maxWidthChars(1)
        }.size(width: side)
        return Button(child: box, "card-button", "flat") {
            env.open(.artist(ArtistRef(artist)))
        }.contextMenu { Menus.artist(env, artist) }
    }

    /// A grid of album cards for thousands of albums, built only as it scrolls. Each card
    /// has the album menu, as the phone's grids do; a card is reused for other albums as
    /// it scrolls, so the menu asks the card which one it holds now.
    static func albumGrid(_ env: Env) -> ItemList<Album, AlbumCardView> {
        ItemList(.grid(minColumns: 2, maxColumns: 12), setup: {
            let card = AlbumCardView(env)
            let reference = WeakReference(card)
            card.root.contextMenu {
                guard let album = reference.value?.album else { return nil }
                return Menus.album(env, album)
            }
            return (card.root, card)
        }, bind: { card, album, _ in
            card.bind(album)
        }, activate: { album, _ in
            env.open(.album(AlbumRef(album)))
        })
    }
}

/// A titled row of cards that scrolls sideways: Home's shelves, an artist's albums.
@MainActor
enum Shelf {
    static func make(_ title: String, subtitle: String? = nil, more: (@MainActor () -> Void)? = nil, cards: [Widget]) -> Widget {
        let header = Box.horizontal(spacing: 8) {
            Box.vertical(spacing: 0) {
                Label(title, "shelf-title")
                if let subtitle { Label(subtitle, "caption", "dim") }
            }.hexpand()
            if let more { Button("See All", "flat", "see-all", action: more) }
        }
        let row = Box.horizontal(spacing: 4)
        for card in cards { row.append(card) }
        let scroller = ScrolledWindow(row, horizontal: GTK_POLICY_AUTOMATIC, vertical: GTK_POLICY_NEVER)
            .propagatesNaturalHeight()
        passesWheelToPage(scroller)
        return Box.vertical(spacing: 8) {
            header
            scroller
        }
    }

    /// A mouse wheel over a shelf scrolls the page, not the shelf. GTK turns an up-and-down
    /// wheel into sideways scrolling for a row that only scrolls sideways, so scrolling down
    /// Home stopped on every shelf the pointer crossed and sent it sideways instead.
    /// Sideways, a touchpad's two-finger swipe or a tilting wheel, still moves the shelf.
    static func passesWheelToPage(_ shelf: ScrolledWindow) {
        let controller = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES)!
        gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE)
        Signal.connect(controller, "scroll", scroll: { dx, dy in
            guard dx == 0, dy != 0,
                  let parent = gtk_widget_get_parent(shelf.widget),
                  let page = gtk_widget_get_ancestor(parent, gtk_scrolled_window_get_type())
            else { return false }
            let adjustment = gtk_scrolled_window_get_vadjustment(page.cast())!
            let pageSize = gtk_adjustment_get_page_size(adjustment)
            // A wheel's notch is GTK's own step; a touchpad's delta is already in pixels.
            let unit = gtk_event_controller_scroll_get_unit(controller.cast())
            let step = unit == GDK_SCROLL_UNIT_WHEEL ? pow(pageSize, 2.0 / 3.0) : 1
            let upper = gtk_adjustment_get_upper(adjustment) - pageSize
            let value = min(max(gtk_adjustment_get_value(adjustment) + dy * step, 0), max(upper, 0))
            gtk_adjustment_set_value(adjustment, value)
            return true
        })
        gtk_widget_add_controller(shelf.widget, controller)
    }
}
