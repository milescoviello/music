import CGtk
import Foundation

/// The full player: the phone's `NowPlayingView`, as the sheet that slides up over the
/// window. Artwork, queue, lyrics or visualiser above; the title, what is actually being
/// heard, the seekbar and the transport below; the cover's colour behind it all.
@MainActor
final class NowPlaying {
    enum Mode: String {
        case artwork, queue, lyrics, visualizer
    }

    let root: Overlay
    private let app: AppState
    private let env: Env
    private let modes = Stack(transition: GTK_STACK_TRANSITION_TYPE_CROSSFADE)
    private var mode: Mode = .artwork
    private var modeButtons: [Mode: Button] = [:]
    private let ratingRow = Box.horizontal(spacing: 2)

    init(app: AppState, shell: Shell) {
        self.app = app
        let navigation = Navigation(app: app, shell: shell)
        env = navigation.env
        let player = app.player

        let backdrop = Backdrop(app: app)
        root = Overlay(backdrop.root)
        root.css("now-playing")

        let artwork = ArtworkView(app, size: .full, side: nil, shape: .player)
        // Square whatever space it is given: the frame keeps the ratio, and the margins sit
        // outside it so they do not squeeze one side.
        let artworkFrame = Widget(gtk_aspect_frame_new(0.5, 0.5, 1, 0)!)
        gtk_aspect_frame_set_child(artworkFrame.widget.cast(), artwork.root.widget)
        artworkFrame.hexpand().vexpand().margin(horizontal: 32, vertical: 8)
        modes.add(artworkFrame, name: Mode.artwork.rawValue)
        modes.add(QueuePane(env: env).root, name: Mode.queue.rawValue)
        modes.add(LyricsPane(env: env).root, name: Mode.lyrics.rawValue)
        modes.add(VisualizerPane(app: app).root, name: Mode.visualizer.rawValue)
        modes.vexpand()

        let controls = Box.vertical(spacing: 6) {}
        controls.append(metadata())
        controls.append(detailLine())
        controls.append(ratingRow.halign(GTK_ALIGN_CENTER))
        controls.append(resumeStrip())
        controls.append(SeekBar(app: app).root)
        controls.append(transport())
        controls.append(volumeRow())
        controls.append(modeRow())

        let body = Box.vertical(spacing: 8) {
            topBar()
            modes
            Clamp(controls.margin(horizontal: 24, vertical: 12), maximum: 640, threshold: 480)
        }
        root.add(body)
        root.keep(self)

        root.observe { artwork.show(player.currentSong?.coverArt, fallback: player.currentSong?.album) }
        let reference = WeakReference(self)
        root.observe {
            guard let song = player.currentSong else { return }
            let rating = app.userState.rating(id: song.id, serverValue: song.userRating)
            reference.value?.refreshRating(songID: song.id, rating: rating)
        }
        select(.artwork)
    }

    private func select(_ target: Mode) {
        mode = target
        modes.visibleName = target.rawValue
        for (candidate, button) in modeButtons { button.setCSS("selected", candidate == target) }
        ratingRow.isVisible = target == .artwork
    }

    // MARK: - Top

    private func topBar() -> Widget {
        let player = app.player
        let source = Label("", "source-title").xalign(0.5).ellipsize()
        source.observe {
            let described = player.queue.sourceDescription
            source.text = described.isEmpty ? "Queue" : described
        }
        let close = Button(icon: "go-down-symbolic", "flat", "circular") { [app] in app.navigator.showsPlayer = false }
        close.tooltip("Close Player")
        let menu = MenuButton(icon: "view-more-symbolic", "flat", "circular") { [weak self] in
            self?.menu() ?? Menu([])
        }
        return Box.horizontal(spacing: 12) {
            close
            Box.vertical(spacing: 0) {
                Label("PLAYING FROM", "source-caption").xalign(0.5)
                source
            }.hexpand()
            menu
        }.margins(top: 20, bottom: 4, start: 12, end: 12)
    }

    private func menu() -> Menu {
        guard let song = app.player.currentSong else { return Menu([]) }
        let app = app
        var sections = Menus.song(env, song, showsNavigation: false, showsRating: false).sections
        var jumps = Menus.navigationItems(env, song, jumps: true)
        jumps.append(.action("Show Similar Tracks") { [env] in SimilarTracks.present(env, song: song) })
        jumps.append(.action("Sonic Adventure…") { app.navigator.open(.sonicAdventure(song)) })
        sections.append(jumps)

        let guest = app.guestDJ
        let speed = app.player.speed
        let timer = app.sleepTimer
        var sleep: [Menu.Item] = []
        if timer.isArmed { sleep.append(.action("Turn Off") { timer.cancel() }) }
        for minutes in SleepTimer.minuteOptions {
            sleep.append(.action(minutes == 60 ? "1 Hour" : "\(minutes) Minutes") { timer.arm(minutes: minutes) })
        }
        sleep.append(.action("End of Track") { timer.armEndOfTrack() })
        if let album = albumPlaying { sleep.append(.action("End of Album") { timer.armEndOfAlbum(albumID: album) }) }

        sections.append([
            .choice(
                guest.dj.map { "Guest DJ — \($0.name)" } ?? "Guest DJ",
                options: [("off", "Off")] + GuestDJ.allCases.map { ($0.rawValue, $0.name) },
                selected: guest.dj?.rawValue ?? "off"
            ) { id in guest.setDJ(GuestDJ(rawValue: id)) },
            .choice(
                speed == 1 ? "Playback Speed" : String(format: "Playback Speed — %.1f×", speed),
                options: stride(from: 5, through: 20, by: 1).map { (String($0), String(format: "%.1f×", Double($0) / 10)) },
                selected: String(Int((speed * 10).rounded()))
            ) { id in app.player.setSpeed((Float(id) ?? 10) / 10) },
            .toggle("Keep Screen On", isOn: app.screenAwake.isEnabled) { app.screenAwake.isEnabled = $0 },
            .submenu(timer.label.map { "Sleep Timer — \($0)" } ?? "Sleep Timer", [sleep]),
        ])
        return Menu(sections)
    }

    /// End of Album is offered only when everything up next is from one album.
    private var albumPlaying: String? {
        let queue = app.player.queue
        guard let album = queue.current?.albumId, queue.hasUpNext, queue.upNextCount < 200,
              queue.upNext.allSatisfy({ $0.albumId == album })
        else { return nil }
        return album
    }

    // MARK: - Title block

    private func metadata() -> Widget {
        let player = app.player
        let title = Label("", "song-title").ellipsize()
        let artist = Button("", "flat", "link-button", "song-artist")
        let album = Button("", "flat", "link-button", "song-album")
        for button in [artist, album] {
            gtk_widget_set_halign(button.widget, GTK_ALIGN_START)
            if let label = gtk_button_get_child(button.widget.cast()) {
                gtk_label_set_ellipsize(OpaquePointer(label), PANGO_ELLIPSIZE_END)
            }
        }
        let heart = Button(icon: "music-heart-symbolic", "flat", "circular")
        heart.valign(GTK_ALIGN_CENTER)

        let app = app
        artist.onClicked {
            guard let song = player.currentSong, let id = song.artistId, let name = song.artist else { return }
            app.navigator.open(.artist(ArtistRef(id: id, name: name)))
        }
        album.onClicked {
            guard let song = player.currentSong, let id = song.albumId, let name = song.album else { return }
            app.navigator.open(.album(AlbumRef(id: id, name: name, artist: song.artist, coverArt: song.coverArt)))
        }
        heart.onClicked {
            guard let song = player.currentSong else { return }
            app.userState.toggleStar(song)
        }

        let box = Box.horizontal(spacing: 12) {
            Box.vertical(spacing: 0) {
                title
                artist
                album
            }.hexpand()
            heart
        }
        box.observe {
            guard let song = player.currentSong else { return }
            title.text = song.title
            artist.label = song.artist ?? ""
            album.label = song.album.map { "\($0)  ›" } ?? ""
            artist.isVisible = song.artist != nil
            album.isVisible = song.album != nil
            let starred = app.userState.isStarred(song)
            heart.setCSS("accent", starred)
            heart.opacity(starred ? 1 : 0.6)
            heart.tooltip(starred ? "Remove Favourite" : "Favourite")
        }
        return box
    }

    /// What is actually being heard, and where in the queue: every part left out when
    /// unknown rather than shown as a placeholder.
    private func detailLine() -> Widget {
        let label = Label("", "detail-line").ellipsize()
        let app = app
        label.observe {
            let player = app.player
            guard let song = player.currentSong else { return }
            var parts: [String] = []
            if app.downloads.isDownloaded(song.id) { parts.append("Downloaded") }
            parts.append(Self.quality(app, song))
            if let count = song.playCount, count > 0 { parts.append("\(count) \(count == 1 ? "play" : "plays")") }
            if player.queue.order.count > 1 { parts.append("\(player.queue.position + 1) of \(player.queue.order.count)") }
            if let dj = app.guestDJ.dj { parts.append("✦ \(dj.name)") }
            if player.speed != 1 { parts.append(String(format: "%.1f×", player.speed)) }
            if let timer = app.sleepTimer.label { parts.append("☾ \(timer)") }
            if app.screenAwake.isEnabled { parts.append("Screen on") }
            label.text = parts.joined(separator: " · ")
        }
        return label
    }

    /// "FLAC · 24/96", "MP3 · 320 kbps": for lossless the depth and rate are the useful
    /// numbers; for a converted stream, that it was converted.
    static func quality(_ app: AppState, _ song: Song) -> String {
        if !app.downloads.isDownloaded(song.id) {
            let variant = app.streaming.policy.variant(for: song, on: app.reachability.network)
            if case let .mp3(kbps) = variant, app.streamCache.index.entry(for: song.id, satisfying: .original) == nil {
                return "MP3 · \(kbps) kbps · converted"
            }
        }
        var parts: [String] = []
        if let suffix = song.suffix { parts.append(suffix.uppercased()) }
        let lossless = ["flac", "wav", "aiff", "aif", "alac", "wv", "ape"].contains(song.suffix?.lowercased() ?? "")
        func kilohertz(_ hertz: Int) -> String {
            let value = Double(hertz) / 1000
            return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        }
        if lossless {
            if let depth = song.bitDepth, let rate = song.samplingRate, rate > 0 {
                parts.append("\(depth)/\(kilohertz(rate))")
            } else if let rate = song.samplingRate, rate > 0 {
                parts.append("\(kilohertz(rate)) kHz")
            }
        } else if let rate = song.bitRate, rate > 0 {
            parts.append("\(rate) kbps")
        }
        if song.channelCount == 1 { parts.append("mono") }
        return parts.isEmpty ? "Streaming" : parts.joined(separator: " · ")
    }

    private func refreshRating(songID: String, rating: Int) {
        ratingRow.removeAll()
        let user = app.userState
        for value in 1...5 {
            let star = Button(icon: value <= rating ? "starred-symbolic" : "non-starred-symbolic", "flat", "star")
            star.setCSS("filled", value <= rating)
            star.tooltip("\(value) Star\(value == 1 ? "" : "s")")
            star.onClicked { user.setRating(id: songID, to: value, current: rating) }
            ratingRow.append(star)
        }
    }

    /// Shown for a few seconds when playback started part-way through a long track, with
    /// the way back to the start.
    private func resumeStrip() -> Widget {
        let player = app.player
        let label = Label("", "caption")
        let strip = Box.horizontal(spacing: 10) {
            Icon("document-open-recent-symbolic", size: 14)
            label
            Button("Start Over", "flat", "caption-heading") { player.startOver() }
        }.css("resume-strip").halign(GTK_ALIGN_CENTER)
        let revealer = Revealer(strip, transition: GTK_REVEALER_TRANSITION_TYPE_CROSSFADE)
        revealer.observe {
            guard let notice = player.resumeNotice, notice.songID == player.currentSong?.id else {
                revealer.isRevealed = false
                return
            }
            label.text = "Resumed from \(Int(notice.seconds).asDuration)"
            revealer.isRevealed = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                if player.resumeNotice == notice { player.resumeNotice = nil }
            }
        }
        return revealer
    }

    // MARK: - Controls

    private func transport() -> Widget {
        let player = app.player
        let settings = app.playerSettings
        let shuffle = Button(icon: "media-playlist-shuffle-symbolic", "flat", "circular") { player.toggleShuffle() }
        let back = Button(icon: "media-seek-backward-symbolic", "flat", "circular") {
            player.skip(by: -Double(settings.skipBackSeconds))
        }
        let previous = Button(icon: "media-skip-backward-symbolic", "flat", "circular") { player.previous() }
        let play = Button(icon: "media-playback-start-symbolic", "play") { player.togglePlayPause() }
        let next = Button(icon: "media-skip-forward-symbolic", "flat", "circular") { player.next() }
        let forward = Button(icon: "media-seek-forward-symbolic", "flat", "circular") {
            player.skip(by: Double(settings.skipForwardSeconds))
        }
        let repeatButton = Button(icon: "media-playlist-repeat-symbolic", "flat", "circular") { player.cycleRepeat() }
        previous.tooltip("Previous")
        next.tooltip("Next")
        play.valign(GTK_ALIGN_CENTER)

        let row = Box.horizontal(spacing: 16) {
            shuffle
            back
            previous
            play
            next
            forward
            repeatButton
        }.css("transport").halign(GTK_ALIGN_CENTER)
        for button in [shuffle, back, previous, next, forward, repeatButton] { button.valign(GTK_ALIGN_CENTER) }

        row.observe {
            play.icon = player.isPlaying ? "media-playback-pause-symbolic" : "media-playback-start-symbolic"
            play.tooltip(player.isPlaying ? "Pause" : "Play")
            shuffle.setCSS("active", player.queue.isShuffled)
            shuffle.tooltip(player.queue.isShuffled ? "Shuffle On" : "Shuffle Off")
            let mode = player.queue.repeatMode
            repeatButton.icon = Icons.named(mode.symbol)
            repeatButton.setCSS("active", mode != .off)
            repeatButton.tooltip("Repeat: \(mode.rawValue.capitalized)")
            back.isVisible = settings.showsSkipButtons
            forward.isVisible = settings.showsSkipButtons
            back.tooltip("Back \(settings.skipBackSeconds) Seconds")
            forward.tooltip("Forward \(settings.skipForwardSeconds) Seconds")
        }
        return row
    }

    /// The stream's own volume, the same one the desktop's mixer shows for the app.
    private func volumeRow() -> Widget {
        let volume = OutputVolume.shared
        let scale = Scale(min: 0, max: 1, step: 0.01, value: volume.level)
        scale.hexpand().onUserChange { volume.level = min(max($0, 0), 1) }
        scale.observe { if abs(scale.value - volume.level) > 0.005 { scale.value = volume.level } }
        return Box.horizontal(spacing: 10) {
            Icon("audio-volume-low-symbolic", size: 14).opacity(0.5)
            scale
            Icon("audio-volume-high-symbolic", size: 14).opacity(0.5)
        }
    }

    private func modeRow() -> Widget {
        let row = Box.horizontal(spacing: 0).homogeneous()
        let entries: [(Mode, String, String)] = [
            (.lyrics, "format-justify-left-symbolic", "Lyrics"),
            (.artwork, "image-x-generic-symbolic", "Artwork"),
            (.visualizer, "music-equalizer-symbolic", "Visualizer"),
            (.queue, "view-list-symbolic", "Queue"),
        ]
        for (target, icon, name) in entries {
            let button = Button(icon: icon, "flat", "mode-button") { [weak self] in
                guard let self else { return }
                select(mode == target ? .artwork : target)
            }
            button.tooltip(name).halign(GTK_ALIGN_CENTER)
            modeButtons[target] = button
            row.append(button)
        }
        return row
    }
}

/// The cover's colour behind the player: blurred artwork, or its average colour flat or
/// as a gradient into black — Plexamp's Ultrablur, Flat and Smooth.
@MainActor
final class Backdrop {
    let root: Overlay
    private var colour = ArtworkStore.RGB(red: 0.12, green: 0.12, blue: 0.12)

    init(app: AppState) {
        let picture = Picture()
        picture.css("backdrop-blur")
        let reference = WeakReference<Backdrop>(nil)
        let wash = DrawingArea { cairo, width, height in
            guard let backdrop = reference.value else { return }
            let colour = backdrop.colour
            switch app.playerSettings.background {
            case .ultrablur:
                cairo.color(red: 0, green: 0, blue: 0, alpha: 0.45)
                cairo.rectangle(0, 0, width, height)
                cairo.fill()
            case .flat:
                cairo.color(colour)
                cairo.rectangle(0, 0, width, height)
                cairo.fill()
            case .smooth:
                cairo.verticalGradient(height: height, [
                    (0, colour, 1),
                    (0.5, colour, 0.55),
                    (1, ArtworkStore.RGB(red: 0, green: 0, blue: 0), 1),
                ])
                cairo.rectangle(0, 0, width, height)
                cairo.fill()
            }
        }
        wash.hexpand().vexpand()
        root = Overlay(picture)
        root.add(wash)
        reference.value = self
        root.keep(self)

        root.observe {
            let cover = app.player.currentSong?.coverArt
            let style = app.playerSettings.background
            picture.isVisible = style == .ultrablur
            Task { @MainActor in
                let full = style == .ultrablur ? await app.artwork.image(for: cover, size: .card) : nil
                let thumb = await app.artwork.image(for: cover, size: .thumb)
                guard let backdrop = reference.value, app.player.currentSong?.coverArt == cover else { return }
                picture.set(full)
                if let thumb { backdrop.colour = Self.average(thumb) }
                wash.redraw()
            }
        }
    }

    /// The mean colour, darkened to at most 45 % brightness so white text always reads.
    private static func average(_ texture: Texture) -> ArtworkStore.RGB {
        let (pixels, stride) = texture.pixels()
        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
        for y in Swift.stride(from: 0, to: texture.height, by: 4) {
            for x in Swift.stride(from: 0, to: texture.width, by: 4) {
                let index = y * stride + x * 4
                blue += Double(pixels[index])
                green += Double(pixels[index + 1])
                red += Double(pixels[index + 2])
                count += 1
            }
        }
        guard count > 0 else { return ArtworkStore.RGB(red: 0.12, green: 0.12, blue: 0.12) }
        let colour = ArtworkStore.RGB(red: red / count / 255, green: green / count / 255, blue: blue / count / 255)
        let peak = max(colour.red, colour.green, colour.blue)
        guard peak > 0.45 else { return colour }
        let scale = 0.45 / peak
        return ArtworkStore.RGB(red: colour.red * scale, green: colour.green * scale, blue: colour.blue * scale)
    }
}
