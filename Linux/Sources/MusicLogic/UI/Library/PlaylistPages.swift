import CGtk
import Foundation

/// Every playlist, with the menu the phone gives each — play, queue, download, rename,
/// delete — and a + for a new one, empty or from Hermes.
@MainActor
enum PlaylistList {
    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let store = app.playlistStore
        let list = ListBox()
        let footer = Label("Playlists are shown from every library.", "caption", "dim")
        let body = Box.vertical(spacing: 12) {
            list
            footer
        }.margin(horizontal: 12, vertical: 24)

        list.observe {
            let playlists = store.playlists
            let loading = store.isLoading
            _ = app.playlistArtwork.generation
            list.removeAll()
            for playlist in playlists {
                list.append(row(env, playlist)) { env.open(.playlist(PlaylistRef(playlist))) }
            }
            if playlists.isEmpty {
                list.placeholder(loading
                    ? Spinner().size(24).margin(24)
                    : StatusPage(icon: "view-list-symbolic", title: "No Playlists", description: "Click + to make one, or add songs from any list.").compact())
            }
            footer.isVisible = !playlists.isEmpty
        }
        Task { await store.loadIfNeeded() }

        return Page.make("Playlists", content: body) { bar in
            bar.end(MenuButton(icon: "list-add-symbolic", "flat") {
                Menu([[
                    .action("New Playlist…") { Menus.newPlaylist(env, [], suggested: "") },
                    .action("Ask Hermes for One…") { env.open(.vibePlaylist) },
                ]])
            })
            bar.end(Button(icon: "view-refresh-symbolic", "flat") { Task { await store.load() } }.tooltip("Refresh"))
        }
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
        func withSongs(_ action: @escaping @MainActor ([Song]) -> Void) {
            Task {
                guard let detail = try? await app.client.playlistDetail(id: playlist.id), !detail.songs.isEmpty else { return }
                action(detail.songs)
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
        }

        func load() {
            loader.run({ () -> PlaylistDetail? in
                let id = playlist.id
                let client = app.client
                return await app.cached(CacheKey.playlist(id)) { try await client.playlistDetail(id: id) }
            }) { detail in
                songs = detail.songs
                return content(env, playlist: playlist, detail: detail, reload: load)
            }
        }
        load()
        return page
    }

    private static func content(_ env: Env, playlist: PlaylistRef, detail: PlaylistDetail, reload: @escaping @MainActor () -> Void) -> Widget {
        let app = env.app
        let songs = detail.songs
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
                    Button("Play", icon: "media-playback-start-symbolic", "suggested-action", "pill") { env.play(songs, source: playlist.name) }
                    Button("Shuffle", icon: "media-playlist-shuffle-symbolic", "pill") { env.play(songs, source: playlist.name, shuffled: true) }
                }.margins(top: 12)
            }.valign(GTK_ALIGN_END).hexpand()
        }
        let body = Box.vertical(spacing: 18) { header }

        if songs.count > longList {
            let list = SongList.long(env, source: playlist.name)
            list.set(songs)
            let scroller = ScrolledWindow(list.view).size(height: 600).vexpand()
            body.append(scroller)
        } else {
            let list = ListBox()
            for (index, song) in songs.enumerated() {
                let row = SongRowView(env, style: .artwork)
                row.bind(song)
                // A playlist's own actions go first in its rows' menus.
                let wrapper = Box.horizontal { row.root.hexpand() }
                wrapper.contextMenu {
                    var sections = Menus.song(env, song).sections
                    var own: [Menu.Item] = [.action("Remove from Playlist", destructive: true) {
                        Task { if await app.playlistStore.removeIndex(index, from: playlist.id) { reload() } }
                    }]
                    if index > 0 { own.insert(.action("Move Up") { move(app, playlist, from: index, to: index - 1, reload) }, at: 0) }
                    if index + 1 < songs.count { own.insert(.action("Move Down") { move(app, playlist, from: index, to: index + 2, reload) }, at: own.count - 1) }
                    sections.insert(own, at: 0)
                    return Menu(sections)
                }
                list.append(wrapper) { env.play(songs, from: index, source: playlist.name) }
            }
            if songs.isEmpty { list.placeholder(Label("This playlist is empty.", "dim").margin(24)) }
            body.append(list)
        }
        return body.margin(horizontal: 12, vertical: 24)
    }

    /// Navidrome's own API moves a track; Subsonic's has no move at all. Both ends are
    /// 1-based, and the target is where it goes before.
    private static func move(_ app: AppState, _ playlist: PlaylistRef, from: Int, to: Int, _ reload: @escaping @MainActor () -> Void) {
        Task {
            do {
                try await app.native.movePlaylistTrack(playlistID: playlist.id, from: from + 1, insertBefore: to + 1)
            } catch {
                await Diagnostics.shared.record("playlist", "reorder failed: \(error)")
            }
            reload()
        }
    }
}
