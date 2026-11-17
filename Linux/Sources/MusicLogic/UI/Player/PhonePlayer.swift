import CGtk
import Foundation

/// The full player, the phone's `NowPlayingView`: the way down, where the music is playing
/// from and the menu along the top; the cover (or the lyrics, the visualiser, the queue or
/// the video in its place); the title, artist and album with the heart beside them; the
/// detail line and the stars; the seekbar, the transport and the volume; and the row that
/// picks what shows in the cover's place.
///
/// Phone-shaped or narrower, one column, as on the phone. In a window wider than it is
/// tall, the cover side and the controls side by side, the way an iPad lays a player out:
/// the same pieces, only placed for the room.
@MainActor
final class PhonePlayer {
    enum Mode: String {
        case artwork, lyrics, visualizer, queue
    }

    let root: Overlay
    private let app: AppState
    private let env: Env
    private var mode: Mode = .artwork
    private var modeButtons: [Mode: Button] = [:]
    private let content = Stack(transition: GTK_STACK_TRANSITION_TYPE_CROSSFADE)
    private let controls = Box.vertical(spacing: 0)
    private let stars: Widget
    private let body = Box.vertical(spacing: 0)
    private let columns = Box.horizontal(spacing: 0)
    private let controlsClamp: Clamp
    private var isWide: Bool?
    private static let visualizerKey = "player.visualizerEnabled"
    private static let videoPage = "video"

    init(app: AppState, env: Env) {
        self.app = app
        self.env = env
        let backdrop = PlayerBackdrop(app: app)
        root = Overlay(backdrop.root)
        root.css("now-playing", "phone-player")
        let reference = WeakReference<PhonePlayer>(nil)

        // The cover, square and as large as the room allows, and its other sides.
        let artwork = ArtworkView(app, size: .full, side: nil, shape: .player)
        let frame = Widget(gtk_aspect_frame_new(0.5, 0.5, 1, 0)!)
        gtk_aspect_frame_set_child(frame.widget.cast(), artwork.root.widget)
        frame.css("np-cover-frame")
        content.add(frame, name: Mode.artwork.rawValue)
        content.add(LyricsPane(env: env).root, name: Mode.lyrics.rawValue)
        content.add(VisualizerPane(app: app) { reference.value?.select(.artwork) }.root, name: Mode.visualizer.rawValue)
        content.add(QueuePane(env: env).root, name: Mode.queue.rawValue)
        content.add(NowPlaying.videoPane(app, fullScreen: { [env] in
            VideoWindow.present(app, watching: nil, toast: env.toast)
        }), name: Self.videoPage)
        gtk_stack_set_hhomogeneous(content.widget.cast(), 0)
        gtk_stack_set_vhomogeneous(content.widget.cast(), 0)
        content.hexpand().vexpand()
        // The cover is the visualiser's other side: a click turns it over, a right-click
        // picks which one — the phone's tap and long press.
        artwork.root.onClick { reference.value?.select(.visualizer) }
        artwork.root.onContextClick { _, _ in reference.value?.pickVisualizer() }

        stars = Self.ratingStars(app)
        let meta = Self.metadata(app)
        let detail = Self.detailLine(app)
        let seek = SeekBar(app: app).root
        let transport = Self.transport(app)
        let volume = Self.volumeRow()
        let bottom = Box.horizontal(spacing: 0).homogeneous().css("np-bottom-row")
        controls.append(meta)
        controls.append(detail)
        controls.append(stars)
        controls.append(NowPlaying.resumeStrip(app))
        controls.append(NowPlaying.unreachableStrip(app))
        controls.append(PlayOn.banner(env))
        controls.append(seek.margins(top: 14, start: 24, end: 24))
        controls.append(transport)
        controls.append(volume)
        controls.append(bottom)
        controlsClamp = Clamp(controls, maximum: 520, threshold: 440)
        // Its own width and no more: the slider inside would otherwise make it take half
        // of the spare room, and the cover beside it the other half.
        gtk_widget_set_hexpand(controlsClamp.widget, 0)

        let top = Self.topBar(app, menu: { reference.value?.menu() ?? Menu([]) })
        let video = NowPlaying.videoSwitch(app, showVideo: { reference.value?.select(.artwork) }) { [env] in
            guard let song = app.player.currentSong else { return }
            ChangeVideo.present(app, song: song, toast: env.toast)
        }
        body.append(top)
        body.append(video.margins(bottom: 6))
        body.append(columns.vexpand())
        root.add(body)

        // Draws nothing: told the player's size, which decides one column or two.
        let sizer = DrawingArea { _, _, _ in }
        sizer.hexpand().vexpand().canTarget(false)
        root.add(sizer)
        sizer.onResize { width, height in
            DispatchQueue.main.async { reference.value?.lay(out: width > 760 && Double(width) > Double(height) * 1.15) }
        }
        reference.value = self
        root.keep(self)

        for (target, symbol, name) in [
            (Mode.lyrics, "quote.bubble", "Lyrics"), (.artwork, "photo", "Artwork"),
            (.visualizer, "waveform", "Visualizer"), (.queue, "list.bullet", "Up Next"),
        ] {
            let button = Button(icon: Symbol.icon(symbol), "flat", "np-mode") { reference.value?.toggle(target) }
            button.tooltip(name)
            modeButtons[target] = button
            bottom.append(button)
        }
        bottom.append(PlayOn.button(env))

        root.observe { artwork.show(app.player.currentSong?.coverArt, fallback: app.player.currentSong?.album) }
        // The phone's one motion cue: the cover sits back a little while paused.
        root.observe { artwork.root.setCSS("paused", !app.player.isPlaying) }
        // A video starting is shown in the cover's place; the layout follows the switch.
        var wasStandingIn = false
        root.observe {
            _ = app.video.wantsVideo
            _ = app.video.showing
            let standing = app.video.isStandingIn
            let started = standing && !wasStandingIn
            wasStandingIn = standing
            DispatchQueue.main.async {
                guard let player = reference.value else { return }
                if started, player.mode == .visualizer { player.select(.artwork) } else { player.refreshMode() }
            }
        }
        let root = root
        root.observe {
            guard let song = app.player.currentSong, gtk_widget_get_mapped(root.widget) != 0 else { return }
            Task { @MainActor in await app.video.prepare(song) }
        }
        root.onMap {
            guard let song = app.player.currentSong else { return }
            Task { @MainActor in await app.video.prepare(song) }
        }
        lay(out: false)
        select(UserDefaults.standard.bool(forKey: Self.visualizerKey) ? .visualizer : .artwork)
    }

    // MARK: - Layout

    /// One column, the cover above the controls; or two, the cover beside them.
    private func lay(out wide: Bool) {
        guard wide != isWide else { return }
        isWide = wide
        // Held across the move: a box lets go of a child it removes.
        let pieces: [Widget] = [content, controlsClamp]
        for piece in pieces {
            g_object_ref(piece.widget)
            if let parent = gtk_widget_get_parent(piece.widget) {
                gtk_box_remove(parent.cast(), piece.widget)
            }
        }
        columns.orientation(wide ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL)
        for piece in pieces {
            columns.append(piece)
            g_object_unref(piece.widget)
        }
        content.margins(top: 0, bottom: wide ? 24 : 0, start: wide ? 32 : 0, end: wide ? 8 : 0)
        controlsClamp.valign(wide ? GTK_ALIGN_CENTER : GTK_ALIGN_END)
        controlsClamp.size(width: wide ? 440 : -1, height: -1)
        controlsClamp.margins(top: 0, bottom: wide ? 24 : 8, start: wide ? 16 : 0, end: wide ? 24 : 0)
    }

    // MARK: - Modes

    /// The bottom row's buttons: choosing the one showing goes back to the cover's side
    /// that was up, as on the phone.
    private func toggle(_ target: Mode) {
        if mode == target {
            select(UserDefaults.standard.bool(forKey: Self.visualizerKey) ? .visualizer : .artwork)
        } else {
            select(target)
        }
    }

    private func select(_ target: Mode) {
        mode = target
        // Only which side of the cover is up is remembered.
        if target == .artwork || target == .visualizer {
            UserDefaults.standard.set(target == .visualizer, forKey: Self.visualizerKey)
        }
        refreshMode()
    }

    /// From outside the player: open it showing `target`.
    func open(_ target: Mode) {
        select(target)
        app.navigator.showsPlayer = true
    }

    private var showsVideo: Bool {
        mode == .artwork && app.video.wantsVideo && app.video.isStandingIn
    }

    private func refreshMode() {
        content.visibleName = showsVideo ? Self.videoPage : mode.rawValue
        let lit: Mode = mode == .visualizer ? .visualizer : mode
        for (candidate, button) in modeButtons { button.setCSS("selected", candidate == lit) }
        // Rating happens while listening, so the stars sit under the cover; elsewhere the
        // list or the lyrics need the room.
        stars.isVisible = mode == .artwork
    }

    private func pickVisualizer() {
        let reference = WeakReference(self)
        VisualizerPicker.present(over: root) { reference.value?.select(.visualizer) }
    }

    // MARK: - Top

    /// The way down, "Playing From" and where the queue came from, and the menu; the
    /// window's buttons at the end. The strip drags the window, as a header bar does.
    private static func topBar(_ app: AppState, menu: @escaping @MainActor () -> Menu) -> Widget {
        let down = Button(icon: Symbol.icon("chevron.down"), "flat", "np-top-button") { app.navigator.showsPlayer = false }
        down.tooltip("Close Player")
        let source = Label("", "np-source").ellipsize().xalign(0.5)
        let from = Box.vertical(spacing: 1) {
            Label("Playing From", "np-source-heading").xalign(0.5)
            source
        }.hexpand().valign(GTK_ALIGN_CENTER)
        from.observe {
            let described = app.player.queue.sourceDescription
            source.text = described.isEmpty ? "Queue" : described
        }
        let more = MenuButton(icon: Symbol.icon("ellipsis"), "flat", "np-top-button", menu: menu)
        more.tooltip("More")
        let row = Box.horizontal(spacing: 12) {
            down
            from
            more
            Widget(gtk_window_controls_new(GTK_PACK_END)!).valign(GTK_ALIGN_CENTER)
        }.margins(top: 6, bottom: 4, start: 8, end: 8)
        let handle = Widget(gtk_window_handle_new()!)
        gtk_window_handle_set_child(handle.widget.cast(), row.widget)
        return handle
    }

    // MARK: - Title

    /// The title, which opens what the song is about; the artist and the album, which go
    /// to their pages (out of the player, into Library, as on the phone); the heart.
    private static func metadata(_ app: AppState) -> Widget {
        let player = app.player
        let title = Label("", "np-title").xalign(0).ellipsize()
        let titleButton = Button(child: Box.horizontal(spacing: 6) {
            title
            Icon(Symbol.icon("info.circle"), size: 14).css("np-info").valign(GTK_ALIGN_CENTER)
        }, "flat", "np-plain") {
            guard let song = player.currentSong else { return }
            SongAboutPage.present(app, song: song)
        }
        titleButton.tooltip("About This Song")
        let artistName = Label("", "np-artist").xalign(0).ellipsize()
        let artist = Button(child: artistName, "flat", "np-plain") {
            guard let song = player.currentSong, let id = song.artistId, let name = song.artist else { return }
            app.navigator.open(.artist(ArtistRef(id: id, name: name)))
        }
        let albumName = Label("", "np-album").xalign(0).ellipsize()
        let chevron = Icon(Symbol.icon("chevron.right"), size: 11).css("np-album")
        let album = Button(child: Box.horizontal(spacing: 4) {
            albumName
            chevron.valign(GTK_ALIGN_CENTER)
        }, "flat", "np-plain") {
            guard let song = player.currentSong, let id = song.albumId, let name = song.album else { return }
            app.navigator.open(.album(AlbumRef(id: id, name: name, artist: song.artist, coverArt: song.coverArt)))
        }
        for button in [titleButton, artist, album] { button.halign(GTK_ALIGN_START) }
        let heart = Button(icon: Symbol.icon("heart"), "flat", "np-heart-big") {
            guard let song = player.currentSong else { return }
            app.userState.toggleStar(song)
        }
        let row = Box.horizontal(spacing: 12) {
            Box.vertical(spacing: 0) {
                titleButton
                artist
                album
            }.hexpand()
            heart.valign(GTK_ALIGN_CENTER)
        }.margins(top: 14, bottom: 0, start: 24, end: 24)
        row.observe {
            guard let song = player.currentSong else { return }
            title.text = song.title
            artistName.text = song.artist ?? ""
            artist.isVisible = song.artist != nil
            albumName.text = song.album ?? ""
            album.isVisible = song.album != nil
            chevron.isVisible = song.albumId != nil
            let starred = app.userState.isStarred(song)
            heart.icon = Symbol.icon(starred ? "heart.fill" : "heart")
            heart.setCSS("filled", starred)
            heart.tooltip(starred ? "Remove Favourite" : "Favourite")
        }
        return row
    }

    /// The phone's caption line: downloaded, the format, the plays, where in the queue, and
    /// whatever is changing the sound or the session (the Guest DJ, the speed, a sleep
    /// timer, the screen kept on), each tinted.
    private static func detailLine(_ app: AppState) -> Widget {
        let player = app.player
        let downloaded = Icon(Symbol.icon("arrow.down.circle.fill"), size: 12).css("accent")
        let text = Label("", "np-detail").xalign(0).ellipsize()
        let extras = Label("", "np-detail", "accent").xalign(0).ellipsize()
        let row = Box.horizontal(spacing: 6) {
            downloaded.valign(GTK_ALIGN_CENTER)
            text
            extras
        }.margins(top: 4, bottom: 0, start: 24, end: 24)
        row.observe {
            guard let song = player.currentSong else { return }
            downloaded.isVisible = app.downloads.isDownloaded(song.id)
            var parts = [NowPlaying.quality(app, song)]
            if let count = song.playCount, count > 0 { parts.append("\(count) \(count == 1 ? "play" : "plays")") }
            if player.queue.order.count > 1 { parts.append("\(player.queue.position + 1) of \(player.queue.order.count)") }
            text.text = parts.joined(separator: " · ")
            var more: [String] = []
            if let dj = app.guestDJ.dj { more.append("✦ \(dj.name)") }
            if player.speed != 1 { more.append(String(format: "%.1f×", player.speed)) }
            if let timer = app.sleepTimer.label { more.append("☾ \(timer)") }
            if app.screenAwake.isEnabled { more.append("☀ Screen on") }
            extras.text = more.isEmpty ? "" : "· " + more.joined(separator: " · ")
            extras.isVisible = !more.isEmpty
        }
        return row
    }

    /// Five stars under the title, in the cover's mode only.
    private static func ratingStars(_ app: AppState) -> Widget {
        let player = app.player
        let row = Box.horizontal(spacing: 18).halign(GTK_ALIGN_CENTER)
        row.css("np-stars").margins(top: 8, bottom: 0, start: 24, end: 24)
        row.observe {
            guard let song = player.currentSong else { return }
            let user = app.userState
            let rating = user.rating(id: song.id, serverValue: song.userRating)
            row.removeAll()
            for value in 1...5 {
                let star = Button(icon: Symbol.icon(value <= rating ? "star.fill" : "star"), "flat", "np-star-big")
                star.setCSS("filled", value <= rating)
                star.tooltip("\(value) Star\(value == 1 ? "" : "s")")
                star.onClicked { user.setRating(song, to: value, current: rating) }
                row.append(star)
            }
        }
        return row
    }

    // MARK: - Controls

    /// Shuffle, previous, play in its white circle, next, repeat; skipping back and forward
    /// by seconds between them when the setting asks.
    private static func transport(_ app: AppState) -> Widget {
        let player = app.player
        let settings = app.playerSettings
        let shuffle = Button(icon: Symbol.icon("shuffle"), "flat", "np-side") { player.toggleShuffle() }
        let repeatButton = Button(icon: Symbol.icon("repeat"), "flat", "np-side") { player.cycleRepeat() }
        let back = Button(icon: Symbol.icon("gobackward.10"), "flat", "np-skip-seconds") {
            player.skip(by: -Double(settings.skipBackSeconds))
        }
        let previous = Button(icon: Symbol.icon("backward.fill"), "flat", "np-skip") { player.previous() }
        let play = Button(icon: Symbol.icon("pause.circle.fill"), "flat", "np-play-circle") { player.togglePlayPause() }
        let next = Button(icon: Symbol.icon("forward.fill"), "flat", "np-skip") { player.next() }
        let forward = Button(icon: Symbol.icon("goforward.10"), "flat", "np-skip-seconds") {
            player.skip(by: Double(settings.skipForwardSeconds))
        }
        previous.tooltip("Previous")
        next.tooltip("Next")
        let row = Box.horizontal(spacing: 22) {
            shuffle
            back
            previous
            play
            next
            forward
            repeatButton
        }.halign(GTK_ALIGN_CENTER).margins(top: 10, bottom: 0, start: 12, end: 12)
        for button in [shuffle, back, previous, play, next, forward, repeatButton] { button.valign(GTK_ALIGN_CENTER) }
        row.observe {
            play.icon = Symbol.icon(player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
            play.tooltip(player.isPlaying ? "Pause" : "Play")
            next.opacity(player.canGoNext ? 1 : 0.4)
            back.isVisible = settings.showsSkipButtons
            forward.isVisible = settings.showsSkipButtons
            gtk_box_set_spacing(row.widget.cast(), settings.showsSkipButtons ? 14 : 22)
            shuffle.setCSS("active", player.queue.isShuffled)
            shuffle.tooltip(player.queue.isShuffled ? "Shuffle On" : "Shuffle Off")
            let mode = player.queue.repeatMode
            repeatButton.icon = Symbol.icon(mode.symbol)
            repeatButton.setCSS("active", mode != .off)
            repeatButton.tooltip("Repeat: \(mode.rawValue.capitalized)")
        }
        return row
    }

    /// The stream's own volume between the two speakers, as on the phone. Playing on another
    /// computer, that computer's.
    private static func volumeRow() -> Widget {
        let volume = OutputVolume.shared
        let scale = Scale(min: 0, max: 1, step: 0.01, value: volume.level)
        scale.hexpand().css("np-volume").onUserChange { value in
            let level = min(max(value, 0), 1)
            if let session = PlayOn.players?.session { session.setVolume(level) } else { volume.level = level }
        }
        scale.observe {
            let target = PlayOn.players?.session?.volume ?? volume.level
            if abs(scale.value - target) > 0.005 { scale.value = target }
        }
        return Box.horizontal(spacing: 10) {
            Icon(Symbol.icon("speaker.fill"), size: 12).css("np-speaker")
            scale
            Icon(Symbol.icon("speaker.wave.3.fill"), size: 14).css("np-speaker")
        }.margins(top: 12, bottom: 0, start: 24, end: 24)
    }

    // MARK: - Menu

    /// The phone's player menu: the song's own items without the queue's or the rating's,
    /// the jumps, then what changes the session.
    private func menu() -> Menu {
        guard let song = app.player.currentSong else { return Menu([]) }
        let app = app
        let env = env
        var sections = Menus.song(env, song, showsNavigation: false, showsRating: false, showsQueueItems: false).sections
        var jumps = Menus.navigationItems(env, song, jumps: true)
        jumps.append(.action("About This Song") { SongAboutPage.present(app, song: song) })
        jumps.append(.action("Show Similar Tracks") { SimilarTracks.present(env, song: song) })
        jumps.append(.action("Sonic Adventure…") { app.navigator.open(.sonicAdventure(song)) })
        if app.video.isAvailable {
            jumps.append(.action("Change Video…") { ChangeVideo.present(app, song: song, toast: env.toast) })
        }
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
        let reference = WeakReference(self)
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
            .action("Select Visualizer…") { reference.value?.pickVisualizer() },
        ])
        return Menu(sections)
    }
}

/// Behind the player, the phone's Ultrablur: the cover, blurred past recognition and dimmed
/// so white type reads on any sleeve. Blurred once per song, here, at 40 pixels across and
/// stretched to fill — a blur done by the GPU for every frame was the cost that sank the
/// first Linux player on the old MacBook. Smooth and Flat are Plexamp's other two, drawn by
/// the player's own `Backdrop`.
@MainActor
final class PlayerBackdrop {
    let root: Overlay
    private let picture = Picture().fit(GTK_CONTENT_FIT_COVER)

    init(app: AppState) {
        let colours = Backdrop(app: app)
        let wash = Box.vertical(spacing: 0).css("np-wash")
        wash.hexpand().vexpand()
        root = Overlay(picture)
        root.add(colours.root)
        root.add(wash)
        root.css("phone-backdrop")
        root.keep(self)
        let picture = picture
        root.observe {
            let cover = app.player.currentSong?.coverArt
            let blurred = app.playerSettings.background == .ultrablur
            picture.isVisible = blurred
            colours.root.isVisible = !blurred
            wash.isVisible = blurred
            guard blurred else { return }
            Task { @MainActor in
                guard let image = await app.artwork.image(for: cover, size: .thumb),
                      app.player.currentSong?.coverArt == cover
                else { return }
                let (pixels, stride) = image.pixels()
                let (width, height) = (image.width, image.height)
                let texture = await Task.detached(priority: .userInitiated) {
                    Self.blur(pixels, stride: stride, width: width, height: height)
                }.value
                guard app.player.currentSong?.coverArt == cover else { return }
                picture.set(texture)
            }
        }
    }

    /// Averaged down to `side` across, then three box blurs (near enough a Gaussian).
    nonisolated private static func blur(_ pixels: [UInt8], stride: Int, width: Int, height: Int, side: Int = 40) -> Texture {
        var small = [Double](repeating: 0, count: side * side * 4)
        guard width > 0, height > 0 else { return Texture(pixels: [UInt8](repeating: 0, count: side * side * 4), width: side, height: side) }
        for y in 0..<side {
            let y0 = y * height / side, y1 = max(y0 + 1, (y + 1) * height / side)
            for x in 0..<side {
                let x0 = x * width / side, x1 = max(x0 + 1, (x + 1) * width / side)
                var sum = (0.0, 0.0, 0.0, 0.0)
                for sy in y0..<y1 {
                    for sx in x0..<x1 {
                        let i = sy * stride + sx * 4
                        sum.0 += Double(pixels[i]); sum.1 += Double(pixels[i + 1])
                        sum.2 += Double(pixels[i + 2]); sum.3 += Double(pixels[i + 3])
                    }
                }
                let count = Double((y1 - y0) * (x1 - x0))
                let o = (y * side + x) * 4
                small[o] = sum.0 / count; small[o + 1] = sum.1 / count
                small[o + 2] = sum.2 / count; small[o + 3] = sum.3 / count
            }
        }
        let radius = 3
        for _ in 0..<3 {
            for horizontal in [true, false] {
                var out = small
                for y in 0..<side {
                    for x in 0..<side {
                        var sum = (0.0, 0.0, 0.0, 0.0)
                        for d in -radius...radius {
                            let sx = horizontal ? min(max(x + d, 0), side - 1) : x
                            let sy = horizontal ? y : min(max(y + d, 0), side - 1)
                            let i = (sy * side + sx) * 4
                            sum.0 += small[i]; sum.1 += small[i + 1]; sum.2 += small[i + 2]; sum.3 += small[i + 3]
                        }
                        let n = Double(2 * radius + 1)
                        let o = (y * side + x) * 4
                        out[o] = sum.0 / n; out[o + 1] = sum.1 / n; out[o + 2] = sum.2 / n; out[o + 3] = sum.3 / n
                    }
                }
                small = out
            }
        }
        return Texture(pixels: small.map { UInt8(min(max($0.rounded(), 0), 255)) }, width: side, height: side)
    }
}
