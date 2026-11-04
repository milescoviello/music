import CGtk
import Foundation

/// Every playlist, as the phone arranges them: the pinned ones first in his order, then
/// the rest by the chosen sort or his own order, either dragged into place. Each has the
/// phone's menu (play, queue, download, pin, rename, delete), and + makes a new one,
/// empty or from Hermes.
@MainActor
enum PlaylistList {
    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let store = app.playlistStore
        let arrangement = app.playlistArrangement
        let pinnedHeading = Label("Pinned", "heading")
        let pinnedList = ListBox()
        let restHeading = Label("Playlists", "heading")
        let list = ListBox()
        let footer = Label("Playlists are shown from every library. Drag one to move it.", "caption", "dim")
        let body = Box.vertical(spacing: 12) {
            pinnedHeading
            pinnedList
            restHeading
            list
            footer
        }.margin(horizontal: 12, vertical: 24)

        list.observe {
            let playlists = store.playlists
            let loading = store.isLoading
            _ = app.playlistArtwork.generation
            let split = arrangement.arranged(playlists)
            pinnedList.removeAll()
            for (index, playlist) in split.pinned.enumerated() {
                let line = row(env, playlist).draggable("pinned:\(index)").onDrop { text in
                    guard let from = Self.dropped(text, prefix: "pinned:"), from != index else { return false }
                    arrangement.movePinned(from: IndexSet(integer: from), to: from < index ? index + 1 : index, shown: split.pinned)
                    return true
                }
                pinnedList.append(line) { env.open(.playlist(PlaylistRef(playlist))) }
            }
            list.removeAll()
            for (index, playlist) in split.rest.enumerated() {
                // Moving one by hand makes the order his own: My Order in the sort menu.
                let line = row(env, playlist).draggable("rest:\(index)").onDrop { text in
                    guard let from = Self.dropped(text, prefix: "rest:"), from != index else { return false }
                    arrangement.moveRest(from: IndexSet(integer: from), to: from < index ? index + 1 : index, shown: split.rest)
                    return true
                }
                list.append(line) { env.open(.playlist(PlaylistRef(playlist))) }
            }
            pinnedHeading.isVisible = !split.pinned.isEmpty
            pinnedList.isVisible = !split.pinned.isEmpty
            restHeading.isVisible = !split.pinned.isEmpty && !split.rest.isEmpty
            if playlists.isEmpty {
                list.placeholder(loading
                    ? Spinner().size(24).margin(24)
                    : StatusPage(icon: "view-list-symbolic", title: "No Playlists", description: "Click + to make one, or add songs from any list.").compact())
            }
            footer.isVisible = !playlists.isEmpty
        }
        Task { await store.refreshIfStale() }

        return Page.make("Playlists", content: body) { bar in
            bar.end(MenuButton(icon: "view-sort-descending-symbolic", "flat") {
                Menu([[
                    .choice(
                        "Sort",
                        options: PlaylistArrangement.Sort.allCases.map { ($0.rawValue, $0.title) },
                        selected: arrangement.sort.rawValue
                    ) { value in
                        if let sort = PlaylistArrangement.Sort(rawValue: value) { arrangement.sort = sort }
                    },
                ]])
            }.tooltip("Sort Playlists"))
            bar.end(MenuButton(icon: "list-add-symbolic", "flat") {
                Menu([[
                    .action("New Playlist…") { Menus.newPlaylist(env, [], suggested: "") },
                    .action("Ask Hermes for One…") { env.open(.vibePlaylist) },
                ]])
            })
            bar.end(Button(icon: "view-refresh-symbolic", "flat") { Task { await store.load() } }.tooltip("Refresh"))
        }
    }

    /// The place a dragged row carried, if it came from the same list.
    private static func dropped(_ text: String, prefix: String) -> Int? {
        guard text.hasPrefix(prefix) else { return nil }
        return Int(text.dropFirst(prefix.count))
    }

    private static func row(_ env: Env, _ playlist: Playlist) -> Widget {
        let artwork = ArtworkView(env.app, size: .thumb, side: 56, shape: .thumb)
        artwork.show(playlist.coverArt, playlistID: playlist.id, fallback: playlist.name)
        var parts: [String] = []
        if let count = playlist.songCount { parts.append("\(count) songs") }
        if let duration = playlist.duration { parts.append(duration.asLongDuration) }
        let row = Box.horizontal(spacing: 12) {
            artwork.root
            Box.vertical(spacing: 2) {
                Label(playlist.name).ellipsize()
                Label(parts.joined(separator: " · "), "caption", "dim")
            }.valign(GTK_ALIGN_CENTER).hexpand()
        }.margin(horizontal: 12, vertical: 6)
        return row.contextMenu { menu(env, playlist) }
    }

    static func menu(_ env: Env, _ playlist: Playlist) -> Menu {
        let app = env.app
        // From the server, or the saved copy's songs on this computer when it doesn't answer:
        // straight from the server, Play and Shuffle here did nothing offline.
        func withSongs(_ action: @escaping @MainActor ([Song]) -> Void) {
            Task {
                let songs = await app.playlistSongsToPlay(playlist.id)
                guard !songs.isEmpty else { return }
                action(songs)
            }
        }
        let player = app.player
        var queue: [Menu.Item] = [.action("Play Next") { withSongs { player.playNext($0) } }]
        if player.canAddToUpNext { queue.append(.action("Add to Up Next") { withSongs { player.addToUpNext($0) } }) }
        queue.append(.action("Add to Queue") { withSongs { player.append($0) } })
        let downloads = app.downloads
        return Menu([
            [
                .action("Play") { withSongs { env.play($0, source: playlist.name) } },
                .action("Shuffle") { withSongs { env.play($0, source: playlist.name, shuffled: true) } },
            ],
            queue,
            [
                downloads.hasDownload(group: playlist.id)
                    ? .action("Remove Download", destructive: true) {
                        app.playlistSync.stopSyncing(groupID: playlist.id)
                        downloads.removeGroup(playlist.id)
                    }
                    : .action("Download") { withSongs { downloads.download($0, groupID: playlist.id, groupName: playlist.name) } },
            ],
            [
                .action(app.playlistArrangement.isPinned(playlist) ? "Unpin" : "Pin to Top") {
                    app.playlistArrangement.togglePin(playlist)
                },
            ],
            [
                .action("Rename…") { edit(env, playlist) },
                .action("Delete…", destructive: true) { delete(env, playlist) },
            ],
        ])
    }

    static func edit(_ env: Env, _ playlist: Playlist) {
        let name = EntryRow("Name", text: playlist.name)
        let comment = EntryRow("Description", text: playlist.comment ?? "")
        let group = PreferencesGroup {
            name
            comment
        }
        Dialogs.alert(
            "Edit Playlist",
            responses: [("cancel", "Cancel", ADW_RESPONSE_DEFAULT), ("save", "Save", ADW_RESPONSE_SUGGESTED)],
            defaultResponse: "save",
            extra: group
        ) { response in
            let newName = name.text.trimmingCharacters(in: .whitespaces)
            guard response == "save", !newName.isEmpty else { return }
            Task { await env.app.playlistStore.rename(playlist, to: newName, comment: comment.text.isEmpty ? nil : comment.text) }
        }
    }

    static func delete(_ env: Env, _ playlist: Playlist) {
        Dialogs.alert(
            "Delete “\(playlist.name)”?",
            body: "The songs stay in your library.",
            responses: [("cancel", "Cancel", ADW_RESPONSE_DEFAULT), ("delete", "Delete Playlist", ADW_RESPONSE_DESTRUCTIVE)]
        ) { response in
            guard response == "delete" else { return }
            Task { await env.app.playlistStore.delete(playlist) }
        }
    }
}

/// A playlist, in the server's order, never re-sorted. Its rows can be removed or moved;
/// a cover can be chosen for it, kept on this computer since the API has no way to send
/// one to the server.
@MainActor
enum PlaylistPage {
    /// Past this many rows the list is built only as it scrolls: a smart playlist of the
    /// whole library is tens of thousands of songs.
    private static let longList = 400

    static func make(_ env: Env, playlist: PlaylistRef) -> NavigationPage {
        let app = env.app
        let loader = Loader()
        var songs: [Song] = []
        let selection = TrackSelection()
        let download = CollectionDownloadButton(env, groupID: playlist.id, groupName: playlist.name) { songs }
        let menu = MenuButton(icon: "view-more-symbolic", "flat") {
            var sections: [[Menu.Item]] = [Menus.queueItems(env, songs)]
            sections.append([.action("Start Radio") {
                guard let seed = songs.randomElement() else { return }
                Task {
                    let mix = await app.radio.mix(seed: seed, scope: app.scope.scope)
                    app.startRadio(named: "\(playlist.name) Radio", songs: mix, station: .radio(seedIDs: songs.map(\.id), title: "\(playlist.name) Radio"))
                }
            }])
            var cover: [Menu.Item] = [.action("Choose Cover…") {
                FilePicker.image(title: "Choose a Cover") { app.playlistArtwork.setImage(data: $0, for: playlist.id) }
            }]
            if app.playlistArtwork.hasCustomImage(for: playlist.id) {
                cover.append(.action("Remove Cover", destructive: true) { app.playlistArtwork.removeImage(for: playlist.id) })
            }
            sections.append(cover)
            if let match = app.playlistStore.playlists.first(where: { $0.id == playlist.id }) {
                sections.append([.action("Rename…") { PlaylistList.edit(env, match) }])
            }
            return Menu(sections)
        }
        let page = Page.make(playlist.name, content: loader.bin) { bar in
            bar.end(menu)
            bar.end(download.root)
            bar.end(selection.button())
        }

        var current = playlist
        func load() {
            loader.run({ () -> (detail: PlaylistDetail, isSaved: Bool)? in
                let found = await app.playlist(playlist.id)
                return found.detail.map { ($0, found.isSaved) }
            }) { found in
                songs = found.detail.songs
                download.songsChanged()
                selection.end()
                return content(env, playlist: current, detail: found.detail, isSaved: found.isSaved, selection: selection, reload: load)
            }
        }
        load()

        // The playlist as the store has it: renamed from here, or a song added from the
        // player laid over this page, the title and the songs stayed as they were.
        func stamp(_ entry: Playlist?) -> String? {
            entry.map { "\($0.name)\u{1F}\($0.songCount ?? 0)\u{1F}\($0.changed ?? "")" }
        }
        var seen = stamp(app.playlistStore.playlists.first { $0.id == playlist.id })
        page.observe {
            let entry = app.playlistStore.playlists.first { $0.id == playlist.id }
            let now = stamp(entry)
            guard now != seen, let entry else { return }
            seen = now
            current = PlaylistRef(id: playlist.id, name: entry.name, coverArt: playlist.coverArt)
            page.title = entry.name
            load()
        }
        return page
    }

    private static func content(_ env: Env, playlist: PlaylistRef, detail: PlaylistDetail, isSaved: Bool, selection: TrackSelection, reload: @escaping @MainActor () -> Void) -> Widget {
        let app = env.app
        let songs = detail.songs
        // Without the server, Play and Shuffle start the songs on this computer.
        let playable = isSaved ? app.playableHere(songs) : songs
        let artwork = ArtworkView(app, size: .full, side: 200, shape: .player)
        artwork.root.observe {
            _ = app.playlistArtwork.generation
            artwork.show(detail.coverArt ?? playlist.coverArt, playlistID: playlist.id, fallback: playlist.name)
        }
        var subtitle: [String] = []
        if let count = detail.songCount { subtitle.append("\(count) songs") }
        if let duration = detail.duration { subtitle.append(duration.asLongDuration) }

        let header = Box.horizontal(spacing: 24) {
            artwork.root
            Box.vertical(spacing: 6) {
                Label(playlist.name, "page-title").wrap()
                if let comment = detail.comment, !comment.isEmpty { Label(comment, "dim").wrap() }
                Label(subtitle.joined(separator: " · "), "caption", "dim")
                Box.horizontal(spacing: 8) {
                    Button("Play", icon: "media-playback-start-symbolic", "suggested-action", "pill") { env.play(playable, source: playlist.name) }
                    Button("Shuffle", icon: "media-playlist-shuffle-symbolic", "pill") { env.play(playable, source: playlist.name, shuffled: true) }
                }.margins(top: 12)
            }.valign(GTK_ALIGN_END).hexpand()
        }
        let body = Box.vertical(spacing: 18) { header }
        body.append(selection.bar(env, all: { songs }, source: playlist.name))

        if songs.count > longList {
            // Built as it scrolls, each row reused for others, so its menu asks which song
            // and place it holds now. These had no Remove or Move at all.
            var list: ItemList<Song, PlaylistCell>?
            list = ItemList(.list, setup: {
                let cell = PlaylistCell(env, selection: selection)
                let reference = WeakReference(cell)
                cell.row.ownItems = { song in
                    guard let index = reference.value?.index else { return [] }
                    return ownItems(app, playlist, songs, song: song, index: index, reload)
                }
                return (cell.root, cell)
            }, bind: { cell, song, index in
                cell.index = index
                cell.row.bind(song)
                cell.check.bind(song)
            }, activate: { song, index in
                selection.activate(song) { env.play(songs, from: index, source: playlist.name) }
            })
            list?.set(songs)
            if let list {
                body.append(ScrolledWindow(list.view).size(height: 600).vexpand())
            }
        } else {
            let list = ListBox()
            for (index, song) in songs.enumerated() {
                let row = SongRowView(env, style: .artwork)
                row.bind(song)
                // A playlist's own actions go first in its rows' menus.
                row.ownItems = { song in ownItems(app, playlist, songs, song: song, index: index, reload) }
                let wrapper = Box.horizontal { row.root.hexpand() }
                // Dragged onto another row, a song takes that row's place, as on the phone.
                wrapper.draggable("\(index)").onDrop { text in
                    guard let from = Int(text), from != index else { return false }
                    move(app, playlist, songs, from: from, to: from < index ? index + 1 : index, reload)
                    return true
                }
                list.append(selection.row(wrapper, song: song)) {
                    selection.activate(song) { env.play(songs, from: index, source: playlist.name) }
                }
            }
            if songs.isEmpty { list.placeholder(Label("This playlist is empty.", "dim").margin(24)) }
            body.append(list)
        }
        return body.margin(horizontal: 12, vertical: 24)
    }

    /// A playlist's own actions for the song at `index`, first in its rows' menus.
    private static func ownItems(_ app: AppState, _ playlist: PlaylistRef, _ songs: [Song], song: Song, index: Int, _ reload: @escaping @MainActor () -> Void) -> [Menu.Item] {
        var own: [Menu.Item] = []
        if index > 0 {
            own.append(.action("Move to Top") { move(app, playlist, songs, from: index, to: 0, reload) })
            own.append(.action("Move Up") { move(app, playlist, songs, from: index, to: index - 1, reload) })
        }
        if index + 1 < songs.count {
            own.append(.action("Move Down") { move(app, playlist, songs, from: index, to: index + 2, reload) })
            own.append(.action("Move to Bottom") { move(app, playlist, songs, from: index, to: songs.count, reload) })
        }
        own.append(.action("Remove from Playlist", destructive: true) {
            Task { if await app.playlistStore.remove(song, shownAt: index, from: playlist.id) { reload() } }
        })
        return own
    }

    /// Navidrome's own API moves a track; Subsonic's has no move at all. `to` is the row it
    /// goes before. The store goes by the songs, not these positions, which a move still
    /// on its way changes.
    private static func move(_ app: AppState, _ playlist: PlaylistRef, _ songs: [Song], from: Int, to: Int, _ reload: @escaping @MainActor () -> Void) {
        guard songs.indices.contains(from) else { return }
        let song = songs[from]
        let anchor = songs.indices.contains(to) ? songs[to] : nil
        Task {
            await app.playlistStore.move(song, shownAt: from, before: anchor, shownAt: to, in: playlist.id)
            reload()
        }
    }
}

/// A row of a long playlist: the song, and the place it is bound to now.
@MainActor
final class PlaylistCell {
    let root: Box
    let row: SongRowView
    let check: SelectionCheck
    var index = 0

    init(_ env: Env, selection: TrackSelection) {
        let row = SongRowView(env, style: .artwork)
        self.row = row
        let check = SelectionCheck(selection)
        self.check = check
        root = Box.horizontal(spacing: 4) {
            check.root
            row.root.hexpand()
        }
        root.keep(self)
    }
}
