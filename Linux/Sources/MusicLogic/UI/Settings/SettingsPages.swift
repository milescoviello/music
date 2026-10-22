import CGtk
import Foundation

/// Settings: the server, the library switch, then a page for each area — the phone's
/// `SettingsView` and its children, as libadwaita preference pages.
@MainActor
enum SettingsPages {
    static func root(_ env: Env) -> NavigationPage {
        let app = env.app
        let page = PreferencesPage()

        if let credentials = app.credentials {
            let test = ActionRow("Test Connection")
            let result = Label("", "dim")
            let spinner = Spinner().size(16).visible(false)
            test.suffix(spinner).suffix(result)
            test.activated {
                spinner.isVisible = true
                result.text = ""
                Task { @MainActor in
                    do {
                        try await app.client.ping()
                        result.text = "OK"
                        result.setCSS("success", true)
                    } catch {
                        result.text = error.localizedDescription
                        result.setCSS("error", true)
                    }
                    spinner.isVisible = false
                }
            }
            page.add(PreferencesGroup("Server") {
                ActionRow("Address").suffix(Label(credentials.baseURL.absoluteString, "dim").selectable())
                ActionRow("User").suffix(Label(credentials.username, "dim"))
                test
            })
        }

        let library = PreferencesGroup("Library", description: "Applies to Home, Albums, Artists, Genres and Search. Playlists always show every library.")
        let scopeRow = ComboRow("Show", options: [], selected: 0) { index in
            let options = app.scope.options
            if options.indices.contains(index) { app.scope.scope = options[index] }
        }
        library.add(scopeRow)
        library.observe {
            library.isVisible = app.scope.isSwitchable
            let options = app.scope.options
            scopeRow.setOptions(options.map(\.shortName), selected: options.firstIndex(of: app.scope.scope) ?? 0)
        }
        page.add(library)

        func link(_ title: String, _ destination: Destination, summary: @escaping @MainActor () -> String) -> Widget {
            let row = ActionRow(title) { env.open(destination) }
            let value = Label("", "dim")
            row.suffix(value).chevron()
            value.observe { value.text = summary() }
            return row
        }
        page.add(PreferencesGroup {
            link("Playback", .audioSettings) {
                var parts: [String] = []
                if app.audio.loudnessLeveling { parts.append("Leveling") }
                if app.audio.sweetFades { parts.append("Sweet Fades") }
                if app.audio.equalizer { parts.append(app.audio.presetName) }
                return parts.isEmpty ? "Off" : parts.joined(separator: " · ")
            }
            link("Experience", .experienceSettings) { "Player, Home" }
            link("Streaming & Caching", .streamingSettings) {
                let policy = app.streaming.policy
                return policy.wifiQuality == policy.cellularQuality ? policy.wifiQuality.label
                    : "\(policy.wifiQuality.label) · \(policy.cellularQuality.label)"
            }
            link("Sonic Analysis", .sonicSettings) {
                guard let status = app.sonic.status else { return "Not connected" }
                return status.analysed < status.tracks ? "\(status.analysed) of \(status.tracks)" : "Ready"
            }
            link("Downloads", .downloads) {
                let count = app.downloads.catalog.entries.count
                return count == 0 ? "None" : "\(count) · \(app.downloads.catalog.totalBytes.asFileSize)"
            }
            link("Offline & Library", .offlineSettings) { app.playlistSync.isEnabled ? "Playlists kept offline" : "Manual" }
            link("Music Requests", .requestSettings) { app.requests.isConfigured ? "Connected" : "Not set up" }
            link("Remote Control", .remoteControl) { RemoteControlPage.summary }
        })
        page.add(PreferencesGroup {
            ActionRow("Diagnostics") { env.open(.diagnostics) }.chevron()
        })
        page.add(PreferencesGroup("About") {
            ActionRow("Version").suffix(Label(version, "dim"))
        })
        page.add(PreferencesGroup {
            ButtonRow("Sign Out", icon: "system-log-out-symbolic", destructive: true) {
                Dialogs.alert(
                    "Sign Out?",
                    body: "Downloads stay on this computer and play again when you sign back in.",
                    responses: [("cancel", "Cancel", ADW_RESPONSE_DEFAULT), ("out", "Sign Out", ADW_RESPONSE_DESTRUCTIVE)]
                ) { if $0 == "out" { Task { await app.signOut() } } }
            }
        })
        return preferencesPage("Settings", page)
    }

    /// The version the build was stamped with, or that it is a local build.
    static var version: String {
        let stamped = ProcessInfo.processInfo.environment["MUSIC_VERSION"] ?? BuildInfo.version
        return stamped.isEmpty ? "Local build" : stamped
    }

    static func preferencesPage(_ title: String, _ page: PreferencesPage) -> NavigationPage {
        NavigationPage(ToolbarView(content: page).top(HeaderBar()), title: title)
    }

    // MARK: - Playback

    static func audio(_ env: Env) -> NavigationPage {
        let audio = env.app.audio
        let autoplay = env.app.autoplay
        let page = PreferencesPage()

        let leveling = SwitchRow("Loudness Leveling", isOn: audio.loudnessLeveling) { audio.loudnessLeveling = $0 }
        let options = LoudnessLeveling.preampOptions
        let preamp = ComboRow("Preamp", options: options.map { value in
            let text = value > 0 ? "+\(Int(value)) dB" : "\(Int(value)) dB"
            return value == LoudnessLeveling.defaultPreamp ? "\(text) (Default)" : text
        }, selected: options.firstIndex(of: audio.preamp) ?? 0) { index in
            if options.indices.contains(index) { audio.preamp = options[index] }
        }
        let limiter = SwitchRow("Limiter", isOn: audio.limiter) { audio.limiter = $0 }
        page.add(PreferencesGroup("Loudness Leveling", description: """
        Plays every track at a consistent volume, using the ReplayGain your server reads from \
        each file. The preamp is how far above the −18 LUFS reference to aim; the limiter catches \
        any peak that pushes past full scale. Tracks with no gain data play as they are.
        """) {
            leveling
            preamp
            limiter
        })

        let sweet = SwitchRow("Sweet Fades", isOn: audio.sweetFades) { audio.sweetFades = $0 }
        let beats = SwitchRow("Beat-Matched Fades", isOn: audio.beatMatchedFades) { audio.beatMatchedFades = $0 }
        page.add(PreferencesGroup(description: """
        Crossfades between tracks, for as long as each pair's intro and outro allow — a long \
        fade-out gets a long overlap, an abrupt ending almost none. An album played in order is \
        always gapless. Beat-Matched Fades lines up the beats of two tracks with close tempos, the \
        way a DJ mixes, playing the incoming track at the outgoing one's tempo through the fade. It \
        needs the sonic service's analysis of both tracks; every other fade is a Sweet Fade.
        """) {
            sweet
            beats
        })

        let equalizer = ActionRow("Equalizer") { env.open(.equalizer) }
        let eqValue = Label("", "dim")
        equalizer.suffix(eqValue).chevron()
        page.add(PreferencesGroup(description: "Ten bands, with presets and your own saved curves.") { equalizer })

        let autoplaySwitch = SwitchRow("Autoplay", isOn: autoplay.isEnabled) { autoplay.isEnabled = $0 }
        let direction = ComboRow("Album Direction", options: ["Next Album", "Previous Album"],
                                 selected: autoplay.albumDirection == .previousAlbum ? 1 : 0) { index in
            autoplay.albumDirection = index == 1 ? .previousAlbum : .nextAlbum
        }
        page.add(PreferencesGroup("Autoplay", description: """
        When the queue is about to run out, keep going with whatever is chosen at the bottom of Up \
        Next — the next album, a radio, the same decade. Never with repeat on, and never for a \
        station or a mix, which keep themselves going.
        """) {
            autoplaySwitch
            direction
        })

        page.observe {
            preamp.isSensitive = audio.loudnessLeveling
            limiter.isSensitive = audio.loudnessLeveling
            beats.isSensitive = audio.sweetFades
            direction.isSensitive = autoplay.isEnabled
            eqValue.text = audio.equalizer ? audio.presetName : "Off"
        }
        return preferencesPage("Playback", page)
    }

    /// Ten faders, a preamp, presets: the phone's graphic equalizer, dragged with a mouse.
    static func equalizer(_ env: Env) -> NavigationPage {
        let audio = env.app.audio
        let toggle = SwitchRow("Equalizer", isOn: audio.equalizer) { audio.equalizer = $0 }
        let faders = Box.horizontal(spacing: 0).homogeneous()
        var scales: [Scale] = []
        var values: [Label] = []
        for index in 0..<Equalizer.bandCount {
            let scale = Scale(min: Double(Equalizer.gainRange.lowerBound), max: Double(Equalizer.gainRange.upperBound), step: 0.5,
                              value: Double(audio.bands[index]), orientation: GTK_ORIENTATION_VERTICAL)
            scale.inverted().size(height: 200).halign(GTK_ALIGN_CENTER)
            gtk_scale_add_mark(scale.widget.cast(), 0, GTK_POS_RIGHT, nil)
            // A gain is a position either side of zero, not a level filled from the bottom.
            gtk_scale_set_has_origin(scale.widget.cast(), 0)
            scale.onUserChange { value in audio.setGain(Float((value * 2).rounded() / 2), forBand: index) }
            // A double-click flattens a band, as a double-tap does on the phone.
            let click = gtk_gesture_click_new()!
            Signal.connect(click, "pressed", press: { count, _, _ in
                if count == 2 { audio.setGain(0, forBand: index) }
            })
            gtk_widget_add_controller(scale.widget, click.cast())
            let value = Label("0", "caption", "numeric").xalign(0.5)
            faders.append(Box.vertical(spacing: 6) {
                value
                scale
                Label(Equalizer.labels[index], "caption", "dim").xalign(0.5)
            })
            scales.append(scale)
            values.append(value)
        }
        let preamp = Scale(min: -12, max: 6, step: 0.5, value: Double(audio.equalizerPreamp))
        preamp.hexpand().onUserChange { audio.equalizerPreamp = Float($0) }
        let preampValue = Label("", "dim", "numeric")
        let presets = MenuButton(icon: "view-list-symbolic", label: audio.presetName, "pill") {
            var sections: [[Menu.Item]] = [[.choice("Preset", options: audio.allPresets.map { ($0.name, $0.name) }, selected: audio.presetName) { name in
                if let preset = audio.allPresets.first(where: { $0.name == name }) { audio.apply(preset) }
            }]]
            if !audio.customPresets.isEmpty {
                sections.append([.submenu("Delete Saved Preset", [audio.customPresets.map { preset in
                    .action(preset.name, destructive: true) { audio.deleteCustom(preset) }
                }])])
            }
            return Menu(sections)
        }
        let save = Button("Save…", "pill") {
            Dialogs.prompt("Save Preset", placeholder: "Name", confirm: "Save") { audio.saveCurrent(as: $0) }
        }
        let flat = Button("Flat", "pill") { audio.apply(.flat) }
        let controls = Box.vertical(spacing: 18) {
            faders
            Box.horizontal(spacing: 12) {
                Label("Preamp")
                preamp
                preampValue
            }
            Box.horizontal(spacing: 8) {
                presets
                Spacer()
                save
                flat
            }
            Label("Double-click a band to flatten it. A curve that boosts everywhere is better as a lower preamp.", "caption", "dim").wrap()
        }
        let body = Box.vertical(spacing: 24) {
            PreferencesGroup { toggle }
            controls
        }.margin(horizontal: 12, vertical: 24)

        body.observe {
            for index in 0..<Equalizer.bandCount {
                let gain = audio.bands[index]
                if abs(scales[index].value - Double(gain)) > 0.01 { scales[index].value = Double(gain) }
                let rounded = (gain * 2).rounded() / 2
                values[index].text = abs(rounded) < 0.01 ? "0" : (rounded > 0 ? "+" : "") + (rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded))
                values[index].setCSS("accent", abs(rounded) >= 0.01)
            }
            if abs(preamp.value - Double(audio.equalizerPreamp)) > 0.01 { preamp.value = Double(audio.equalizerPreamp) }
            let gain = audio.equalizerPreamp
            preampValue.text = (gain > 0 ? "+" : "") + String(format: "%.1f dB", gain)
            if let content = gtk_button_get_child(presets.widget.cast()) {
                adw_button_content_set_label(OpaquePointer(content), audio.presetName)
            }
            controls.isSensitive = audio.equalizer
            controls.opacity(audio.equalizer ? 1 : 0.4)
            save.isSensitive = !audio.isFlat
            flat.isSensitive = !audio.isFlat
        }
        return Page.make("Equalizer", content: body, clamp: 720)
    }

    // MARK: - Streaming

    static func streaming(_ env: Env) -> NavigationPage {
        let app = env.app
        let settings = app.streaming
        let cache = app.streamCache
        let page = PreferencesPage()

        let wifi = StreamQuality.wifiOptions
        let cellular = StreamQuality.cellularOptions
        page.add(PreferencesGroup("Quality", description: """
        Maximum plays the file as stored. A lower setting converts anything above it to MP3 on \
        the server; files already under it play as they are. A metered connection counts as \
        cellular.
        """) {
            ComboRow("Unmetered Streaming", options: wifi.map(\.label), selected: wifi.firstIndex(of: settings.policy.wifiQuality) ?? 0) { index in
                if wifi.indices.contains(index) { settings.policy.wifiQuality = wifi[index] }
            }
            ComboRow("Metered Streaming", options: cellular.map(\.label), selected: cellular.firstIndex(of: settings.policy.cellularQuality) ?? 0) { index in
                if cellular.indices.contains(index) { settings.policy.cellularQuality = cellular[index] }
            }
        })

        let ahead = StreamingPolicy.cacheAheadOptions
        let sizes = StreamingPolicy.cacheSizeOptions
        func aheadLabel(_ count: Int) -> String { count == 0 ? "Only Next Track" : "\(count) Tracks" }
        let inUse = ActionRow("In Use")
        let inUseValue = Label("", "dim")
        let fetching = Spinner().size(16).visible(false)
        inUse.suffix(fetching).suffix(inUseValue)
        let delete = ButtonRow("Delete Caches", icon: "user-trash-symbolic", destructive: true) {
            Dialogs.alert(
                "Delete \(cache.totalBytes.asFileSize) of cached tracks?",
                body: "Downloads are not affected.",
                responses: [("cancel", "Cancel", ADW_RESPONSE_DEFAULT), ("delete", "Delete Caches", ADW_RESPONSE_DESTRUCTIVE)]
            ) { if $0 == "delete" { cache.removeAll() } }
        }
        page.add(PreferencesGroup("Caching", description: """
        Tracks coming up in the queue are fetched whole before they play, so a dropped connection \
        does not stop the music, converted streams can be scrubbed, and Sweet Fades can measure \
        each fade instead of guessing. Played tracks stay until the space is needed. Downloads are \
        never counted or touched.
        """) {
            ComboRow("Unmetered Caching", options: ahead.map(aheadLabel), selected: ahead.firstIndex(of: settings.policy.wifiCacheAhead) ?? 0) { index in
                if ahead.indices.contains(index) { settings.policy.wifiCacheAhead = ahead[index] }
            }
            ComboRow("Metered Caching", options: ahead.map(aheadLabel), selected: ahead.firstIndex(of: settings.policy.cellularCacheAhead) ?? 0) { index in
                if ahead.indices.contains(index) { settings.policy.cellularCacheAhead = ahead[index] }
            }
            ComboRow("Cache Size", options: sizes.map { Int64($0 * 1_024 * 1_024).asFileSize }, selected: sizes.firstIndex(of: settings.policy.cacheMegabytes) ?? 0) { index in
                if sizes.indices.contains(index) { settings.policy.cacheMegabytes = sizes[index] }
            }
            inUse
            delete
        })

        let prefer = PreferDownloads.allCases
        page.add(PreferencesGroup(description: "When to play a downloaded copy instead of streaming. With no network a download always plays, whatever this says.") {
            ComboRow("Prefer Downloaded Media", options: prefer.map(\.label), selected: prefer.firstIndex(of: settings.policy.preferDownloads) ?? 0) { index in
                if prefer.indices.contains(index) { settings.policy.preferDownloads = prefer[index] }
            }
        })
        let network = ActionRow("Network")
        let networkValue = Label("", "dim")
        network.suffix(networkValue)
        page.add(PreferencesGroup { network })

        page.observe {
            inUseValue.text = cache.totalBytes.asFileSize
            fetching.isVisible = cache.fetchingSongID != nil
            delete.isSensitive = cache.totalBytes > 0
            switch app.reachability.network {
            case .wifi: networkValue.text = "Unmetered"
            case .cellular: networkValue.text = "Metered"
            case .offline: networkValue.text = "Offline"
            }
        }
        return preferencesPage("Streaming & Caching", page)
    }

    // MARK: - Experience

    static func experience(_ env: Env) -> NavigationPage {
        let app = env.app
        let settings = app.playerSettings
        let page = PreferencesPage()
        let styles = PlayerSettings.SeekbarStyle.allCases
        let backgrounds = PlayerSettings.Background.allCases
        let skips = PlayerSettings.skipOptions
        page.add(PreferencesGroup("Player", description: """
        Show Full Player opens the player whenever something starts playing. The Smooth and Bars \
        seekbars draw the track's loudness. Keep Screen On stops the screen blanking while the app \
        is open.
        """) {
            SwitchRow("Show Full Player", isOn: settings.opensPlayerOnPlay) { settings.opensPlayerOnPlay = $0 }
            ComboRow("Seekbar Style", options: styles.map(\.title), selected: styles.firstIndex(of: settings.seekbarStyle) ?? 0) { index in
                if styles.indices.contains(index) { settings.seekbarStyle = styles[index] }
            }
            ComboRow("Background", options: backgrounds.map(\.title), selected: backgrounds.firstIndex(of: settings.background) ?? 0) { index in
                if backgrounds.indices.contains(index) { settings.background = backgrounds[index] }
            }
            SwitchRow("Keep Screen On", isOn: app.screenAwake.isEnabled) { app.screenAwake.isEnabled = $0 }
        })
        let back = ComboRow("Skip Backwards", options: skips.map { "\($0) sec" }, selected: skips.firstIndex(of: settings.skipBackSeconds) ?? 0) { index in
            if skips.indices.contains(index) { settings.skipBackSeconds = skips[index] }
        }
        let forward = ComboRow("Skip Forwards", options: skips.map { "\($0) sec" }, selected: skips.firstIndex(of: settings.skipForwardSeconds) ?? 0) { index in
            if skips.indices.contains(index) { settings.skipForwardSeconds = skips[index] }
        }
        page.add(PreferencesGroup("Quick Skip", description: "Buttons either side of the transport that jump within the track — for mixes, live sets and anything long. Playback speed is in the player's menu.") {
            SwitchRow("Music Quick Skip", isOn: settings.showsSkipButtons) { settings.showsSkipButtons = $0 }
            back
            forward
        })
        page.add(PreferencesGroup("Home Screen", description: "Choose which shelves Home shows, and in what order — from Home's own menu.") {
            ButtonRow("Reset Home Screen", icon: "edit-undo-symbolic", destructive: true) {
                UserDefaults.standard.removeObject(forKey: "home.layout")
            }
        })
        page.observe {
            back.isSensitive = settings.showsSkipButtons
            forward.isSensitive = settings.showsSkipButtons
        }
        return preferencesPage("Experience", page)
    }

    // MARK: - Sonic

    static func sonic(_ env: Env) -> NavigationPage {
        let sonic = env.app.sonic
        let page = PreferencesPage()
        let status = PreferencesGroup("Status", description: """
        Sonically Similar tracks, albums and artists, Sonic Adventure, the sonic Guest DJs, track \
        radio and mood stations come from this service, which analyses every track the way Plex \
        does. Until a track has been analysed, those features use your server's similar songs \
        instead.
        """)
        let rows = Box.vertical(spacing: 0)
        status.add(rows)
        let check = ButtonRow("Check Now", icon: "view-refresh-symbolic") {
            Task { await sonic.refreshStatus(force: true) }
        }
        status.add(check)
        page.add(status)
        status.observe {
            rows.removeAll()
            if let current = sonic.status {
                rows.append(ActionRow("Analysed").suffix(Label("\(current.analysed) of \(current.tracks)", "dim")))
                if current.analysed < current.tracks {
                    let bar = ProgressBar()
                    bar.fraction = Double(current.analysed) / Double(max(current.tracks, 1))
                    rows.append(bar.margin(12))
                }
                rows.append(ActionRow("Now").suffix(Label(current.analysing ? "Analysing new music" : "Up to date", "dim")))
                rows.append(ActionRow("Model").suffix(Label(current.model, "dim")))
            } else {
                let row = ActionRow("Status")
                row.suffix(Label("Not connected", "dim"))
                if let error = sonic.lastError { row.subtitle = error }
                rows.append(row)
            }
        }
        let address = EntryRow("Address", text: sonic.configuration.baseURL.absoluteString)
        address.inputPurpose(GTK_INPUT_PURPOSE_URL)
        let token = EntryRow("Token (optional)", text: sonic.configuration.token ?? "", password: true)
        page.add(PreferencesGroup("Service") {
            address
            token
            ButtonRow("Save", icon: "document-save-symbolic", suggested: true) {
                guard let url = URL(string: address.text.trimmingCharacters(in: .whitespaces)), url.scheme != nil else { return }
                sonic.configuration = SonicClient.Configuration(baseURL: url, token: token.text.isEmpty ? nil : token.text)
                Task { await sonic.refreshStatus(force: true) }
            }
        })
        Task { await sonic.refreshStatus(force: true) }
        return preferencesPage("Sonic Analysis", page)
    }

    // MARK: - Offline & Library

    static func offline(_ env: Env) -> NavigationPage {
        let app = env.app
        let sync = app.playlistSync
        let playlists = app.playlistStore
        let page = PreferencesPage()

        let keep = SwitchRow("Keep Playlists Offline", isOn: sync.isEnabled) { on in
            sync.isEnabled = on
            if on { Task { await sync.sync() } }
        }
        let wifiOnly = SwitchRow("Unmetered Only", isOn: sync.isWiFiOnly) { sync.isWiFiOnly = $0 }
        let automatic = PreferencesGroup("Automatic Downloads") {
            keep
            wifiOnly
        }
        page.add(automatic)

        let list = PreferencesGroup("Playlists")
        let rows = Box.vertical(spacing: 0)
        list.add(rows)
        let summary = Label("", "caption", "dim")
        let syncing = Spinner().size(16).visible(false)
        list.suffix(Box.horizontal(spacing: 6) {
            syncing
            summary
        })
        page.add(list)
        let syncNow = ButtonRow("Sync Now", icon: "view-refresh-symbolic") { Task { await sync.sync() } }
        let onDisk = ActionRow("On This Computer")
        let onDiskValue = Label("", "dim")
        onDisk.suffix(onDiskValue)
        let actions = PreferencesGroup {
            syncNow
            onDisk
        }
        page.add(actions)

        page.observe {
            wifiOnly.isVisible = sync.isEnabled
            automatic.descriptionText = sync.isEnabled
                ? "The playlists switched on below are downloaded at full quality and kept up to date as you add to them. Estimated \(sync.estimatedSize(for: playlists.playlists, bytesPerSecond: app.downloads.catalog.measuredBytesPerSecond).asFileSize) for those selected. Nothing is ever deleted automatically."
                : "Downloads stay manual: use the arrow on an album or playlist."
            list.isVisible = sync.isEnabled && !playlists.playlists.isEmpty
            actions.isVisible = sync.isEnabled && !playlists.playlists.isEmpty
            syncing.isVisible = sync.isSyncing
            summary.text = sync.isSyncing ? "" : (sync.lastSummary ?? "")
            syncNow.isSensitive = !sync.isSyncing
            onDiskValue.text = "\(app.downloads.catalog.entries.count) · \(app.downloads.catalog.totalBytes.asFileSize)"
        }
        rows.observe {
            let all = playlists.playlists
            _ = sync.includedIDs
            rows.removeAll()
            for playlist in all {
                var subtitle: String?
                if let count = playlist.songCount, let duration = playlist.duration {
                    subtitle = "\(count) songs · about \(Int64(duration * 1_000_000).asFileSize)"
                }
                rows.append(SwitchRow(playlist.name, subtitle: subtitle, isOn: sync.isIncluded(playlist)) { on in
                    sync.setIncluded(on, for: playlist)
                })
            }
        }

        let rescan = ActionRow("Rescan Library")
        let scanning = Spinner().size(16).visible(false)
        rescan.suffix(scanning)
        let tracks = ActionRow("Tracks")
        let tracksValue = Label("", "dim")
        tracks.suffix(tracksValue)
        let lastScan = ActionRow("Last Scan")
        let lastScanValue = Label("", "dim")
        lastScan.suffix(lastScanValue)
        page.add(PreferencesGroup("Library", description: "Navidrome only notices new files when it scans. Requested music can sit on the server unseen until then, so this is how you make it show up now.") {
            rescan
            tracks
            lastScan
        })
        let alive = rescan.liveness
        func show(_ scan: ScanStatus?) {
            guard alive.isAlive else { return }
            tracksValue.text = scan?.count.map(String.init) ?? "—"
            lastScanValue.text = scan?.lastScanAt?.formatted(date: .abbreviated, time: .shortened) ?? "—"
            scanning.isVisible = scan?.scanning == true
            rescan.isSensitive = scan?.scanning != true
        }
        rescan.activated {
            scanning.isVisible = true
            rescan.isSensitive = false
            Task { @MainActor in
                var scan = await app.rescanLibrary()
                show(scan)
                while scan?.scanning == true {
                    try? await Task.sleep(for: .seconds(3))
                    scan = try? await app.client.scanStatus()
                    show(scan)
                }
                await app.refreshRequests()
            }
        }
        Task { @MainActor in
            await playlists.loadIfNeeded()
            show(try? await app.client.scanStatus())
        }
        return preferencesPage("Offline & Library", page)
    }

    // MARK: - Diagnostics

    static func diagnostics(_ env: Env) -> NavigationPage {
        let app = env.app
        let body = Box.vertical(spacing: 24).margin(horizontal: 12, vertical: 24)
        func reload() {
            Task { @MainActor in
                let pending = await app.outbox.summary()
                let lines = await Diagnostics.shared.recent()
                let export = await Diagnostics.shared.export()
                fill(pending: pending, lines: lines, export: export)
            }
        }
        func label(_ kind: ServerOutbox.Kind) -> String {
            switch kind {
            case .scrobble: return "Plays"
            case .star: return "Favourites added"
            case .unstar: return "Favourites removed"
            case .rating: return "Ratings"
            case .bookmark: return "Resume positions"
            }
        }
        func fill(pending: [ServerOutbox.Kind: Int], lines: [Diagnostics.Line], export: String) {
            body.removeAll()
            let waiting = PreferencesGroup("Pending", description: "Plays, stars and ratings made while offline wait here and are sent when the server is reachable. They carry the time they actually happened, so a late one is still recorded correctly.")
            if pending.isEmpty {
                waiting.add(ActionRow("Waiting to sync").suffix(Label("Nothing", "dim")))
            } else {
                for kind in pending.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                    waiting.add(ActionRow(label(kind)).suffix(Label("\(pending[kind] ?? 0)", "dim")))
                }
            }
            let flush = ButtonRow("Sync Now", icon: "view-refresh-symbolic") {
                Task { @MainActor in
                    await app.flushOutbox()
                    reload()
                }
            }
            flush.isSensitive = !pending.isEmpty
            waiting.add(flush)
            body.append(waiting)

            let downloads = app.downloads
            let sync = PreferencesGroup("Sync")
            sync.add(ActionRow("Queue Uploaded").suffix(Label(app.queueSync.lastPushedAt?.formatted(date: .omitted, time: .shortened) ?? "Not yet", "dim")))
            sync.add(ActionRow("Downloads").suffix(Label("\(downloads.catalog.entries.count)", "dim")))
            if !downloads.progress.isEmpty {
                sync.add(ActionRow("Downloading").suffix(Label("\(downloads.progress.count)", "dim")))
            }
            let stalled = downloads.catalog.pending.keys.filter { downloads.progress[$0] == nil }.count
            if stalled > 0 { sync.add(ActionRow("Stalled Downloads").suffix(Label("\(stalled)", "dim"))) }
            body.append(sync)

            let mixes = PreferencesGroup(description: "Mixes are built once a day. Rebuilding logs how many candidates each one found.")
            mixes.add(ActionRow("Daily Mixes").suffix(Label("\(app.mixes.mixes.count) built", "dim")))
            mixes.add(ButtonRow("Rebuild Daily Mixes", icon: "view-refresh-symbolic") {
                Task { @MainActor in
                    app.mixes.forgetToday()
                    await app.mixes.loadAndWait(appState: app, scope: app.scope.scope)
                    reload()
                }
            })
            body.append(mixes)

            let failures = PreferencesGroup("Recent Failures", description: "Request URLs are stripped of their query, which is where the auth token lives.")
            if lines.isEmpty {
                failures.add(ActionRow("Nothing has failed."))
            } else {
                failures.suffix(Button("Copy", "flat") {
                    gdk_clipboard_set_text(gtk_widget_get_clipboard(body.widget), export)
                    env.toast("Copied the log")
                })
                for line in lines {
                    let row = ActionRow(line.message, subtitle: "\(line.area) · \(line.at.formatted(date: .omitted, time: .standard))")
                    row.titleLines(0)
                    failures.add(row)
                }
            }
            body.append(failures)
            if !lines.isEmpty {
                body.append(PreferencesGroup {
                    ButtonRow("Clear Log", icon: "user-trash-symbolic", destructive: true) {
                        Task { @MainActor in
                            await Diagnostics.shared.clear()
                            reload()
                        }
                    }
                })
            }
        }
        reload()
        return Page.make("Diagnostics", content: body) { bar in
            bar.end(Button(icon: "view-refresh-symbolic", "flat") { reload() }.tooltip("Refresh"))
        }
    }
}

/// Stamped by the build script; empty for a plain `swift build`.
enum BuildInfo {
    static let version = ""
}
