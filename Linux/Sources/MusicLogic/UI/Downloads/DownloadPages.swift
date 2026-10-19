import CGtk
import Foundation

/// What is on this computer, the way Plexamp shows it: albums and playlists as folders,
/// with a ring while one is arriving, searchable, sorted, and Play All over the lot.
@MainActor
enum DownloadsPage {
    private static let sortKey = "downloads.sort"
    private static let ascendingKey = "downloads.sortAscending"

    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let store = app.downloadFolders
        let entry = SearchEntry(placeholder: "Albums, Playlists, Songs")
        let content = Box.vertical(spacing: 18)
        let body = Box.vertical(spacing: 18) {
            entry
            content
        }.margin(horizontal: 12, vertical: 18)

        func fill() {
            content.removeAll()
            let folders = store.folders
            let defaults = UserDefaults.standard
            let sort = DownloadFolders.Sort(rawValue: defaults.string(forKey: sortKey) ?? "") ?? .addedAt
            let ascending = defaults.object(forKey: ascendingKey) as? Bool ?? true
            let query = entry.text.trimmingCharacters(in: .whitespaces)

            guard !folders.isEmpty else {
                content.append(StatusPage(icon: "folder-download-symbolic", title: "No Downloads", description: "Download an album, playlist or song to keep it on this computer."))
                return
            }
            if !query.isEmpty {
                let results = folders.search(query)
                if results.albums.isEmpty, results.playlists.isEmpty, results.songs.isEmpty {
                    content.append(StatusPage(icon: "system-search-symbolic", title: "No Results", description: "Nothing downloaded matches “\(query)”."))
                    return
                }
                if !results.albums.isEmpty { content.append(section(env, "Albums", folders.sorted(results.albums, by: sort, ascending: ascending))) }
                if !results.playlists.isEmpty { content.append(section(env, "Playlists", folders.sorted(results.playlists, by: sort, ascending: ascending))) }
                if !results.songs.isEmpty {
                    content.append(Label("Songs", "heading"))
                    content.append(SongList.make(env, results.songs, source: "Downloads"))
                }
                return
            }

            var totals = [folders.totalBytes.asFileSize]
            if folders.totalDuration > 0 { totals.append(folders.totalDuration.asLongDuration) }
            let summary = Box.vertical(spacing: 2) {
                Label("\(folders.songs.count) \(folders.songs.count == 1 ? "track" : "tracks")", "heading")
                Label(totals.joined(separator: " – "), "caption", "dim")
            }
            if !app.reachability.isOnline { summary.append(Label("Offline — playing from this computer", "caption", "accent")) }
            content.append(summary)

            let albums = folders.sorted(folders.albums, by: sort, ascending: ascending)
            if !albums.isEmpty { content.append(section(env, "Albums", albums)) }
            let playlists = folders.sorted(folders.playlists, by: sort, ascending: ascending)
            if !playlists.isEmpty { content.append(section(env, "Playlists", playlists)) }
        }

        entry.onSearch { _ in fill() }
        content.observe {
            _ = store.folders
            _ = app.reachability.isOnline
            fill()
        }
        body.onMap { store.activate() }

        let menu = MenuButton(icon: "view-more-symbolic", "flat") {
            let folders = store.folders
            let defaults = UserDefaults.standard
            let sort = DownloadFolders.Sort(rawValue: defaults.string(forKey: sortKey) ?? "") ?? .addedAt
            let ascending = defaults.object(forKey: ascendingKey) as? Bool ?? true
            @MainActor func playAll(_ shuffled: Bool) {
                let songs = folders.playAll(sort: sort, ascending: ascending)
                guard !songs.isEmpty else { return }
                env.play(songs, source: "Downloads", shuffled: shuffled)
            }
            return Menu([
                [
                    .action("Play All", enabled: !folders.isEmpty) { playAll(false) },
                    .action("Shuffle All", enabled: !folders.isEmpty) { playAll(true) },
                ],
                [.choice("Sort By", options: DownloadFolders.Sort.allCases.map { option in
                    (option.rawValue, option == sort ? "\(option.title) \(ascending ? "↑" : "↓")" : option.title)
                }, selected: sort.rawValue) { raw in
                    if raw == sort.rawValue {
                        defaults.set(!ascending, forKey: ascendingKey)
                    } else {
                        defaults.set(raw, forKey: sortKey)
                    }
                    fill()
                }],
                [.action("Remove All…", destructive: true, enabled: !folders.isEmpty) {
                    Dialogs.alert(
                        "Remove all downloads?",
                        body: "The music stays on your server. Only the copies on this computer are deleted.",
                        responses: [("cancel", "Cancel", ADW_RESPONSE_DEFAULT), ("remove", "Remove \(folders.totalBytes.asFileSize)", ADW_RESPONSE_DESTRUCTIVE)]
                    ) { if $0 == "remove" { app.downloads.removeAll() } }
                }],
            ])
        }
        return Page.make("Downloads", content: body) { bar in bar.end(menu) }
    }

    private static func section(_ env: Env, _ title: String, _ folders: [DownloadFolders.Folder]) -> Widget {
        let list = ListBox()
        for folder in folders {
            list.append(DownloadFolderRow.make(env, folder)) { env.open(.downloadFolder(folder.id)) }
        }
        return Box.vertical(spacing: 8) {
            Label(title, "heading")
            list
        }
    }

    /// Removing a folder takes only what it alone brought; a playlist kept offline by
    /// Offline & Library would come straight back, and the dialog says so.
    static func confirmRemoval(_ env: Env, _ folder: DownloadFolders.Folder, removed: @escaping @MainActor () -> Void = {}) {
        let app = env.app
        let sync = app.playlistSync
        let kept = folder.kind == .playlist && sync.isEnabled
            && (folder.key == "favourites" ? sync.includesFavourites : sync.includedIDs.contains(folder.key))
        Dialogs.alert(
            "Remove “\(folder.name)” from this computer?",
            body: kept
                ? "It stays on your server. Offline & Library is set to keep it here, so it will download again unless you turn that off."
                : "It stays on your server.",
            responses: [("cancel", "Cancel", ADW_RESPONSE_DEFAULT), ("remove", "Remove Download", ADW_RESPONSE_DESTRUCTIVE)]
        ) { response in
            guard response == "remove" else { return }
            let folders = app.downloadFolders.folders
            let current = folders.folder(id: folder.id) ?? folder
            app.downloads.remove(folders.songIDsToRemove(for: current))
            removed()
        }
    }

    static func menu(_ env: Env, _ folder: DownloadFolders.Folder, removed: @escaping @MainActor () -> Void = {}) -> Menu {
        var sections: [[Menu.Item]] = []
        if !folder.songs.isEmpty {
            sections.append([
                .action("Play") { env.play(folder.songs, source: folder.name) },
                .action("Shuffle") { env.play(folder.songs, source: folder.name, shuffled: true) },
            ])
            sections.append(Menus.queueItems(env, folder.songs))
        }
        sections.append([.action(folder.isDownloading ? "Cancel and Remove" : "Remove Download", destructive: true) {
            confirmRemoval(env, folder, removed: removed)
        }])
        return Menu(sections)
    }
}

/// A downloaded album or playlist as a row: cover with a ring while it arrives, name,
/// artist or track count, and size or progress.
@MainActor
enum DownloadFolderRow {
    static func make(_ env: Env, _ folder: DownloadFolders.Folder) -> Widget {
        let artwork = ArtworkView(env.app, size: .thumb, side: 56, shape: .thumb)
        artwork.show(folder.coverArt, playlistID: folder.kind == .playlist ? folder.key : nil, fallback: folder.name)
        let cover = Overlay(artwork.root)
        if folder.isDownloading {
            let fraction = folder.fractionDone
            let remaining = folder.waiting.count
            cover.add(DrawingArea(width: 56, height: 56) { cairo, width, height in
                cairo.color(red: 0, green: 0, blue: 0, alpha: 0.5)
                cairo.roundedRectangle(0, 0, width, height, radius: 6)
                cairo.fill()
                let radius = min(width, height) / 2 - 10
                cairo.color(red: 1, green: 1, blue: 1, alpha: 0.25)
                cairo_arc(cairo.context, width / 2, height / 2, radius, 0, 2 * .pi)
                cairo.stroke(width: 4)
                cairo.color(Style.tint)
                cairo_arc(cairo.context, width / 2, height / 2, radius, -.pi / 2, -.pi / 2 + 2 * .pi * fraction)
                cairo.stroke(width: 4)
                cairo.color(red: 1, green: 1, blue: 1)
                let text = "\(remaining)"
                let textWidth = cairo.textWidth(text, size: 11, bold: true)
                cairo.text(text, x: (width - textWidth) / 2, y: height / 2 + 4, size: 11, bold: true)
            })
        }
        let detail: String
        if folder.isDownloading {
            detail = folder.songs.isEmpty ? "Waiting…" : "\(folder.songs.count) of \(folder.trackCount) · \(folder.byteCount.asFileSize)"
        } else {
            detail = "\(folder.byteCount.asFileSize) · \(folder.duration.asLongDuration)"
        }
        let row = Box.horizontal(spacing: 12) {
            cover
            Box.vertical(spacing: 2) {
                Label(folder.name).ellipsize()
                Label(folder.artist ?? folder.trackCountText, "caption", "dim").ellipsize()
                Label(detail, "caption", folder.isDownloading ? "accent" : "dimmer", "numeric").ellipsize()
            }.valign(GTK_ALIGN_CENTER).hexpand()
        }.margin(horizontal: 12, vertical: 6)
        return row.contextMenu { DownloadsPage.menu(env, folder) }
    }
}

extension DownloadFolders.Folder {
    var trackCountText: String {
        "\(trackCount) \(trackCount == 1 ? "track" : "tracks")"
    }
}

/// A downloaded album or playlist: playable with no server at all, its waiting tracks
/// listed beneath, and the way to its library page when the server is there.
@MainActor
enum DownloadFolderPage {
    static func make(_ env: Env, id: String) -> NavigationPage {
        let app = env.app
        let store = app.downloadFolders
        let slot = Bin()
        let title = store.folders.folder(id: id)?.name ?? "Download"
        slot.observe {
            guard let folder = store.folders.folder(id: id) else {
                slot.child = StatusPage(icon: "folder-download-symbolic", title: "Not on This Computer", description: "This is no longer in your downloads.")
                return
            }
            slot.child = content(env, folder)
        }
        slot.onMap { store.activate() }
        // A playlist's order can change on the server; the downloaded copy follows it.
        Task { @MainActor in
            guard app.reachability.isOnline, let folder = store.folders.folder(id: id), folder.kind == .playlist,
                  folder.key != "favourites", !folder.key.hasPrefix("mix-"),
                  let detail = try? await app.client.playlistDetail(id: folder.key)
            else { return }
            await app.cache.store(detail, for: CacheKey.playlist(folder.key))
            store.update(order: detail.songs.map(\.id), forPlaylist: folder.key)
        }
        let menu = MenuButton(icon: "view-more-symbolic", "flat") {
            guard let folder = store.folders.folder(id: id) else { return Menu([]) }
            var menu = DownloadsPage.menu(env, folder) { env.navigation.pop() }
            if app.reachability.isOnline, let destination = libraryDestination(folder) {
                menu.sections.insert([.action(folder.kind == .album ? "Go to Album" : "Go to Playlist") { env.open(destination) }], at: menu.sections.count - 1)
            }
            return menu
        }
        return Page.make(title, content: slot) { bar in bar.end(menu) }
    }

    private static func content(_ env: Env, _ folder: DownloadFolders.Folder) -> Widget {
        let artwork = ArtworkView(env.app, size: .full, side: 200, shape: .player)
        artwork.show(folder.coverArt, playlistID: folder.kind == .playlist ? folder.key : nil, fallback: folder.name)
        var summary = [folder.trackCountText]
        if folder.duration > 0 { summary.append(folder.duration.asLongDuration) }
        summary.append(folder.byteCount.asFileSize)
        let play = Button("Play", icon: "media-playback-start-symbolic", "suggested-action", "pill") { env.play(folder.songs, source: folder.name) }
        let shuffle = Button("Shuffle", icon: "media-playlist-shuffle-symbolic", "pill") { env.play(folder.songs, source: folder.name, shuffled: true) }
        play.isSensitive = !folder.songs.isEmpty
        shuffle.isSensitive = !folder.songs.isEmpty
        let header = Box.horizontal(spacing: 24) {
            artwork.root
            Box.vertical(spacing: 6) {
                Label(folder.name, "page-title").wrap()
                if let artist = folder.artist { Label(artist, "page-subtitle") }
                Label(summary.joined(separator: " · "), "caption", "dim")
                Box.horizontal(spacing: 8) {
                    play
                    shuffle
                }.margins(top: 12)
            }.valign(GTK_ALIGN_END).hexpand()
        }
        let body = Box.vertical(spacing: 18) { header }
        switch folder.kind {
        case .album:
            let list = ListBox()
            for (index, song) in folder.songs.enumerated() {
                let row = SongRowView(env, style: .numbered, showsNavigation: false)
                row.bind(song, number: song.track ?? index + 1)
                list.append(row.root) { env.play(folder.songs, from: index, source: folder.name) }
            }
            body.append(list)
        case .playlist:
            body.append(SongList.make(env, folder.songs, source: folder.name))
        }
        if !folder.waiting.isEmpty {
            body.append(Label("Still to Download · \(folder.waiting.count)", "heading"))
            let list = ListBox()
            for song in folder.waiting {
                list.append(Box.horizontal(spacing: 12) {
                    Icon("folder-download-symbolic").opacity(0.4)
                    Box.vertical(spacing: 2) {
                        Label(song.title, "dim").ellipsize()
                        if let artist = song.artist { Label(artist, "caption", "dimmer").ellipsize() }
                    }.hexpand()
                }.margin(horizontal: 12, vertical: 6))
            }
            body.append(list)
        }
        return body.margin(horizontal: 12, vertical: 24)
    }

    private static func libraryDestination(_ folder: DownloadFolders.Folder) -> Destination? {
        switch folder.kind {
        case .album:
            guard (folder.songs.first ?? folder.waiting.first)?.albumId != nil else { return nil }
            return .album(AlbumRef(id: folder.key, name: folder.name, artist: folder.artist, coverArt: folder.coverArt))
        case .playlist:
            if folder.key == "favourites" { return .favorites }
            if folder.key.hasPrefix("mix-") { return .dailyMix(String(folder.key.dropFirst(4))) }
            return .playlist(PlaylistRef(id: folder.key, name: folder.name, coverArt: folder.coverArt))
        }
    }
}
