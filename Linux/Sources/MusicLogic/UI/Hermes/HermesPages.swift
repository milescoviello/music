import CGtk
import Foundation

/// Asking Hermes for music, a lyric, a playlist or a library check — the phone's Hermes
/// and Requests screens.
@MainActor
enum HermesPages {
    // MARK: - Request Music

    static func request(_ env: Env, prefill: String) -> NavigationPage {
        let requests = env.app.requests
        let entry = EntryRow("Artist — Album", text: prefill)
        let note = Label("", "caption", "dim").wrap()
        let history = Box.vertical(spacing: 8)
        var didSend = false

        func submit() {
            let text = entry.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !requests.isSending else { return }
            Task { @MainActor in
                if await requests.send(text) {
                    didSend = true
                    entry.text = ""
                }
            }
        }
        let send = ButtonRow("Send Request", icon: "mail-send-symbolic", suggested: true) { submit() }
        Signal.connect(entry.widget, "entry-activated") { submit() }

        let form = Box.vertical(spacing: 24) {
            PreferencesGroup("What Do You Want?") {
                entry
                send
            }
            note
            history
        }
        let notSetUp = StatusPage(
            icon: "network-offline-symbolic", title: "Not Set Up",
            description: "Add the Hermes webhook address and secret in Settings to request music from here.",
            child: Button("Open Settings", "pill") { env.open(.requestSettings) }.halign(GTK_ALIGN_CENTER)
        )
        let body = Box.vertical(spacing: 0) {
            form
            notSetUp
        }.margin(horizontal: 12, vertical: 24)

        body.observe {
            form.isVisible = requests.isConfigured
            notSetUp.isVisible = !requests.isConfigured
            send.isSensitive = !requests.isSending
            if let error = requests.lastError {
                note.text = error
                note.setCSS("error", true)
            } else {
                note.setCSS("error", false)
                note.text = didSend
                    ? "Sent. This screen will say when it shows up in your library."
                    : "An artist and album is enough. Hermes checks the library first so it will not fetch something you already have."
            }
            history.removeAll()
            guard !requests.history.isEmpty else { return }
            let group = PreferencesGroup("Requests", description: "The agent replies on its own channel, which this app cannot read — so instead it watches your library and tells you when the music actually turns up.")
            if requests.isWatchingAnything { group.suffix(Label("checking your library", "caption", "dim")) }
            for item in requests.history { group.add(requestRow(env, item)) }
            history.append(group)
            history.append(PreferencesGroup {
                ButtonRow("Clear History", icon: "user-trash-symbolic", destructive: true) { requests.clearHistory() }
            })
        }
        // While anything is still awaited, the library is checked every twenty seconds.
        let alive = body.liveness
        Task { @MainActor in
            while alive.isAlive, requests.isWatchingAnything {
                await requests.refresh()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        return Page.make("Request Music", content: body)
    }

    private static func requestRow(_ env: Env, _ item: MusicRequestService.Entry) -> Widget {
        let icon: String
        let status: String
        if let arrival = item.arrival {
            icon = "object-select-symbolic"
            let names = arrival.albumNames.filter { !$0.isEmpty }
            status = names.isEmpty ? "Arrived — \(arrival.songCount) new \(arrival.songCount == 1 ? "track" : "tracks")" : "Arrived — " + names.joined(separator: ", ")
        } else if !item.wasAccepted {
            icon = "dialog-warning-symbolic"
            status = "Not sent — " + item.sentAt.formatted(date: .abbreviated, time: .shortened)
        } else if item.gaveUp == true {
            icon = "dialog-question-symbolic"
            status = "Never turned up. Sent " + item.sentAt.formatted(date: .abbreviated, time: .omitted) + "."
        } else {
            icon = "document-open-recent-symbolic"
            status = "Waiting since " + item.sentAt.formatted(date: .omitted, time: .shortened)
        }
        let row = ActionRow(item.text, subtitle: status, icon: icon)
        if let arrival = item.arrival, let albumID = arrival.firstAlbumID {
            row.activated { env.open(.album(AlbumRef(id: albumID, name: arrival.albumNames.first ?? item.text))) }
            row.chevron()
        }
        return row
    }

    static func requestSettings(_ env: Env) -> NavigationPage {
        let requests = env.app.requests
        let address = EntryRow("Webhook Address", text: requests.configuration?.endpoint.absoluteString ?? "")
        address.inputPurpose(GTK_INPUT_PURPOSE_URL)
        let secret = EntryRow("HMAC Secret", password: true)
        let results = EntryRow("Results Address", text: requests.configuration?.resultsBase?.absoluteString ?? "")
        results.inputPurpose(GTK_INPUT_PURPOSE_URL)
        let test = ActionRow("Test Results Address")
        let testResult = Label("", "dim")
        test.suffix(testResult)
        test.activated {
            guard let url = URL(string: results.text), url.host != nil else {
                testResult.text = "Bad URL"
                return
            }
            testResult.text = "…"
            Task { @MainActor in
                let client = HermesClient(configuration: .init(endpoint: url, secret: secret.text, resultsBase: url))
                testResult.text = await client.ping() ? "OK" : "No answer"
            }
        }
        let problem = Label("", "caption", "error").wrap().visible(false)
        let page = PreferencesPage()
        page.add(PreferencesGroup("Hermes Webhook", description: """
        The secret is kept on this computer, readable by you alone. Requests are signed with it, and the \
        gateway rejects anything unsigned or older than five minutes. The results address is where \
        Hermes's answers are read from — the webhook itself is one-way.
        """) {
            address
            secret
            results
            test
        })
        let remove = ButtonRow("Remove", icon: "user-trash-symbolic", destructive: true) {
            requests.forget()
            address.text = ""
            secret.text = ""
        }
        page.add(PreferencesGroup {
            ButtonRow("Save", icon: "document-save-symbolic", suggested: true) {
                guard let url = URL(string: address.text), url.scheme != nil, url.host != nil else {
                    problem.text = "That does not look like a URL."
                    problem.isVisible = true
                    return
                }
                var base: URL?
                if !results.text.isEmpty {
                    guard let parsed = URL(string: results.text), parsed.scheme != nil, parsed.host != nil else {
                        problem.text = "The results address does not look like a URL."
                        problem.isVisible = true
                        return
                    }
                    base = parsed
                }
                guard !secret.text.isEmpty else {
                    problem.text = "The secret is needed to sign requests."
                    problem.isVisible = true
                    return
                }
                problem.isVisible = false
                requests.configure(endpoint: url, secret: secret.text, resultsBase: base)
                env.toast("Saved")
            }
            remove
        })
        page.add(PreferencesGroup { problem })
        page.observe { remove.isVisible = requests.isConfigured }
        return SettingsPages.preferencesPage("Music Requests", page)
    }

    // MARK: - Lyric Search

    static func lyricSearch(_ env: Env, prefill: String) -> NavigationPage {
        let app = env.app
        let entry = EntryRow("A line you remember", text: prefill)
        let results = Box.vertical(spacing: 12)
        var asking = false

        func run() {
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !asking else { return }
            asking = true
            results.set {
                Box.horizontal(spacing: 8) {
                    Spinner().size(16)
                    Label("Searching the library…", "dim")
                }
            }
            let alive = results.liveness
            Task { @MainActor in
                let outcome = await app.hermes.ask(route: "music-lyrics", fields: ["query": trimmed], as: LyricSearchResult.self, timeout: 120)
                asking = false
                guard alive.isAlive else { return }
                switch outcome {
                case let .ok(result):
                    await show(result.found)
                case let .failed(message):
                    results.set { Label(message, "warning").wrap() }
                case .pending:
                    results.set { Label("Hermes didn't answer in time.", "warning") }
                }
            }
        }

        func show(_ matches: [LyricMatch]) async {
            guard !matches.isEmpty else {
                results.set { StatusPage(icon: "format-justify-left-symbolic", title: "No Lyrics Matched", description: "Nothing on file contains that line.").compact() }
                return
            }
            var songs: [String: Song] = [:]
            let client = app.client
            await withTaskGroup(of: (String, Song?).self) { group in
                for match in matches.prefix(25) {
                    group.addTask { (match.songID, try? await client.song(id: match.songID)) }
                }
                for await (id, song) in group { if let song { songs[id] = song } }
            }
            let playable = matches.compactMap { songs[$0.songID] }
            let list = ListBox()
            for match in matches {
                let box = Box.vertical(spacing: 4)
                let index = playable.firstIndex { $0.id == match.songID }
                if let song = songs[match.songID] {
                    let row = SongRowView(env, style: .artwork)
                    row.bind(song)
                    box.append(row.root)
                } else {
                    box.append(Label(match.title ?? "Unknown Track").margins(start: 12))
                    box.append(Label([match.artist, match.album].compactMap { $0 }.joined(separator: " · "), "caption", "dim").margins(start: 12))
                }
                if let line = match.line { box.append(Label("“\(line)”", "caption", "dim").wrap().margins(start: 12)) }
                if let at = match.atMs, let index {
                    box.append(Button("Play from \((at / 1_000).asDuration)", icon: "media-playback-start-symbolic", "flat") {
                        app.player.play(songs: playable, startingAt: index, source: "Lyric Search", startAt: Double(at) / 1_000)
                    }.halign(GTK_ALIGN_START).margins(start: 2))
                }
                list.append(box.margin(horizontal: 12, vertical: 6)) {
                    if let index { env.play(playable, from: index, source: "Lyric Search") }
                }
            }
            results.set {
                Label("\(matches.count) matched", "heading")
                list
            }
        }
        let search = ButtonRow("Search Lyrics", icon: "edit-find-symbolic", suggested: true) { run() }
        Signal.connect(entry.widget, "entry-activated") { run() }

        let body = Box.vertical(spacing: 18) {
            PreferencesGroup(description: "Searches the lyrics stored with your own files, so a miss means there is nothing on file — not that you don't own the song.") {
                entry
                search
            }
            results
        }.margin(horizontal: 12, vertical: 24)
        return Page.make("Lyric Search", content: body)
    }

    // MARK: - Make a Playlist

    static func vibePlaylist(_ env: Env) -> NavigationPage {
        let app = env.app
        let hermes = app.hermes
        let store = app.playlistStore
        let vibe = EntryRow("late night drive, rainy sunday, gym")
        var trackCount = 25
        let naming = Label("", "caption", "dim").wrap().visible(false)
        let serverOnly = SwitchRow("Keep this one server-side only", isOn: false) { _ in }
        let syncNote = Label("", "caption", "dim").wrap()

        // Honest about the consequence: a FLAC playlist is not a small download.
        func refreshSyncNote() {
            let bytes = Int64(Double(trackCount * 240) * app.downloads.catalog.measuredBytesPerSecond)
            syncNote.text = app.playlistSync.isEnabled
                ? "Playlist sync is on, so a new \(trackCount)-track playlist would download about \(bytes.asFileSize). Leave this on to keep it on the server only."
                : "Playlist sync is off, so nothing is downloaded either way."
        }
        let count = SpinRow("Tracks", min: 10, max: 50, step: 5, value: 25) {
            trackCount = Int($0)
            refreshSyncNote()
        }
        let status = Label("", "caption", "warning").wrap()
        let asked = Box.vertical(spacing: 8)

        func refreshNaming() {
            let proposed = VibeTitle.sanitised(vibe.text)
            naming.isVisible = !vibe.text.isEmpty
            guard !vibe.text.isEmpty else { return }
            let taken = store.playlists.contains { $0.name.compare(proposed, options: .caseInsensitive) == .orderedSame }
            naming.text = "Will be called “\(proposed)”." + (taken ? " You already have one with that name, so a short suffix will be added." : "")
        }
        vibe.onChange { _ in refreshNaming() }
        var isSending = false
        let ask = ButtonRow("Ask Hermes", icon: "starred-symbolic", suggested: true) {
            let description = vibe.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty, !isSending else { return }
            isSending = true
            Task { @MainActor in
                let name = VibeTitle.unique(VibeTitle.sanitised(description), existing: store.playlists.map(\.name), requestID: UUID())
                if await hermes.startVibe(name: name, vibe: description, trackCount: trackCount) { vibe.text = "" }
                isSending = false
            }
        }

        let body = Box.vertical(spacing: 18) {
            PreferencesGroup("The Vibe", description: "Hermes searches the whole library — genre, year, length, whether you've ever played it — and creates the playlist on the server. It usually takes a few minutes.") {
                vibe
                count
            }
            naming
            PreferencesGroup { serverOnly }
            syncNote
            PreferencesGroup { ask }
            status
            asked
        }.margin(horizontal: 12, vertical: 24)

        body.observe {
            ask.isSensitive = hermes.isAvailable
            if !hermes.isAvailable {
                status.text = "Set the Hermes results address in Settings first."
            } else {
                status.text = hermes.lastError ?? ""
            }
            status.isVisible = !status.text.isEmpty
            refreshSyncNote()
            asked.removeAll()
            guard !hermes.vibes.isEmpty else { return }
            let group = PreferencesGroup("Asked For")
            for pending in hermes.vibes {
                let row = ActionRow(pending.name, subtitle: [pending.vibe, pending.note, pending.failure].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
                row.subtitleLines(4)
                if pending.isWaiting {
                    row.suffix(Spinner().size(16))
                } else if pending.failure != nil {
                    row.suffix(Icon("dialog-warning-symbolic").css("warning"))
                } else {
                    row.suffix(Icon("object-select-symbolic").css("accent"))
                }
                if let id = pending.playlistID {
                    row.activated { env.open(.playlist(PlaylistRef(id: id, name: pending.name))) }
                }
                row.suffix(Button(icon: "window-close-symbolic", "flat", "circular") { hermes.dismissVibe(pending.id) }.valign(GTK_ALIGN_CENTER).tooltip("Dismiss"))
                group.add(row)
            }
            asked.append(group)
        }
        // The phone refreshes on open and on pull; here the page checks again every
        // fifteen seconds while anything it asked for is still being made.
        let alive = body.liveness
        Task { @MainActor in
            await store.loadIfNeeded()
            await hermes.refreshVibes(playlists: store.playlists)
            while alive.isAlive {
                try? await Task.sleep(for: .seconds(15))
                guard alive.isAlive, hermes.isWatchingAnything else { continue }
                await store.load()
                await hermes.refreshVibes(playlists: store.playlists)
            }
        }
        return Page.make("Make a Playlist", content: body)
    }

    // MARK: - Library Health

    static func libraryHealth(_ env: Env) -> NavigationPage {
        let app = env.app
        let body = Box.vertical(spacing: 24).margin(horizontal: 12, vertical: 24)
        var report: HealthReport?
        let copy = Button(icon: "edit-copy-symbolic", "flat") {
            guard let report else { return }
            gdk_clipboard_set_text(gtk_widget_get_clipboard(body.widget), exportText(report))
            env.toast("Copied the report")
        }.tooltip("Copy Report").sensitive(false)

        func showAsk(_ failure: String? = nil) {
            body.removeAll()
            let check = ButtonRow("Check the Library", icon: "dialog-information-symbolic", suggested: true) { run() }
            check.isSensitive = app.hermes.isAvailable
            body.append(PreferencesGroup(description: "One query against Navidrome's own database — duplicates across your music folders, missing years, missing artwork, and the files that have to be streamed transcoded.") { check })
            if !app.hermes.isAvailable { body.append(Label("Set the Hermes results address in Settings first.", "caption", "dim")) }
            if let failure { body.append(Label(failure, "caption", "warning").wrap()) }
        }

        func run() {
            body.set {
                Box.horizontal(spacing: 8) {
                    Spinner().size(16)
                    Label("Asking Hermes…", "dim")
                }
            }
            let alive = body.liveness
            Task { @MainActor in
                let outcome = await app.hermes.ask(route: "music-health", fields: [:], as: HealthReport.self, timeout: 180)
                guard alive.isAlive else { return }
                switch outcome {
                case let .ok(result):
                    report = result
                    copy.isSensitive = true
                    show(result)
                case let .failed(message):
                    showAsk(message)
                case .pending:
                    showAsk("Hermes didn't answer in time.")
                }
            }
        }

        func show(_ report: HealthReport) {
            body.removeAll()
            let summary = PreferencesGroup("Library")
            if let total = report.totalTracks { summary.add(ActionRow("Tracks").suffix(Label("\(total)", "dim"))) }
            summary.add(ActionRow("Duplicated across folders").suffix(Label("\(report.duplicateGroups?.count ?? 0) shown", "dim")))
            if let missing = report.missingYear { summary.add(ActionRow("No year").suffix(Label("\(missing)", "dim"))) }
            if let missing = report.missingArtwork { summary.add(ActionRow("No cover art").suffix(Label("\(missing)", "dim"))) }
            body.append(summary)

            if let groups = report.duplicateGroups, !groups.isEmpty {
                let group = PreferencesGroup("Same Recording, Both Folders", description: "Navidrome mounts the music read-only, so nothing here can be deleted from the app. Play both and delete the worse one on the server.")
                for duplicate in groups {
                    let expander = ExpanderRow(duplicate.title, subtitle: duplicate.artist)
                    for copy in duplicate.copies {
                        let row = ActionRow(copy.path ?? copy.songID, subtitle: [copy.library, copy.suffix?.uppercased(), copy.sizeBytes.map { $0.asFileSize }].compactMap { $0 }.joined(separator: " · "))
                        row.titleLines(2)
                        row.prefix(Button(icon: "media-playback-start-symbolic", "flat", "circular") {
                            Task { @MainActor in
                                guard let song = try? await app.client.song(id: copy.songID) else { return }
                                env.play([song], source: "Library Health")
                            }
                        }.valign(GTK_ALIGN_CENTER))
                        expander.add(row)
                    }
                    group.add(expander)
                }
                body.append(group)
            }
            if let undecodable = report.undecodable, !undecodable.isEmpty {
                let group = PreferencesGroup("Converted on Playback", description: "The phone can't decode these containers, so it plays them through the server's transcoder. On Linux, FFmpeg plays them as they are.")
                for track in undecodable {
                    let row = ActionRow(track.path ?? track.songID, subtitle: [track.library, track.suffix?.uppercased()].compactMap { $0 }.joined(separator: " · "))
                    row.titleLines(2)
                    group.add(row)
                }
                body.append(group)
            }
        }
        showAsk()
        return Page.make("Library Health", content: body) { bar in
            bar.end(copy)
        }
    }

    private static func exportText(_ report: HealthReport) -> String {
        var lines = ["Music library health"]
        if let total = report.totalTracks { lines.append("Tracks: \(total)") }
        if let missing = report.missingYear { lines.append("No year: \(missing)") }
        if let missing = report.missingArtwork { lines.append("No cover art: \(missing)") }
        lines.append("")
        for group in report.duplicateGroups ?? [] {
            lines.append("\(group.artist ?? "Unknown") — \(group.title)")
            for copy in group.copies { lines.append("  \(copy.library ?? "?"): \(copy.path ?? copy.songID)") }
        }
        if let undecodable = report.undecodable, !undecodable.isEmpty {
            lines.append("")
            lines.append("Transcoded on playback:")
            for track in undecodable { lines.append("  \(track.path ?? track.songID)") }
        }
        return lines.joined(separator: "\n")
    }
}
