import CGtk
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Getting music into the library from the app, as on the phone (`GrabService`): Search's
// Soulseek side, the Add dialog, the Requests page and one request's page with its copies
// to pick from, and an artist's records the library lacks. The server finds a lossless copy
// on Soulseek -- never anything lossy -- downloads it, checks it and adds it.

/// An album or song cover from YouTube Music, square.
@MainActor
enum CatalogCover {
    private static var cache: [URL: Texture] = [:]

    static func make(_ url: URL?, side: Int32 = 48) -> Widget {
        let picture = Picture().fit(GTK_CONTENT_FIT_COVER)
        let frame = ScrolledWindow(picture, horizontal: GTK_POLICY_EXTERNAL, vertical: GTK_POLICY_EXTERNAL)
        frame.size(width: side, height: side)
        gtk_scrolled_window_set_max_content_width(frame.widget.cast(), side)
        gtk_scrolled_window_set_max_content_height(frame.widget.cast(), side)
        let root = Overlay(frame).css("video-thumb")
        root.clipped().halign(GTK_ALIGN_START).valign(GTK_ALIGN_CENTER).hexpand(false).vexpand(false)
        guard let url else { return root }
        if let kept = cache[url] {
            picture.set(kept)
        } else {
            let alive = picture.liveness
            Task { @MainActor in
                guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                let texture = await Task.detached { Texture(data: data) }.value
                guard let texture else { return }
                if cache.count > 400 { cache.removeAll() }
                cache[url] = texture
                if alive.isAlive { picture.set(texture) }
            }
        }
        return root
    }
}

/// Search's Soulseek side: YouTube Music's songs and albums, each marked when the library
/// has it, the rest one click from being got.
@MainActor
enum CatalogResults {
    static func make(_ env: Env, query: String) -> Widget {
        let app = env.app
        guard app.grab.isAvailable else {
            return StatusPage(
                icon: "folder-download-symbolic",
                title: "Soulseek Needs the Server",
                description: "Getting music goes through the request service on the server. It isn't answering right now."
            )
        }
        guard !query.isEmpty else {
            return StatusPage(
                icon: "folder-download-symbolic",
                title: "Get Music",
                description: "Songs and albums that aren't in your library yet. Add one, and it comes in lossless from Soulseek."
            )
        }
        let holder = Bin(Spinner().size(32).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_START).margin(48))
        let alive = holder.liveness
        Task { @MainActor in
            let found = try? await SonicClient(configuration: app.sonic.configuration).catalogSearch(query)
            guard alive.isAlive else { return }
            guard let found else {
                holder.child = StatusPage(icon: "network-offline-symbolic", title: "Can’t Search Right Now",
                                          description: "The search didn't go through. Try again in a moment.")
                return
            }
            guard !found.songs.isEmpty || !found.albums.isEmpty else {
                holder.child = StatusPage(icon: "system-search-symbolic", title: "No Results",
                                          description: "Nothing for “\(query)”.")
                return
            }
            let body = Box.vertical(spacing: 18)
            if !found.albums.isEmpty {
                let group = PreferencesGroup("Albums")
                for album in found.albums {
                    group.add(row(env, query: query, title: album.title,
                                  subtitle: [album.artist, album.type, album.year].compactMap { $0 }.joined(separator: " · "),
                                  cover: album.cover, have: album.have,
                                  item: .album(artist: album.artist, title: album.title, year: album.year,
                                               albumID: album.albumId, cover: album.cover)))
                }
                body.append(group)
            }
            if !found.songs.isEmpty {
                let group = PreferencesGroup("Songs")
                for song in found.songs {
                    group.add(row(env, query: query, title: song.title,
                                  subtitle: [song.artist, song.album].compactMap { $0 }.joined(separator: " · "),
                                  cover: song.cover, have: song.have,
                                  item: .song(artist: song.artist, title: song.title, album: song.album,
                                              albumID: song.albumId, seconds: song.seconds,
                                              videoID: song.videoId, cover: song.cover)))
                }
                body.append(group)
            }
            holder.child = body
        }
        return holder
    }

    private static func row(_ env: Env, query: String, title: String, subtitle: String, cover: URL?,
                            have: Bool, item: AddMusicItem) -> Widget {
        let row = ActionRow(title, subtitle: subtitle).prefix(CatalogCover.make(cover))
        if have {
            row.suffix(Icon("object-select-symbolic").css("dim-label").tooltip("In your library"))
        } else {
            let add = Button(icon: "list-add-symbolic", "flat", "circular") {
                env.app.recentSearches.record(query)
                AddMusic.present(env, item)
            }
            add.valign(GTK_ALIGN_CENTER).tooltip("Get “\(title)”…")
            row.suffix(add)
            row.activated {
                env.app.recentSearches.record(query)
                AddMusic.present(env, item)
            }
        }
        return row
    }
}

/// The Add dialog: which library, for a song whether its album comes too, and Add -- the
/// server takes the best lossless copy -- or Choose the Copy, which opens the request's page
/// once the search is done.
@MainActor
enum AddMusic {
    static func present(_ env: Env, _ item: AddMusicItem) {
        present(env.app, item, toast: env.toast, open: { env.open($0) })
    }

    /// From a window without pages of its own (the video's): `open` goes through the app.
    static func present(_ app: AppState, _ item: AddMusicItem, toast: @escaping @MainActor (String) -> Void,
                        open: @escaping @MainActor (Destination) -> Void) {
        var library = app.grab.lastLibrary
        var albumToo = false
        var dialog: OpaquePointer?

        let artwork: Widget
        if item.cover != nil {
            artwork = CatalogCover.make(item.cover, side: 64)
        } else {
            let view = ArtworkView(app, size: .thumb, side: 64, shape: .thumb)
            view.show(item.coverArt, fallback: item.title)
            artwork = view.root
        }
        let header = Box.horizontal(spacing: 12) {
            artwork
            Box.vertical(spacing: 2) {
                Label(item.title, "heading").xalign(0).wrap()
                Label(item.artist, "dim-label").xalign(0).ellipsize()
                Label(kindLine(item), "caption", "dim-label").xalign(0)
            }.valign(GTK_ALIGN_CENTER)
        }

        let music = ToggleButton("Music")
        let mine = ToggleButton("My Music")
        mine.group(with: music)
        music.isActive = library == .music
        mine.isActive = library == .myMusic
        Signal.connect(mine.widget, "toggled") { library = mine.isActive ? .myMusic : .music }
        let libraries = Box.horizontal(spacing: 0) { music.hexpand(); mine.hexpand() }.css("linked")
        let libraryGroup = PreferencesGroup("Add To") { libraries }
        libraryGroup.isVisible = item.asksForLibrary

        let albumGroup = PreferencesGroup(description: "The song comes first, so it plays within minutes.") {
            SwitchRow("Also Get Its Album", isOn: false) { albumToo = $0 }
        }
        if case .song = item {} else { albumGroup.isVisible = false }

        let problem = Label("", "error").xalign(0).wrap()
        problem.isVisible = false
        let spinner = Spinner().size(16)
        spinner.isVisible = false

        func send(choose: Bool) {
            spinner.isVisible = true
            problem.isVisible = false
            Task { @MainActor in
                defer { spinner.isVisible = false }
                do {
                    let request = try await app.grab.ask(item.ask(library: library, choose: choose, albumToo: albumToo))
                    if let dialog { Dialogs.close(dialog) }
                    if choose {
                        open(.grabRequest(request.id))
                    } else {
                        toast(albumToo ? "Getting “\(item.title)”, then its album" : "Getting “\(item.title)”")
                    }
                } catch {
                    problem.text = error.localizedDescription
                    problem.isVisible = true
                }
            }
        }

        let lossless: Bool = if case .lossless = item { true } else { false }
        let add = Button(lossless ? "Get It Lossless" : "Add", "suggested-action", "pill") { send(choose: false) }
        let pick = Button("Choose the Copy…", "pill") { send(choose: true) }
        let note = lossless
            ? "A lossless copy replaces the file where it is, keeping its plays, stars and tags."
            : "Only lossless copies, from Soulseek. Add takes the best one; Choose the Copy shows every one found."

        let body = Box.vertical(spacing: 18) {
            header
            libraryGroup
            albumGroup
            Box.horizontal(spacing: 12) { add; pick; spinner }.halign(GTK_ALIGN_CENTER)
            Label(note, "caption", "dim-label").wrap().justify(GTK_JUSTIFY_CENTER)
            problem
        }.margin(18)
        dialog = Dialogs.sheet(item.isAlbum ? "Get the Album" : "Get the Song", content: Clamp(body, maximum: 520),
                               width: 480, height: 460)
    }

    private static func kindLine(_ item: AddMusicItem) -> String {
        switch item {
        case .song: "Song"
        case let .album(_, _, year, _, _): ["Album", year].compactMap { $0 }.joined(separator: " · ")
        case .fullAlbum: "The album this song is on"
        case let .lossless(song): "In your library as \(song.suffix?.uppercased() ?? "a lossy file")"
        }
    }
}

/// Rows for requests and their parts.
@MainActor
enum RequestRows {
    static func request(_ request: SonicClient.GrabRequest) -> Widget {
        let line = [request.artist, request.kind == "album" ? "Album" : "Song",
                    request.library == .music ? "Music" : "My Music"].compactMap { $0 }.joined(separator: " · ")
        return part(title: request.title ?? "", line: line, detail: request.detail, state: request.state,
                    progress: request.progress)
    }

    static func target(_ target: SonicClient.GrabTarget) -> Widget {
        part(title: target.title, line: target.kind == "album" ? "Album" : "Song", detail: target.detail,
             state: target.state, progress: target.progress)
    }

    private static func part(title: String, line: String, detail: String, state: SonicClient.GrabState,
                             progress: SonicClient.GrabProgress?) -> Widget {
        let text = Box.vertical(spacing: 2) {
            Label(title, "heading").xalign(0).ellipsize()
            Label(line, "caption", "dim-label").xalign(0).ellipsize()
            Label(detail, state == .failed ? "error" : "dim-label").xalign(0).wrap()
        }.hexpand()
        if let progress, state == .downloading {
            let bar = ProgressBar()
            bar.fraction = progress.fraction
            text.append(bar)
            text.append(Label("\(bytes(progress.done)) of \(bytes(progress.total))", "caption", "dim-label", "numeric").xalign(0))
        }
        return Box.horizontal(spacing: 12) {
            icon(state).valign(GTK_ALIGN_START)
            text
        }.margin(horizontal: 12, vertical: 8)
    }

    static func icon(_ state: SonicClient.GrabState) -> Widget {
        switch state {
        case .searching, .queued, .importing: Spinner().size(20)
        case .downloading: Icon("folder-download-symbolic").css("accent")
        case .choosing: Icon("view-list-bullet-symbolic").css("accent")
        case .done: Icon("object-select-symbolic").css("success")
        case .failed: Icon("dialog-warning-symbolic").css("error")
        case .cancelled: Icon("process-stop-symbolic").css("dim-label")
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// Everything asked for from the app, newest first, with retry and cancel.
@MainActor
enum RequestsPage {
    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let grab = app.grab
        let body = Box.vertical(spacing: 0)
        body.observe {
            body.removeAll()
            body.append(soulseekSummary(env))
            guard !grab.requests.isEmpty else {
                body.append(StatusPage(
                    icon: "folder-download-symbolic",
                    title: "Nothing Asked For",
                    description: grab.isAvailable
                        ? "Songs and albums you get from Search, an artist's page or a song's menu show up here as they come in."
                        : "Getting music needs the server's request service, which isn't answering right now."
                ))
                return
            }
            let list = ListBox(boxed: true)
            for request in grab.requests {
                let row = RequestRows.request(request)
                let actions = Box.horizontal(spacing: 6).valign(GTK_ALIGN_CENTER)
                if request.state == .failed || request.state == .cancelled {
                    actions.append(Button(icon: "view-refresh-symbolic", "flat", "circular") {
                        act(env) { try await grab.retry(request) }
                    }.tooltip("Try Again"))
                }
                if request.state.isActive || request.state == .choosing {
                    actions.append(Button(icon: "process-stop-symbolic", "flat", "circular") {
                        act(env) { try await grab.cancel(request) }
                    }.tooltip("Cancel Request"))
                }
                actions.append(Icon("go-next-symbolic").css("row-chevron"))
                let line = Box.horizontal(spacing: 0) { row.hexpand(); actions.margins(end: 12) }
                list.append(Button(child: line, "flat", "request-row") { env.open(.grabRequest(request.id)) })
            }
            body.append(list)
        }
        body.onMap {
            grab.beginWatchingClosely()
            grab.beginMonitoring()
            Task { await grab.refreshAvailability(force: true) }
        }
        body.onUnmap {
            grab.endWatchingClosely()
            grab.endMonitoring()
        }
        return Page.make("Requests", content: Box.vertical(spacing: 12) { body }.margin(horizontal: 12, vertical: 6))
    }

    /// Soulseek at a glance, above the requests: is it signed in, what is moving. Opens the
    /// monitor (`SoulseekPage`).
    private static func soulseekSummary(_ env: Env) -> Widget {
        let grab = env.app.grab
        let monitor = grab.monitor
        let trouble = monitor.map { !$0.slskd.isOnline } ?? grab.monitorFailed
        let headline = monitor?.slskd.headline ?? (grab.monitorFailed ? "The request service isn't answering" : "Checking…")
        let lines = [headline, trouble ? nil : monitor?.activityLine].compactMap { $0 }
        let row = ActionRow("Soulseek", subtitle: lines.joined(separator: "\n"))
            .subtitleLines(2)
            .prefix(SoulseekPage.statusIcon(monitor?.slskd, failed: grab.monitorFailed))
            .chevron()
            .activated { env.open(.soulseek) }
        return PreferencesGroup { row }.margins(bottom: 12)
    }

    static func act(_ env: Env, _ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await work()
            } catch {
                env.toast(error.localizedDescription)
            }
        }
    }
}

/// One request: where it stands, and while it waits for one, every lossless copy found to
/// pick from. Read again every few seconds while it is open.
@MainActor
enum RequestPage {
    static func make(_ env: Env, id: String) -> NavigationPage {
        let app = env.app
        let body = Box.vertical(spacing: 18)
        body.append(Spinner().size(32).halign(GTK_ALIGN_CENTER).margin(48))
        var picking = false

        func show(_ request: SonicClient.GrabRequest) {
            body.removeAll()
            body.append(PreferencesGroup { RequestRows.request(request) })
            for target in request.targets {
                if target.state == .choosing, !target.copies.isEmpty {
                    let group = PreferencesGroup(
                        request.targets.count > 1 ? target.title : "Pick a Copy",
                        description: "Lossless only, best first: whole, free to send now, and quick."
                    )
                    for copy in target.copies {
                        let row = ActionRow(copy.folder, subtitle: copySubtitle(copy)).subtitleLines(3)
                        if copy.index == 0 { row.suffix(Label("Best", "accent", "caption-heading").valign(GTK_ALIGN_CENTER)) }
                        row.activated {
                            guard !picking else { return }
                            picking = true
                            RequestsPage.act(env) {
                                defer { picking = false }
                                show(try await app.grab.choose(request, target: target.key, copy: copy.index))
                            }
                        }
                        group.add(row)
                    }
                    body.append(group)
                } else if request.targets.count > 1 {
                    body.append(PreferencesGroup(target.kind == "album" ? "Album" : "Song") { RequestRows.target(target) })
                }
            }
            let actions = Box.horizontal(spacing: 12).halign(GTK_ALIGN_CENTER)
            if request.state == .failed || request.state == .cancelled {
                actions.append(Button("Try Again", icon: "view-refresh-symbolic", "pill") {
                    RequestsPage.act(env) { try await app.grab.retry(request) }
                })
            }
            if request.state.isActive || request.state == .choosing {
                actions.append(Button("Cancel Request", icon: "process-stop-symbolic", "pill", "destructive-action") {
                    RequestsPage.act(env) { try await app.grab.cancel(request) }
                })
            }
            body.append(actions)
        }

        let alive = body.liveness
        Task { @MainActor in
            var shownOnce = false
            while alive.isAlive {
                if let fresh = await app.grab.details(id) {
                    guard alive.isAlive else { return }
                    if !picking { show(fresh) }
                    shownOnce = true
                } else if !shownOnce {
                    body.removeAll()
                    body.append(StatusPage(icon: "network-offline-symbolic", title: "Can’t Reach the Server",
                                           description: "The request service isn't answering."))
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        return Page.make("Request", content: body.margin(horizontal: 12, vertical: 6))
    }

    private static func copySubtitle(_ copy: SonicClient.GrabCopy) -> String {
        let what = [copy.formats.map { $0.uppercased() }.joined(separator: ", "),
                    copy.tracks == 1 ? "1 file" : "\(copy.tracks) files", RequestRows.bytes(copy.bytes)]
            .joined(separator: " · ")
        let speed = (copy.speed ?? 0) > 0 ? " · \(RequestRows.bytes(Int64(copy.speed ?? 0)))/s" : ""
        let when = copy.free == true ? "Free to send now" : ((copy.queue ?? 0) > 0 ? "\(copy.queue ?? 0) waiting before you" : "Busy")
        return "\(what)\n\(when)\(speed)\n\(copy.peer)"
    }
}

/// An artist's own albums and EPs the library does not have, each with Get. Stays hidden
/// while the request service is away, and when the library has them all.
@MainActor
enum MissingAlbums {
    static func make(_ env: Env, artist: ArtistRef) -> Widget {
        let app = env.app
        let group = PreferencesGroup("Not in Your Library")
        group.isVisible = false
        let alive = group.liveness
        Task { @MainActor in
            await app.grab.refreshAvailability()
            guard app.grab.isAvailable, !artist.name.isEmpty else { return }
            let found = try? await SonicClient(configuration: app.sonic.configuration)
                .catalogArtist(artistID: artist.id, name: artist.name)
            let missing = found?.albums.filter { !$0.have } ?? []
            guard alive.isAlive, !missing.isEmpty else { return }
            for record in missing {
                let get = Button(icon: "list-add-symbolic", "flat", "circular") {
                    AddMusic.present(env, .album(artist: artist.name, title: record.title, year: record.year))
                }
                get.valign(GTK_ALIGN_CENTER).tooltip("Get “\(record.title)”…")
                group.add(ActionRow(record.title, subtitle: [record.type, record.year].compactMap { $0 }.joined(separator: " · "))
                    .suffix(get))
            }
            group.isVisible = true
        }
        return group
    }
}
