import CGtk
import Foundation

/// The full player: Plexamp's now playing screen, laid out the way Plexamp lays it out for
/// the window it is in.
///
/// Plexamp's desktop player has three layouts and picks one from the window's size alone
/// (its `PlayerPortrait`, `PlayerLandscape` and `PlayerTabletSideBySide`):
///
/// - **Portrait** (narrower than tall, or under 500 wide): the cover on top, at most 300
///   across, then the seekbar, artist, title and album, the transport and the toolbar.
/// - **Landscape** (wider than tall, up to 680 high): the cover on the left as tall as the
///   window allows, everything else beside it.
/// - **Side by side** (wider than tall and over 680 high): the player in the left half,
///   the cover two-fifths of the window's height, and Up Next filling the right half.
///
/// The thresholds and sizes are Plexamp 4.13's own. The cover's flip side — visualiser or
/// lyrics — takes the cover's place at the cover's size.
///
/// Whatever does not fit goes, least important first, measured rather than guessed: the
/// volume, the codec line, the toolbar, then the cover shrinks and goes, then the seekbar,
/// then the title. Previous, play and next are the last thing left.
@MainActor
final class NowPlaying {
    enum Mode: String {
        case artwork, queue, lyrics, visualizer
    }

    enum Layout {
        case portrait, landscape, sideBySide
    }

    /// Plexamp's `MARGIN` and `SPACER`.
    private static let margin: Int32 = 15
    /// Where Up Next beside the player is remembered: Plexamp's `playerShowPlayQueue`.
    private static let showsQueueKey = "player.showsQueue"

    let root: Overlay
    private let app: AppState
    private let env: Env
    private var mode: Mode = .artwork
    private var modeButtons: [Mode: Button] = [:]
    private var layout: Layout?
    private var size = (width: Int32(0), height: Int32(0))
    private var showsQueueColumn = UserDefaults.standard.object(forKey: NowPlaying.showsQueueKey) as? Bool ?? true

    // The pieces, made once and arranged for each layout.
    private let topBar: Widget
    private let body = Stack(transition: GTK_STACK_TRANSITION_TYPE_CROSSFADE)
    private let content = Box.horizontal(spacing: 0)
    private let playerBox = Box.vertical(spacing: 0)
    private let posterCell: Overlay
    private let poster = Stack(transition: GTK_STACK_TRANSITION_TYPE_CROSSFADE)
    /// Holds the cover at exactly its size: a picture's natural size is its image's,
    /// which a size request can raise but not cap.
    private let posterFrame: ScrolledWindow
    private var sourceBlock: Widget?
    private let sideClamp: Clamp
    private let side = Box.vertical(spacing: 0)
    private let topSpace = Spacer(horizontal: false)
    private let middleSpace = Spacer(horizontal: false)
    private let bottomSpace = Spacer(horizontal: false)
    private let infoBox = Box.vertical(spacing: 6)
    private let seek: Widget
    private let titleBlock: Box
    private let codec: Widget
    private let controls = Box.vertical(spacing: 0)
    private let transportRow: Box
    private let inlineShuffle: Button
    private let inlineRepeat: Button
    private let volume: Widget
    private let toolbar: Box
    private let toolbarShuffle: Button
    private let toolbarRepeat: Button
    private let queuePane: QueuePane
    private let queueColumn = Bin()
    private let queuePage = Bin()

    init(app: AppState, shell: Shell) {
        self.app = app
        let navigation = Navigation(app: app, shell: shell)
        env = navigation.env

        let backdrop = Backdrop(app: app)
        root = Overlay(backdrop.root)
        root.css("now-playing")

        // The cover and its flip side.
        let artwork = ArtworkView(app, size: .full, side: nil, shape: .player)
        poster.add(artwork.root, name: Mode.artwork.rawValue)
        poster.add(LyricsPane(env: env).root, name: Mode.lyrics.rawValue)
        let modeReference = WeakReference<NowPlaying>(nil)
        let visualizer = VisualizerPane(app: app) { modeReference.value?.select(.artwork) }
        poster.add(visualizer.root, name: Mode.visualizer.rawValue)
        posterFrame = ScrolledWindow(poster, horizontal: GTK_POLICY_EXTERNAL, vertical: GTK_POLICY_EXTERNAL)
        posterFrame.propagatesNaturalWidth().propagatesNaturalHeight()
        posterFrame.halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER)
        posterCell = Overlay(posterFrame)

        seek = SeekBar(app: app).root
        seek.margin(horizontal: Self.margin, vertical: 0)
        titleBlock = Self.titleBlock(app)
        codec = Self.detailLine(app)
        let resume = Self.resumeStrip(app)
        (transportRow, inlineShuffle, inlineRepeat) = Self.transport(app)
        volume = Self.volumeRow()
        queuePane = QueuePane(env: env)
        (toolbar, toolbarShuffle, toolbarRepeat) = (Box.horizontal(spacing: 0), Self.shuffleButton(app), Self.repeatButton(app))

        infoBox.append(seek)
        infoBox.append(titleBlock)
        infoBox.append(codec)
        infoBox.append(resume)
        controls.append(transportRow)
        controls.append(volume)
        for spacer in [topSpace, middleSpace, bottomSpace] { spacer.vexpand() }
        side.append(topSpace)
        side.append(infoBox)
        side.append(middleSpace)
        side.append(controls)
        side.append(toolbar)
        side.append(bottomSpace)
        sideClamp = Clamp(side, maximum: 560, threshold: 400)
        playerBox.append(posterCell)
        playerBox.append(sideClamp)
        content.append(playerBox)
        content.append(queueColumn.hexpand().vexpand())
        body.add(content, name: "player")
        body.add(queuePage, name: "queue")
        // Sized by the page showing only: Up Next's list must not stretch the player.
        gtk_stack_set_hhomogeneous(body.widget.cast(), 0)
        gtk_stack_set_vhomogeneous(body.widget.cast(), 0)
        body.vexpand()

        let (bar, source) = Self.topBar(app, menu: { modeReference.value?.menu() ?? Menu([]) })
        topBar = bar
        sourceBlock = source
        // In a scroller that never scrolls: it asks nothing of the window's size, so the
        // window can always be made smaller, and the next layout fits what is left.
        let frame = ScrolledWindow(Box.vertical {
            bar
            body
        }, horizontal: GTK_POLICY_EXTERNAL, vertical: GTK_POLICY_EXTERNAL)
        frame.hexpand().vexpand()
        root.add(frame)
        // Draws nothing: there to be told the player's size, which decides the layout.
        let sizer = DrawingArea { _, _, _ in }
        sizer.hexpand().vexpand().canTarget(false)
        root.add(sizer)
        root.keep(self)
        modeReference.value = self

        buildToolbar()
        // Plexamp's artwork is the visualiser's other side: a click turns it over, a
        // right-click picks which one.
        artwork.root.onClick { modeReference.value?.select(.visualizer) }
        artwork.root.onContextClick { _, _ in modeReference.value?.selectVisualizer() }
        sizer.onResize { width, height in
            // Applied after this allocation rather than during it: the layout changes
            // size requests, which GTK takes on the next pass.
            DispatchQueue.main.async {
                modeReference.value?.resize(width: width, height: height)
            }
        }
        root.observe { artwork.show(app.player.currentSong?.coverArt, fallback: app.player.currentSong?.album) }
        select(.artwork)
    }

    // MARK: - Layout

    private func resize(width: Int32, height: Int32) {
        guard width > 0, height > 0, (width, height) != size else { return }
        size = (width, height)
        arrange()
    }

    /// Plexamp's choice of layout and every size in it, from the window's size; then
    /// whatever does not fit, dropped least important first.
    private func arrange() {
        let (width, height) = (Int(size.width), Int(size.height))
        guard width > 0 else { return }
        let w = Double(width)
        // The bar as tall as it asks to be with this desktop's fonts and buttons, and a
        // margin at the bottom, clear of the window's rounded corners.
        let bar = max(measuredHeight(topBar, width: size.width), 40)
        let available = Double(height) - bar - 12
        // Plexamp's header floats over the top 30 of its player; this one takes a row of
        // its own, so Plexamp's heights are measured from below it, plus that 30.
        let h = available + 30
        let margin = Double(Self.margin)

        // `landscape` on the desktop: over 500 wide and wider than tall. Side by side
        // when the window is also over 680 high (and the setting is on, which it is by
        // default and here always).
        let landscape = w > 500 && w / h > 1
        let layout: Layout = landscape ? (w > 500 && h > 680 ? .sideBySide : .landscape) : .portrait
        let changed = layout != self.layout
        self.layout = layout

        // Start with everything the layout shows, then take away what does not fit.
        for piece in [seek, titleBlock, codec, transportRow, toolbar] { piece.isVisible = true }
        posterCell.isVisible = true
        var posterSize: Double
        var lyricsWidth: Double
        var posterGap: Double
        var sideWidth: Double
        switch layout {
        case .portrait:
            let fullBleed = w < 300 || (h > 700 && w < 350)
            posterSize = fullBleed ? w : min(w - 70, 300)
            lyricsWidth = w - 2 * margin
            posterGap = fullBleed ? 0 : 6
            sideWidth = min(w, 600)
            volume.isVisible = h >= 675
            playerBox.orientation(GTK_ORIENTATION_VERTICAL)
            playerBox.size(width: -1, height: Int32(min(available, 700)))
            playerBox.halign(GTK_ALIGN_FILL).valign(GTK_ALIGN_CENTER).hexpand(true)
            posterCell.halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_START)
            posterCell.margins(top: Int32(posterGap), bottom: 0, start: 0, end: 0)
            sideClamp.hexpand(true).vexpand(true).valign(GTK_ALIGN_FILL)
            adw_clamp_set_maximum_size(sideClamp.widget.cast(), 600)
            setSpacers(top: true, middle: true, bottom: false)
            volume.size(width: Int32(min(w * 0.75, 500)), height: -1)
            reorder(seekFirst: true)
            titleBlock.setCSS("large", false)
        case .landscape:
            posterSize = h > 100 ? min(w - 250, h - 4 * margin) : h
            posterSize = min(posterSize, available - 2 * margin)
            lyricsWidth = posterSize
            posterGap = 0
            sideWidth = min(w - posterSize - 3 * margin, 560)
            volume.isVisible = h > 420
            playerBox.orientation(GTK_ORIENTATION_HORIZONTAL)
            playerBox.size(width: -1, height: -1)
            playerBox.halign(GTK_ALIGN_FILL).valign(GTK_ALIGN_FILL).hexpand(true)
            // The cover in a cell its own width plus a margin, against the right edge.
            posterCell.halign(GTK_ALIGN_END).valign(GTK_ALIGN_CENTER)
            posterCell.margins(top: 0, bottom: 0, start: Self.margin, end: Self.margin)
            sideClamp.hexpand(true).vexpand(true).valign(GTK_ALIGN_FILL)
            adw_clamp_set_maximum_size(sideClamp.widget.cast(), 560)
            setSpacers(top: true, middle: true, bottom: false)
            volume.size(width: Int32(max(min(sideWidth - 2 * margin, 500), 120)), height: -1)
            reorder(seekFirst: false)
            titleBlock.setCSS("large", false)
        case .sideBySide:
            posterSize = (h / 2.5).rounded()
            lyricsWidth = posterSize
            posterGap = margin
            sideWidth = max(w / 2 - 2 * margin, 300)
            volume.isVisible = true
            playerBox.orientation(GTK_ORIENTATION_VERTICAL)
            playerBox.size(width: Int32(w / 2), height: -1)
            playerBox.hexpand(false).valign(GTK_ALIGN_CENTER)
            playerBox.halign(showsQueueColumn ? GTK_ALIGN_START : GTK_ALIGN_CENTER)
            posterCell.halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_START)
            posterCell.margins(top: 0, bottom: Self.margin, start: 0, end: 0)
            sideClamp.hexpand(true).vexpand(false).valign(GTK_ALIGN_START)
            adw_clamp_set_maximum_size(sideClamp.widget.cast(), Int32(sideWidth))
            setSpacers(top: false, middle: false, bottom: false)
            volume.size(width: Int32(min(w / 2 - 4 * margin, 500)), height: -1)
            reorder(seekFirst: true)
            titleBlock.setCSS("large", true)
        }
        // Extra controls beside the transport only side by side; otherwise shuffle and
        // repeat live in the toolbar, as in Plexamp.
        let extra = layout == .sideBySide
        inlineShuffle.isVisible = extra
        inlineRepeat.isVisible = extra
        toolbarShuffle.isVisible = !extra
        toolbarRepeat.isVisible = !extra

        // Fit. In the stacked layouts the cover shares the height with everything else;
        // in landscape it stands beside them, and only needs width.
        let stacked = layout != .landscape
        let minimumPoster = 110.0
        if !stacked, posterSize < minimumPoster || w - posterSize - 3 * margin < 260 {
            posterCell.isVisible = false
            sideWidth = min(w, 560)
        }
        func needed() -> Double {
            let side = measuredHeight(sideClamp, width: Int32(max(sideWidth, 1)))
            return stacked && posterCell.isVisible ? posterSize + posterGap + side : side
        }
        for piece in [volume, codec, toolbar] where needed() > available {
            piece.isVisible = false
        }
        if stacked, needed() > available, posterCell.isVisible {
            let room = available - posterGap - measuredHeight(sideClamp, width: Int32(max(sideWidth, 1)))
            if room >= minimumPoster {
                posterSize = room
            } else {
                posterCell.isVisible = false
            }
        }
        for piece in [seek, titleBlock] where needed() > available {
            piece.isVisible = false
        }

        let side = Int32(max(posterSize, 40))
        let wide = mode == .lyrics ? Int32(max(lyricsWidth, Double(side))) : side
        poster.size(width: wide, height: side)
        gtk_scrolled_window_set_min_content_width(posterFrame.widget.cast(), wide)
        gtk_scrolled_window_set_max_content_width(posterFrame.widget.cast(), wide)
        gtk_scrolled_window_set_min_content_height(posterFrame.widget.cast(), side)
        gtk_scrolled_window_set_max_content_height(posterFrame.widget.cast(), side)
        // A tiny window keeps the way down, the menu and its own buttons.
        sourceBlock?.isVisible = w >= 330

        if changed { placeQueue() }
        refreshMode()
    }

    /// What a widget asks for in height at a width, as laid out now.
    private func measuredHeight(_ widget: Widget, width: Int32) -> Double {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(widget.widget, GTK_ORIENTATION_VERTICAL, width, &minimum, &natural, nil, nil)
        return Double(natural)
    }

    private func setSpacers(top: Bool, middle: Bool, bottom: Bool) {
        topSpace.isVisible = top
        middleSpace.isVisible = middle
        bottomSpace.isVisible = bottom
        middleSpace.size(width: -1, height: middle ? -1 : 2 * Self.margin)
    }

    /// The seekbar above the title in portrait and side by side, below it in landscape.
    private func reorder(seekFirst: Bool) {
        if seekFirst {
            gtk_box_reorder_child_after(infoBox.widget.cast(), seek.widget, nil)
        } else {
            gtk_box_reorder_child_after(infoBox.widget.cast(), seek.widget, titleBlock.widget)
        }
    }

    /// Up Next has one home per layout: beside the player side by side, otherwise a page
    /// of its own in place of the player.
    private func placeQueue() {
        let widget = queuePane.root
        g_object_ref(widget.widget)
        queueColumn.child = nil
        queuePage.child = nil
        if layout == .sideBySide {
            queueColumn.child = widget
        } else {
            queuePage.child = widget
        }
        g_object_unref(widget.widget)
    }

    // MARK: - Modes

    private func select(_ target: Mode) {
        if target == .queue, layout == .sideBySide {
            showsQueueColumn.toggle()
            UserDefaults.standard.set(showsQueueColumn, forKey: Self.showsQueueKey)
            arrange()
            return
        }
        mode = target
        arrange()
    }

    private func refreshMode() {
        switch mode {
        case .queue:
            body.visibleName = layout == .sideBySide ? "player" : "queue"
        case .artwork, .lyrics, .visualizer:
            body.visibleName = "player"
            poster.visibleName = mode.rawValue
        }
        queueColumn.isVisible = layout == .sideBySide && showsQueueColumn
        for (candidate, button) in modeButtons {
            let selected = candidate == .queue
                ? (layout == .sideBySide ? showsQueueColumn : mode == .queue)
                : candidate == mode
            button.setCSS("selected", selected)
        }
    }

    /// Select Visualizer, which also shows the visualiser it chooses.
    private func selectVisualizer() {
        let reference = WeakReference(self)
        VisualizerPicker.present(over: root) { reference.value?.select(.visualizer) }
    }

    // MARK: - Top

    /// "Playing from", the way down, the menu — and, as the player fills the window, the
    /// window's own buttons, on a bar that drags the window and maximizes it on a double
    /// click as a header bar does.
    private static func topBar(_ app: AppState, menu: @escaping @MainActor () -> Menu) -> (Widget, Widget) {
        let player = app.player
        let source = Label("", "source-title").xalign(0.5).ellipsize()
        source.observe {
            let described = player.queue.sourceDescription
            source.text = described.isEmpty ? "Queue" : described
        }
        let close = Button(icon: "go-down-symbolic", "flat", "circular") { app.navigator.showsPlayer = false }
        close.tooltip("Close Player").valign(GTK_ALIGN_CENTER)
        let more = MenuButton(icon: "view-more-symbolic", "flat", "circular") { menu() }
        more.valign(GTK_ALIGN_CENTER)
        let block = Box.vertical(spacing: 0) {
            Label("PLAYING FROM", "source-caption").xalign(0.5).ellipsize()
            source
        }
        block.valign(GTK_ALIGN_CENTER)
        let bar = Box.horizontal(spacing: 6) {
            Widget(gtk_window_controls_new(GTK_PACK_START)!)
            close
            Box.horizontal { block.hexpand() }.hexpand()
            more
            Widget(gtk_window_controls_new(GTK_PACK_END)!)
        }.margin(horizontal: 6, vertical: 6)
        let handle = Widget(gtk_window_handle_new()!)
        gtk_window_handle_set_child(handle.widget.cast(), bar.widget)
        return (handle, block)
    }

    // MARK: - Menu

    private func menu() -> Menu {
        guard let song = app.player.currentSong else { return Menu([]) }
        let app = app
        var sections = Menus.song(env, song, showsNavigation: false, showsRating: true).sections
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
            .action("Select Visualizer…") { [weak self] in self?.selectVisualizer() },
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

    /// Plexamp's three lines, centred: the artist, the title in bold, the album and its
    /// year dimmer. The artist and album lead to their pages.
    private static func titleBlock(_ app: AppState) -> Box {
        let player = app.player
        let artist = Button("", "flat", "link-button", "np-artist")
        let title = Label("", "np-title").ellipsize().xalign(0.5)
        let album = Button("", "flat", "link-button", "np-album")
        for button in [artist, album] {
            button.halign(GTK_ALIGN_CENTER)
            if let label = gtk_button_get_child(button.widget.cast()) {
                gtk_label_set_ellipsize(OpaquePointer(label), PANGO_ELLIPSIZE_END)
            }
        }
        artist.onClicked {
            guard let song = player.currentSong, let id = song.artistId, let name = song.artist else { return }
            app.navigator.open(.artist(ArtistRef(id: id, name: name)))
        }
        album.onClicked {
            guard let song = player.currentSong, let id = song.albumId, let name = song.album else { return }
            app.navigator.open(.album(AlbumRef(id: id, name: name, artist: song.artist, coverArt: song.coverArt)))
        }
        let box = Box.vertical(spacing: 1) {
            artist
            title
            album
        }
        box.css("np-meta").margin(horizontal: 20, vertical: 0)
        box.observe {
            guard let song = player.currentSong else { return }
            title.text = song.title
            artist.label = song.artist ?? ""
            artist.isVisible = song.artist != nil
            let year = song.year.map { " (\($0))" } ?? ""
            album.label = song.album.map { $0 + year } ?? ""
            album.isVisible = song.album != nil
        }
        return box
    }

    /// What is actually being heard, and where in the queue: every part left out when
    /// unknown rather than shown as a placeholder.
    private static func detailLine(_ app: AppState) -> Widget {
        let label = Label("", "detail-line").ellipsize().xalign(0.5)
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


    /// Shown for a few seconds when playback started part-way through a long track, with
    /// the way back to the start.
    private static func resumeStrip(_ app: AppState) -> Widget {
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

    /// Plexamp's transport: previous and next, play in a circle tinted with the cover's
    /// accent, a little smaller than Plexamp's 60; with shuffle and repeat either side when
    /// side by side. Skip back and forward join it when the setting asks.
    private static func transport(_ app: AppState) -> (Box, Button, Button) {
        let player = app.player
        let settings = app.playerSettings
        let shuffle = shuffleButton(app)
        let repeatButton = repeatButton(app)
        let back = Button(icon: "media-seek-backward-symbolic", "flat", "np-skip") {
            player.skip(by: -Double(settings.skipBackSeconds))
        }
        let previous = Button(icon: "media-skip-backward-symbolic", "flat", "np-skip") { player.previous() }
        let play = Button(icon: "media-playback-start-symbolic", "np-play") { player.togglePlayPause() }
        let next = Button(icon: "media-skip-forward-symbolic", "flat", "np-skip") { player.next() }
        let forward = Button(icon: "media-seek-forward-symbolic", "flat", "np-skip") {
            player.skip(by: Double(settings.skipForwardSeconds))
        }
        previous.tooltip("Previous")
        next.tooltip("Next")
        let row = Box.horizontal(spacing: 0) {
            shuffle
            back
            previous
            play
            next
            forward
            repeatButton
        }.css("np-transport").halign(GTK_ALIGN_CENTER)
        for button in [shuffle, back, previous, play, next, forward, repeatButton] { button.valign(GTK_ALIGN_CENTER) }
        play.margin(horizontal: 10, vertical: 0)
        shuffle.margin(horizontal: margin, vertical: 0)
        repeatButton.margin(horizontal: margin, vertical: 0)
        row.observe {
            play.icon = player.isPlaying ? "media-playback-pause-symbolic" : "media-playback-start-symbolic"
            play.tooltip(player.isPlaying ? "Pause" : "Play")
            next.opacity(player.queue.hasUpNext ? 1 : 0.4)
            back.isVisible = settings.showsSkipButtons
            forward.isVisible = settings.showsSkipButtons
            back.tooltip("Back \(settings.skipBackSeconds) Seconds")
            forward.tooltip("Forward \(settings.skipForwardSeconds) Seconds")
        }
        return (row, shuffle, repeatButton)
    }

    private static func shuffleButton(_ app: AppState) -> Button {
        let player = app.player
        let button = Button(icon: "media-playlist-shuffle-symbolic", "flat", "np-small") { player.toggleShuffle() }
        button.observe {
            button.setCSS("active", player.queue.isShuffled)
            button.tooltip(player.queue.isShuffled ? "Shuffle On" : "Shuffle Off")
        }
        return button
    }

    private static func repeatButton(_ app: AppState) -> Button {
        let player = app.player
        let button = Button(icon: "media-playlist-repeat-symbolic", "flat", "np-small") { player.cycleRepeat() }
        button.observe {
            let mode = player.queue.repeatMode
            button.icon = Icons.named(mode.symbol)
            button.setCSS("active", mode != .off)
            button.tooltip("Repeat: \(mode.rawValue.capitalized)")
        }
        return button
    }

    /// The stream's own volume, the same one the desktop's mixer shows for the app.
    private static func volumeRow() -> Widget {
        let volume = OutputVolume.shared
        let scale = Scale(min: 0, max: 1, step: 0.01, value: volume.level)
        scale.hexpand().onUserChange { volume.level = min(max($0, 0), 1) }
        scale.observe { if abs(scale.value - volume.level) > 0.005 { scale.value = volume.level } }
        return Box.horizontal(spacing: 10) {
            Icon("audio-volume-low-symbolic", size: 14).opacity(0.5)
            scale
            Icon("audio-volume-high-symbolic", size: 14).opacity(0.5)
        }.halign(GTK_ALIGN_CENTER).margins(top: margin, bottom: 0, start: 0, end: 0)
    }

    /// Plexamp's row along the bottom: shuffle, the cover's flip sides, Up Next, repeat.
    private func buildToolbar() {
        toolbar.css("np-toolbar").halign(GTK_ALIGN_CENTER).margins(top: 8, bottom: 6, start: 0, end: 0)
        toolbar.append(toolbarShuffle)
        let entries: [(Mode, String, String)] = [
            (.lyrics, "format-justify-left-symbolic", "Lyrics"),
            (.visualizer, "music-waveform-symbolic", "Visualizer"),
            (.queue, "view-list-symbolic", "Up Next"),
        ]
        for (target, icon, name) in entries {
            let button = Button(icon: icon, "flat", "np-small", "mode-button") { [weak self] in
                guard let self else { return }
                select(target != .queue && mode == target ? .artwork : (target == .queue && mode == .queue ? .artwork : target))
            }
            button.tooltip(name)
            modeButtons[target] = button
            toolbar.append(button)
        }
        toolbar.append(toolbarRepeat)
        for child in [toolbarShuffle, toolbarRepeat] { child.margin(horizontal: 8, vertical: 0) }
        for button in modeButtons.values { button.margin(horizontal: 8, vertical: 0) }
    }
}

/// The cover's colours behind the player, drawn as Plexamp's desktop draws them.
///
/// Ultrablur, the default, is four radial gradients over black, one out of each corner in
/// that corner's colour at 80 %, fading out by 80 % of the way across — Plexamp's CSS,
/// with the corner colours picked as Plexamp picks them. Smooth is the top-left colour
/// into the bottom-right one, top to bottom; Flat is the first colour at half strength.
///
/// Drawn once per track and shape into a small image that is then stretched to fill: it is
/// all gradient, so nothing is lost, and nothing is redrawn while the player moves.
@MainActor
final class Backdrop {
    let root: Overlay
    private let picture = Picture().fit(GTK_CONTENT_FIT_FILL)
    private var corners: [VisualizerPalette.RGB]?
    private var aspect = 1.6
    private var generation = 0
    private let app: AppState

    /// The play button's tint, Plexamp's `buttonOverlayColor`: the palette's accent,
    /// lightened, at 19 %.
    private static let tint: OpaquePointer = {
        let provider = gtk_css_provider_new()!
        gtk_style_context_add_provider_for_display(
            gdk_display_get_default(), OpaquePointer(provider), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1)
        )
        return OpaquePointer(provider)
    }()

    init(app: AppState) {
        self.app = app
        let sizer = DrawingArea { _, _, _ in }
        sizer.hexpand().vexpand().canTarget(false)
        root = Overlay(picture)
        root.add(sizer)
        root.css("backdrop")
        root.keep(self)

        let reference = WeakReference(self)
        sizer.onResize { width, height in
            guard let backdrop = reference.value, width > 0, height > 0 else { return }
            let aspect = Double(width) / Double(height)
            // Only the shape matters to the image; small changes are not worth a redraw.
            guard abs(aspect - backdrop.aspect) / backdrop.aspect > 0.03 else { return }
            backdrop.aspect = aspect
            backdrop.redraw()
        }
        root.observe {
            let cover = app.player.currentSong?.coverArt
            _ = app.playerSettings.background
            Task { @MainActor in
                guard let corners = await VisualizerArtworkPalette.corners(for: cover, artwork: app.artwork),
                      let backdrop = reference.value, app.player.currentSong?.coverArt == cover
                else { return }
                backdrop.corners = corners
                backdrop.redraw()
                Self.setTint(corners)
            }
        }
    }

    private func redraw() {
        guard let corners else { return }
        let style = app.playerSettings.background
        let aspect = aspect
        generation += 1
        let current = generation
        Task { @MainActor in
            let texture = await Task.detached(priority: .userInitiated) {
                Self.render(corners, style: style, aspect: aspect)
            }.value
            guard current == self.generation else { return }
            self.picture.set(texture)
        }
    }

    nonisolated private static func render(_ colours: [VisualizerPalette.RGB], style: PlayerSettings.Background, aspect: Double) -> Texture {
        let width = 160
        let height = max(1, Int((Double(width) / aspect).rounded()))
        // In units of the window's height: the radii are the window's, so the circles stay
        // circles whatever its shape.
        let w = aspect
        let h = 1.0
        let radius = (w * w + h * h).squareRoot() * 0.8
        // Bottom layer first: CSS lists the bottom-left gradient first, which draws on top.
        let layers = [((0.0, 0.0), colours[0]), ((w, 0.0), colours[1]), ((w, h), colours[2]), ((0.0, h), colours[3])]
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let py = (Double(y) + 0.5) / Double(height) * h
            for x in 0..<width {
                let px = (Double(x) + 0.5) / Double(width) * w
                var (r, g, b) = (0.0, 0.0, 0.0)
                switch style {
                case .ultrablur:
                    for ((cx, cy), colour) in layers {
                        let distance = ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot()
                        let alpha = distance < radius ? 0.8 * (1 - distance / radius) : 0
                        r = colour.r * alpha + r * (1 - alpha)
                        g = colour.g * alpha + g * (1 - alpha)
                        b = colour.b * alpha + b * (1 - alpha)
                    }
                case .smooth:
                    let t = py / h
                    r = (colours[0].r * (1 - t) + colours[2].r * t) * 0.8
                    g = (colours[0].g * (1 - t) + colours[2].g * t) * 0.8
                    b = (colours[0].b * (1 - t) + colours[2].b * t) * 0.8
                case .flat:
                    (r, g, b) = (colours[0].r * 0.5, colours[0].g * 0.5, colours[0].b * 0.5)
                }
                let index = (y * width + x) * 4
                pixels[index] = UInt8(clamping: Int(b.rounded()))
                pixels[index + 1] = UInt8(clamping: Int(g.rounded()))
                pixels[index + 2] = UInt8(clamping: Int(r.rounded()))
            }
        }
        return Texture(pixels: pixels, width: width, height: height)
    }

    /// The most saturated corner, its lightness raised by 30 %.
    private static func setTint(_ corners: [VisualizerPalette.RGB]) {
        func hsl(_ c: VisualizerPalette.RGB) -> (h: Double, s: Double, l: Double) {
            let (r, g, b) = (c.r / 255, c.g / 255, c.b / 255)
            let high = max(r, g, b)
            let low = min(r, g, b)
            let l = (high + low) / 2
            guard high != low else { return (0, 0, l) }
            let d = high - low
            let s = l > 0.5 ? d / (2 - high - low) : d / (high + low)
            let h: Double
            switch high {
            case r: h = (g - b) / d + (g < b ? 6 : 0)
            case g: h = (b - r) / d + 2
            default: h = (r - g) / d + 4
            }
            return (h / 6, s, l)
        }
        func rgb(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
            guard s > 0 else { return (l, l, l) }
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s
            let p = 2 * l - q
            func channel(_ t: Double) -> Double {
                var t = t
                if t < 0 { t += 1 }
                if t > 1 { t -= 1 }
                if t < 1.0 / 6 { return p + (q - p) * 6 * t }
                if t < 0.5 { return q }
                if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
                return p
            }
            return (channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
        }
        guard let accent = corners.max(by: { hsl($0).s < hsl($1).s }) else { return }
        let (h, s, l) = hsl(accent)
        let (r, g, b) = rgb(h, s, min(1, l * 1.3))
        let css = ".now-playing .np-play { background-color: rgba(\(Int(r * 255)), \(Int(g * 255)), \(Int(b * 255)), 0.19); }"
        gtk_css_provider_load_from_string(UnsafeMutablePointer(tint), css)
    }
}
