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

    init(_ env: Env, style: Style, showsNavigation: Bool = true) {
        self.env = env
        self.style = style
        artwork = style == .artwork ? ArtworkView(env.app, size: .thumb, side: 40, shape: .thumb) : nil

        let leading: Widget
        if let artwork {
            leading = artwork.root
        } else {
            leading = Overlay(number).add(playing.halign(GTK_ALIGN_END)).size(width: 28)
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

        let reference = WeakReference(self)
        root.contextMenu {
            guard let row = reference.value, let song = row.song else { return nil }
            return Menus.song(row.env, song, showsNavigation: showsNavigation)
        }
        // The marks follow the stores, so starring a song or finishing its download shows
        // in every row that has it without the list being rebuilt.
        root.observe {
            guard let row = reference.value, let song = row.song else { return }
            row.refreshMarks(song)
        }
        root.keep(self)
    }

    /// Fills the row. `trailing` replaces the duration when set — a last-played date in a
    /// list where that is the figure worth the space.
    func bind(_ song: Song, number position: Int? = nil, trailing text: String? = nil) {
        self.song = song
        title.text = song.title
        switch style {
        case .numbered:
            subtitle.text = song.artist ?? ""
            number.text = position.map(String.init) ?? song.track.map(String.init) ?? ""
        case .artwork:
            subtitle.text = [song.artist, song.album].compactMap { $0 }.joined(separator: " — ")
            artwork?.show(song.coverArt, fallback: song.album ?? song.title)
        }
        subtitle.isVisible = !subtitle.text.isEmpty
        trailing.text = text ?? song.duration.map(\.asDuration) ?? ""
        refreshMarks(song)
    }

    private func refreshMarks(_ song: Song) {
        let app = env.app
        downloaded.isVisible = app.downloads.isDownloaded(song.id)
        heart.isVisible = app.userState.isStarred(song)
        let isCurrent = app.player.currentSong?.id == song.id
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

    static let side: Int32 = 160

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
        bind(title: album.name, subtitle: album.artist, cover: album.coverArt)
    }
}

@MainActor
enum Cards {
    /// A clickable album card with its menu.
    static func album(_ env: Env, _ album: Album, side: Int32 = AlbumCardView.side) -> Widget {
        let card = AlbumCardView(env, side: side)
        card.bind(album)
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
        }
    }

    /// A grid of album cards for thousands of albums, built only as it scrolls.
    static func albumGrid(_ env: Env) -> ItemList<Album, AlbumCardView> {
        ItemList(.grid(minColumns: 2, maxColumns: 12), setup: {
            let card = AlbumCardView(env)
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
            if let more { Button("See All", "flat", action: more) }
        }
        let row = Box.horizontal(spacing: 4)
        for card in cards { row.append(card) }
        let scroller = ScrolledWindow(row, horizontal: GTK_POLICY_AUTOMATIC, vertical: GTK_POLICY_NEVER)
            .propagatesNaturalHeight()
        return Box.vertical(spacing: 8) {
            header
            scroller
        }
    }
}
