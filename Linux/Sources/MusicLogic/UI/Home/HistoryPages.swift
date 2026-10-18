import CGtk
import Foundation

/// Rediscover: forgotten favourites, never-played tracks, a year and a month ago.
@MainActor
enum RediscoverPage {
    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let model = RediscoverModel()
        let body = Box.vertical(spacing: 24)
        body.keep(model)
        let rebuild = Observer {
            _ = model.isLoading
            _ = model.neverPlayed
            _ = model.yearAgo
            _ = model.monthAgo
            let forgotten = model.forgotten
            _ = forgotten
            fill(body, model: model, env: env)
        }
        body.keep(rebuild)
        body.observe {
            let scope = app.scope.scope
            _ = app.scope.generation
            Task { await model.load(appState: app, scope: scope) }
        }
        return Page.make("Rediscover", content: body.margin(horizontal: 12, vertical: 24)) { bar in
            bar.end(Button(icon: "view-refresh-symbolic", "flat") { Task { await model.load(appState: app, scope: app.scope.scope) } }.tooltip("Refresh"))
        }
    }

    private static func fill(_ body: Box, model: RediscoverModel, env: Env) {
        let app = env.app
        body.removeAll()
        if model.isEmpty {
            if model.isLoading {
                body.append(Spinner().size(32).halign(GTK_ALIGN_CENTER).margin(48))
            } else {
                body.append(StatusPage(icon: "document-open-recent-symbolic", title: "Nothing to Rediscover", description: "Star a few tracks, and this fills in as your library ages."))
            }
            return
        }
        if !model.forgotten.songs.isEmpty {
            let lastPlayed: (Song) -> String? = { model.lastPlayedText(for: $0) }
            let list = SongList.make(env, model.forgotten.songs, source: "Forgotten Favourites", trailing: lastPlayed)
            body.append(section("Forgotten Favourites", footer: "Starred, and least recently played. A favourite you have never played at all comes first.", list))
        }
        if !model.neverPlayed.isEmpty {
            let list = SongList.make(env, model.neverPlayed, source: "Never Played")
            let reroll = Button("Show Me Another Handful", icon: "view-refresh-symbolic", "flat") {
                Task { await model.reroll(appState: app, scope: app.scope.scope) }
            }
            reroll.halign(GTK_ALIGN_START)
            let box = Box.vertical(spacing: 6)
            box.append(list)
            box.append(reroll)
            body.append(section("Never Played", footer: "Most of a library has never been played once.", box))
        }
        if !model.yearAgo.isEmpty {
            body.append(section("A Year Ago Today", footer: nil, SongList.make(env, model.yearAgo, source: "A Year Ago Today")))
        }
        if !model.monthAgo.isEmpty {
            body.append(section("A Month Ago", footer: nil, SongList.make(env, model.monthAgo, source: "A Month Ago")))
        }
    }

    static func section(_ title: String, footer: String?, _ content: Widget) -> Widget {
        let box = Box.vertical(spacing: 8) {
            Label(title, "shelf-title")
            content
        }
        if let footer { box.append(Label(footer, "caption", "dim").wrap()) }
        return box
    }
}

/// Trip Mode: how long, at what quality, and the plan that packs it — the phone's model.
@MainActor
enum TripModePage {
    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let model = TripModeModel()
        let days = SpinRow("Days", min: 1, max: 21, step: 1, value: Double(model.days)) { value in
            model.days = Int(value)
            model.replan(downloads: app.downloads)
        }
        let hours = SpinRow("Hours a day", min: 1, max: 12, step: 1, value: Double(model.hoursPerDay)) { value in
            model.hoursPerDay = Int(value)
            model.replan(downloads: app.downloads)
        }
        let needed = ActionRow("Music needed")
        let neededValue = Label("", "dim")
        needed.suffix(neededValue)
        let qualities = DownloadQuality.allCases
        let quality = ComboRow("Quality", options: qualities.map(\.label), selected: qualities.firstIndex(of: model.quality) ?? 0) { index in
            guard qualities.indices.contains(index) else { return }
            model.quality = qualities[index]
            model.replan(downloads: app.downloads)
        }
        let qualityDetail = Label("", "caption", "dim").wrap()

        let plan = PreferencesGroup("The Plan", description: "Built from your favourites, today's mixes and what you play most — whole albums where it can, and never the same recording twice.")
        func figure(_ title: String) -> (ActionRow, Label) {
            let row = ActionRow(title)
            let value = Label("", "dim")
            row.suffix(value)
            plan.add(row)
            return (row, value)
        }
        let songs = figure("Songs").1
        let time = figure("Playing time").1
        let already = figure("Already downloaded").1
        let toDownload = figure("To download").1
        let free = figure("Free space").1
        let warning = Label("Some of it was left out — there isn't room at this quality.", "caption", "warning").wrap()
        let pack = Button("Download", icon: "folder-download-symbolic", "suggested-action", "pill") { model.pack(appState: app) }
        let packing = PreferencesGroup("What Gets Packed")

        let body = Box.vertical(spacing: 24) {
            PreferencesGroup("How Long") {
                days
                hours
                needed
            }
            PreferencesGroup("Quality", description: "Original is what this app normally downloads. The other three are transcoded by the server on the way out, which is the only way a long trip fits.") {
                quality
            }
            qualityDetail
            plan
            warning
            pack.halign(GTK_ALIGN_START)
            packing
        }.margin(horizontal: 12, vertical: 24)
        body.keep(model)

        body.observe {
            neededValue.text = model.targetText
            qualityDetail.text = model.quality.detail
            let current = model.plan
            songs.text = "\(current.songCount)"
            time.text = current.seconds.asLongDuration
            already.text = "\(current.alreadyCount) songs"
            toDownload.text = current.bytesToDownload.asFileSize
            free.text = model.freeBytes.asFileSize
            warning.isVisible = current.isSpaceLimited
            pack.label = current.toDownload.isEmpty ? "Already Packed" : "Download \(current.toDownload.count) Songs"
            pack.isSensitive = !current.toDownload.isEmpty
        }
        let packingRows = Box.vertical(spacing: 0)
        packing.add(packingRows)
        packing.observe {
            let groups = model.plan.groups
            packingRows.removeAll()
            packing.isVisible = !groups.isEmpty
            for group in groups {
                packingRows.append(ActionRow(group.name, subtitle: "\(group.songs.count) songs\(group.subtitle.map { " · \($0)" } ?? "")"))
            }
        }
        body.observe {
            _ = app.downloads.catalog.entries.count
            model.replan(downloads: app.downloads)
        }
        Task { await model.load(appState: app, scope: app.scope.scope) }
        return Page.make("Trip Mode", content: body)
    }
}

/// Stats: what this computer recorded — plays, hours, streaks, when you listen, the top
/// lists — and what the server knows across every device.
@MainActor
enum StatsPage {
    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let history = app.history
        var window: ListeningHistory.Window = .month
        let windows = ListeningHistory.Window.allCases
        let switcher = Box.horizontal().css("linked").halign(GTK_ALIGN_CENTER)
        let local = Box.vertical(spacing: 24)
        var first: ToggleButton?
        for option in windows {
            let toggle = ToggleButton(option.title)
            if let first { toggle.group(with: first) } else { first = toggle }
            toggle.isActive = option == window
            switcher.append(toggle)
            Signal.connect(toggle.widget, "toggled") {
                guard toggle.isActive else { return }
                window = option
                fill()
            }
        }

        func fill() {
            local.removeAll()
            let plays = history.plays(in: window)
            let seconds = history.totalSeconds(in: window)
            let hours = seconds < 3_600 ? "\(seconds / 60)m"
                : (Double(seconds) / 3_600 < 10 ? String(format: "%.1fh", Double(seconds) / 3_600) : "\(seconds / 3_600)h")
            let figures = Box.horizontal(spacing: 0) {
                figure("\(plays.count)", "plays")
                figure(hours, "listened")
                figure("\(history.streak)", "day streak")
            }.homogeneous()
            local.append(RediscoverPage.section("On This Computer",
                footer: history.plays.isEmpty ? "Nothing yet. Plays are recorded as they happen, on this computer." : "Recorded on this computer, from when the app was first run.",
                figures))

            let byHour = history.playsByHour(in: window)
            let byDay = history.playsByDay(30)
            local.append(RediscoverPage.section("When You Listen", footer: nil, Box.vertical(spacing: 12) {
                bars(byHour.map(Double.init), height: 70, labels: ["12a", "12p", "11p"])
                bars(byDay.map { Double($0.count) }, height: 50, labels: ["Last 30 days"])
            }))
            for (title, entries) in [
                ("Top Artists", history.topArtists(in: window)),
                ("Top Albums", history.topAlbums(in: window)),
                ("Top Songs", history.topSongs(in: window)),
                ("Top Genres", history.topGenres(in: window)),
            ] where !entries.isEmpty {
                let group = PreferencesGroup(title)
                for (index, entry) in entries.enumerated() {
                    let row = ActionRow(entry.name, subtitle: entry.subtitle)
                    row.prefix(Label("\(index + 1)", "song-number"))
                    row.suffix(Label("\(entry.count)", "accent"))
                    group.add(row)
                }
                local.append(group)
            }
            if !history.plays.isEmpty {
                let count = history.plays.count
                local.append(PreferencesGroup(description: "\(count) plays recorded on this computer. Clearing does not touch the server's own play counts.") {
                    ButtonRow("Export History…", icon: "document-save-symbolic") {
                        FilePicker.save(Data(csv(history.plays).utf8), suggestedName: "listening-history.csv", title: "Export Listening History")
                    }
                    ButtonRow("Clear Listening History", icon: "user-trash-symbolic", destructive: true) {
                        Dialogs.alert(
                            "Delete \(count) plays recorded on this computer?",
                            body: "Play counts on the server are unaffected.",
                            responses: [("cancel", "Cancel", ADW_RESPONSE_DEFAULT), ("delete", "Delete", ADW_RESPONSE_DESTRUCTIVE)]
                        ) { if $0 == "delete" { history.clear(); fill() } }
                    }
                })
            }
        }

        let server = Box.vertical(spacing: 24)
        let body = Box.vertical(spacing: 24) {
            switcher
            local
            server
        }.margin(horizontal: 12, vertical: 24)
        let alive = body.liveness
        Task { @MainActor in
            await history.loaded()
            guard alive.isAlive else { return }
            fill()
            async let status = try? app.client.scanStatus()
            async let stars = try? app.client.starred()
            async let frequent = try? app.client.albums(type: .frequent, size: 10)
            async let playing = try? app.client.nowPlaying()
            async let recent = try? app.native.recentlyPlayed(limit: 25)
            async let top = try? app.native.mostPlayed(limit: 25)
            let (scan, starred, mostPlayed, nowPlaying, recentTracks, topTracks) = await (status, stars, frequent ?? [], playing ?? [], recent ?? [], top ?? [])
            guard alive.isAlive else { return }
            if !topTracks.isEmpty {
                let group = PreferencesGroup("Most Played Tracks", description: "Every device, all time.")
                for (index, song) in topTracks.prefix(10).enumerated() {
                    let row = ActionRow(song.title, subtitle: song.artist)
                    row.prefix(Label("\(index + 1)", "song-number"))
                    row.suffix(Label("\(song.playCount ?? 0)", "dim"))
                    group.add(row)
                }
                server.append(group)
            }
            if !recentTracks.isEmpty {
                let group = PreferencesGroup("Recently Played", description: "From Navidrome — so a track played on another device shows here too.")
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                for song in recentTracks.prefix(15) {
                    let row = ActionRow(song.title, subtitle: song.artist)
                    row.suffix(Label(song.playDate.map { formatter.localizedString(for: $0, relativeTo: .now) } ?? "", "dim"))
                    group.add(row)
                }
                server.append(group)
            }
            if !nowPlaying.isEmpty {
                let group = PreferencesGroup("Playing Now", description: "Anything your account is playing, on any device.")
                for entry in nowPlaying {
                    let artwork = ArtworkView(app, size: .thumb, side: 40, shape: .thumb)
                    artwork.show(entry.coverArt, fallback: entry.title)
                    let row = ActionRow(entry.title ?? "Unknown", subtitle: [entry.artist, entry.playerName].compactMap { $0 }.joined(separator: " · "))
                    row.prefix(artwork.root)
                    group.add(row)
                }
                server.append(group)
            }
            let library = PreferencesGroup("Library", description: "From the server, so this counts every play however you made it.")
            @MainActor func value(_ title: String, _ text: String) {
                library.add(ActionRow(title).suffix(Label(text, "dim")))
            }
            if let count = scan?.count { value("Tracks", "\(count)") }
            if let starred {
                value("Favourite songs", "\(starred.songs.count)")
                value("Favourite albums", "\(starred.albums.count)")
            }
            if let last = scan?.lastScanAt { value("Last scan", last.formatted(date: .abbreviated, time: .shortened)) }
            server.append(library)
            if !mostPlayed.isEmpty {
                server.append(Shelf.make("Most Played, All Time", cards: mostPlayed.map { Cards.album(env, $0) }))
            }
            let storage = PreferencesGroup("On This Computer")
            storage.add(ActionRow("Downloaded").suffix(Label("\(app.downloads.catalog.entries.count) tracks", "dim")))
            storage.add(ActionRow("Audio").suffix(Label(app.downloads.catalog.totalBytes.asFileSize, "dim")))
            storage.add(ActionRow("Artwork").suffix(Label(ArtworkStore.diskUsage().asFileSize, "dim")))
            server.append(storage)
        }
        return Page.make("Stats", content: body)
    }

    private static func figure(_ value: String, _ label: String) -> Widget {
        Box.vertical(spacing: 2) {
            Label(value, "title-2", "accent", "numeric").xalign(0.5)
            Label(label, "caption", "dim").xalign(0.5)
        }
    }

    /// A row of bars, tallest at `height`, with a few labels underneath.
    static func bars(_ values: [Double], height: Int32, labels: [String]) -> Widget {
        let peak = max(values.max() ?? 1, 1)
        let chart = DrawingArea(height: height) { cairo, width, chartHeight in
            guard !values.isEmpty else { return }
            let slot = width / Double(values.count)
            for (index, value) in values.enumerated() {
                let barHeight = max(2, value / peak * chartHeight)
                cairo.color(Style.tint, alpha: value == 0 ? 0.15 : 0.9)
                cairo.roundedRectangle(Double(index) * slot + 1, chartHeight - barHeight, max(1, slot - 2), barHeight, radius: 1.5)
                cairo.fill()
            }
        }
        chart.hexpand()
        let legend = Box.horizontal()
        for (index, label) in labels.enumerated() {
            let text = Label(label, "caption", "dimmer")
            if index > 0 { legend.append(Spacer()) }
            legend.append(text)
        }
        return Box.vertical(spacing: 4) {
            chart
            legend
        }
    }

    private static func csv(_ plays: [ListeningHistory.Play]) -> String {
        let formatter = ISO8601DateFormatter()
        func escaped(_ field: String) -> String { "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let rows = plays.map { play in
            [formatter.string(from: play.at), escaped(play.title), escaped(play.artist), escaped(play.album), escaped(play.genre ?? ""), String(play.duration)].joined(separator: ",")
        }
        return (["played_at,title,artist,album,genre,seconds"] + rows).joined(separator: "\n")
    }
}

/// Charts from the local history: tracks, albums and artists for a week, month, season,
/// year, decade or all time, stepping back through past periods.
@MainActor
enum ChartsPage {
    private enum Kind: String, CaseIterable {
        case tracks = "Tracks", albums = "Albums", artists = "Artists"
    }

    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let defaults = UserDefaults.standard
        var span = ChartSpan(rawValue: defaults.string(forKey: "charts.span") ?? "") ?? .month
        var limit = defaults.object(forKey: "charts.limit") as? Int ?? 25
        var hemisphere = Hemisphere(rawValue: defaults.string(forKey: "charts.hemisphere") ?? "") ?? .north
        var period: ChartPeriod?
        var kind: Kind = .tracks
        var generation = 0

        let title = Label("", "heading").xalign(0.5).hexpand()
        let back = Button(icon: "go-previous-symbolic", "flat", "circular")
        let forward = Button(icon: "go-next-symbolic", "flat", "circular")
        let periodRow = Box.horizontal(spacing: 8) {
            back
            title
            forward
        }
        let spanCombo = ComboRow("Span", options: ChartSpan.allCases.map(\.title), selected: ChartSpan.allCases.firstIndex(of: span) ?? 1) { index in
            span = ChartSpan.allCases[index]
            defaults.set(span.rawValue, forKey: "charts.span")
            period = nil
        }
        let kinds = Box.horizontal().css("linked").halign(GTK_ALIGN_CENTER)
        let list = ListBox()
        let body = Box.vertical(spacing: 18) {
            PreferencesGroup { spanCombo }
            periodRow
            kinds
            list
        }.margin(horizontal: 12, vertical: 24)
        let alive = body.liveness

        func shown() -> ChartPeriod { period ?? ChartPeriod.current(span) }

        func refresh() {
            let current = shown()
            periodRow.isVisible = span != .all
            title.text = current.title(hemisphere: hemisphere)
            forward.isSensitive = current.hasNext()
            generation += 1
            let mine = generation
            let plays = app.history.plays
            Task { @MainActor in
                var rows: [ChartRow]
                if span == .all, kind == .albums {
                    let albums = (try? await app.client.albums(type: .frequent, size: limit, scope: app.scope.scope)) ?? []
                    rows = albums.map { ChartRow(id: $0.id, title: $0.name, subtitle: $0.artist, plays: $0.playCount ?? 0, albumID: $0.id, artistID: $0.artistId, coverArt: $0.coverArt) }
                } else {
                    let currentKind = kind
                    let currentLimit = limit
                    rows = await Task.detached(priority: .userInitiated) { () -> [ChartRow] in
                        let chart = plays.map { $0.chartPlay }
                        switch currentKind {
                        case .tracks: return Charts.topTracks(chart, in: current, limit: currentLimit)
                        case .albums: return Charts.topAlbums(chart, in: current, limit: currentLimit)
                        case .artists: return Charts.topArtists(chart, in: current, limit: currentLimit)
                        }
                    }.value
                }
                guard alive.isAlive, mine == generation else { return }
                show(rows)
            }
        }

        func show(_ rows: [ChartRow]) {
            list.removeAll()
            if rows.isEmpty {
                list.placeholder(Label(span == .all ? "Nothing played yet." : "Nothing played in this \(span.title.lowercased()).", "dim").margin(24))
                return
            }
            for (index, row) in rows.enumerated() {
                let artwork = ArtworkView(app, size: .thumb, side: 40, shape: kind == .artists ? .round : .thumb)
                artwork.show(row.coverArt, fallback: row.title)
                let line = Box.horizontal(spacing: 12) {
                    Label("\(index + 1)", "heading", "dim").widthChars(3).xalign(1)
                    artwork.root
                    Box.vertical(spacing: 2) {
                        Label(row.title).ellipsize()
                        if let subtitle = row.subtitle { Label(subtitle, "caption", "dim").ellipsize() }
                    }.hexpand().valign(GTK_ALIGN_CENTER)
                    Label(row.plays == 1 ? "1 play" : "\(row.plays) plays", "song-meta")
                }.margin(horizontal: 12, vertical: 6)
                list.append(line) {
                    switch kind {
                    case .tracks: play(fromTrack: index, rows: rows)
                    case .albums:
                        if let id = row.albumID { env.open(.album(AlbumRef(id: id, name: row.title, artist: row.subtitle, coverArt: row.coverArt))) }
                    case .artists:
                        if let id = row.artistID { env.open(.artist(ArtistRef(id: id, name: row.title))) }
                    }
                }
            }
        }

        func play(fromTrack index: Int, rows: [ChartRow]) {
            let ids = rows[index...].compactMap(\.songID)
            let source = "Charts · \(shown().title(hemisphere: hemisphere))"
            Task { @MainActor in
                var found: [Int: Song] = [:]
                await withTaskGroup(of: (Int, Song?).self) { group in
                    for (offset, id) in ids.enumerated() {
                        group.addTask { (offset, try? await app.client.song(id: id)) }
                    }
                    for await (offset, song) in group { if let song { found[offset] = song } }
                }
                env.play(ids.indices.compactMap { found[$0] }, source: source)
            }
        }

        var firstKind: ToggleButton?
        for option in Kind.allCases {
            let toggle = ToggleButton(option.rawValue)
            if let firstKind { toggle.group(with: firstKind) } else { firstKind = toggle }
            toggle.isActive = option == kind
            kinds.append(toggle)
            Signal.connect(toggle.widget, "toggled") {
                guard toggle.isActive else { return }
                kind = option
                refresh()
            }
        }
        back.onClicked { period = shown().offset(by: -1); refresh() }
        forward.onClicked { period = shown().offset(by: 1); refresh() }
        Signal.connect(spanCombo.widget, "notify::selected", pointer: { _ in refresh() })
        body.observe {
            _ = app.history.plays.count
            refresh()
        }
        Task { await app.history.loaded() }

        let options = MenuButton(icon: "emblem-system-symbolic", "flat") {
            Menu([[
                .choice("Length", options: Charts.limits.map { (String($0), "Top \($0)") }, selected: String(limit)) { value in
                    limit = Int(value) ?? 25
                    defaults.set(limit, forKey: "charts.limit")
                    refresh()
                },
                .choice("Hemisphere", options: [(Hemisphere.north.rawValue, "Northern Hemisphere"), (Hemisphere.south.rawValue, "Southern Hemisphere")], selected: hemisphere.rawValue) { value in
                    hemisphere = Hemisphere(rawValue: value) ?? .north
                    defaults.set(hemisphere.rawValue, forKey: "charts.hemisphere")
                    refresh()
                },
            ]])
        }
        return Page.make("Charts", content: body) { bar in bar.end(options) }
    }
}
