import CGtk
import Foundation

/// The full player: Plexamp's desktop player, laid out the way Plexamp lays it out for the
/// window it is in. Every rule and size here is Plexamp 4.13's own (its `PlayerPortrait`,
/// `PlayerLandscape`, `PlayerTabletSideBySide`, `PosterSize` and the components they
/// hold), in Plexamp's units: its desktop app draws at a zoom of 0.8 ("Normal"), so a
/// Plexamp pixel is 0.8 of a screen pixel, and its breakpoints are in its pixels.
///
/// - **Portrait** — narrower than tall, or under 500 across: the cover on top, 300 across
///   at most (the full width under 300), then the seekbar, artist, title and album, the
///   codec and rating line, the transport, the volume and a toolbar, in a block 700 tall
///   at most. Up Next — with Back To and Related beside it — fills the window below; in a
///   shorter window it is a scroll away, as in Plexamp.
/// - **Landscape** — wider than tall, up to 680 high: the cover on the left as tall as
///   the window, everything else beside it; the queue below.
/// - **Side by side** — wider than tall and taller than 680: the player in the left half,
///   the cover two-fifths of the height, and the queue filling the right half (or, hidden,
///   the player centred).
///
/// What Plexamp leaves out as the window shrinks goes here too, and anything that still
/// does not fit goes after it, measured: the volume, the codec line, the toolbar, then the
/// cover shrinks, then the seekbar and the title. Previous, play and next are the last
/// thing left.
@MainActor
final class NowPlaying {
    enum Mode: String {
        case artwork, lyrics, visualizer
    }

    enum Layout {
        case portrait, landscape, sideBySide
    }

    /// Plexamp's desktop zoom: its pixels to ours.
    static let zoom = 0.8
    /// Plexamp's `MARGIN` and `SPACER`, 15 of its pixels.
    private static let margin = 15.0
    /// Where Up Next beside the player is remembered: Plexamp's `playerShowPlayQueue`.
    private static let showsQueueKey = "player.showsQueue"
    /// Whether the visualiser was up: Plexamp's `ui:visualizerenabled`, so it comes back
    /// where it was left.
    private static let visualizerKey = "player.visualizerEnabled"

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
    private let scroller: ScrolledWindow
    private let page = Box.vertical(spacing: 0)
    private let mainRow = Box.horizontal(spacing: 0)
    private let playerBox = Box.vertical(spacing: 0)
    private let posterColumn = Box.vertical(spacing: 0)
    private let posterPad = Spacer(horizontal: false)
    private let posterCell: Overlay
    private let poster = Stack(transition: GTK_STACK_TRANSITION_TYPE_CROSSFADE)
    /// Holds the cover at exactly its size: a picture's natural size is its image's, which
    /// a size request can raise but not cap.
    private let posterFrame: ScrolledWindow
    private let side = Box.vertical(spacing: 0)
    private let sideSpacers = (0..<4).map { _ in Spacer(horizontal: false) }
    private let infoClamp: Clamp
    private let info = Box.vertical(spacing: 0)
    private let seek: Widget
    private let titleBlock: Box
    private let codec: Widget
    private let controls = Box.vertical(spacing: 0)
    private let controlsClamp: Clamp
    private let transportRow: Box
    private let inlineShuffle: Button
    private let inlineRepeat: Button
    private let volume: Widget
    private let toolbar: Box
    private let sideToolbar: Box
    private let toolbarShuffle: Button
    private let toolbarRepeat: Button
    private let queuePane: QueuePane
    private let queueColumn = Bin()
    private let queueDock = Bin()

    init(app: AppState, shell: Shell) {
        self.app = app
        let navigation = Navigation(app: app, shell: shell)
        env = navigation.env

        let backdrop = Backdrop(app: app)
        root = Overlay(backdrop.root)
        root.css("now-playing")

        // The cover and its flip sides.
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
        posterColumn.append(posterPad)
        posterColumn.append(posterCell)

        seek = SeekBar(app: app, desktop: true).root
        titleBlock = Self.titleBlock(app)
        codec = Self.codecRow(app)
        let resume = Self.resumeStrip(app)
        let unreachable = Self.unreachableStrip(app)
        (transportRow, inlineShuffle, inlineRepeat) = Self.transport(app)
        volume = Self.volumeRow()
        queuePane = QueuePane(env: env)
        toolbarShuffle = Self.shuffleButton(app)
        toolbarRepeat = Self.repeatButton(app)
        toolbar = Box.horizontal(spacing: 0)
        sideToolbar = Box.horizontal(spacing: 0)

        info.append(seek)
        info.append(titleBlock)
        info.append(codec)
        info.append(resume)
        info.append(unreachable)
        infoClamp = Clamp(info, maximum: 400, threshold: 300)
        controls.append(transportRow)
        controls.append(volume)
        controlsClamp = Clamp(controls, maximum: 440, threshold: 300)
        for spacer in sideSpacers { spacer.vexpand() }
        side.append(sideSpacers[0])
        side.append(infoClamp)
        side.append(sideSpacers[1])
        side.append(controlsClamp)
        side.append(sideSpacers[2])
        side.append(toolbar)
        side.append(sideToolbar)
        side.append(sideSpacers[3])
        playerBox.append(posterColumn)
        playerBox.append(side)
        mainRow.append(playerBox)
        mainRow.append(queueColumn.hexpand().vexpand())
        page.append(mainRow)
        page.append(queueDock)

        // One scroller for the whole player, as Plexamp's: in a short window the queue is
        // a scroll away under it. It asks nothing of the window's size, so the window can
        // always be made smaller and the next layout fits what is left.
        scroller = ScrolledWindow(page, horizontal: GTK_POLICY_EXTERNAL, vertical: GTK_POLICY_AUTOMATIC)
        scroller.hexpand().vexpand()
        gtk_scrolled_window_set_overlay_scrolling(scroller.widget.cast(), 1)
        // Scrolled only by the person: following focus, a click on a button moved the
        // player out from under the window's edge.
        if let viewport = gtk_scrolled_window_get_child(scroller.widget.cast()) {
            gtk_viewport_set_scroll_to_focus(OpaquePointer(viewport), 0)
        }
        root.add(scroller)

        let bar = Self.topBar()
        topBar = bar
        root.add(bar)
        // Draws nothing: there to be told the player's size, which decides the layout.
        let sizer = DrawingArea { _, _, _ in }
        sizer.hexpand().vexpand().canTarget(false)
        root.add(sizer)
        root.keep(self)
        modeReference.value = self

        buildToolbars()
        // Plexamp's cover is the visualiser's other side: a click turns it over, a
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
        select(UserDefaults.standard.bool(forKey: Self.visualizerKey) ? .visualizer : .artwork)
    }

    // MARK: - Layout

    private func resize(width: Int32, height: Int32) {
        guard width > 0, height > 0, (width, height) != size else { return }
        size = (width, height)
        arrange()
    }

    /// Plexamp's choice of layout and every size in it, from the window's size; then
    /// whatever still does not fit, dropped least important first.
    private func arrange() {
        guard size.width > 0, size.height > 0 else { return }
        let z = Self.zoom
        let width = Double(size.width)
        let height = Double(size.height)
        // In Plexamp's pixels, where its rules are written.
        let w = width / z
        let h = height / z
        let m = Self.margin
        let bar = max(measuredHeight(topBar, width: size.width), 28)

        // Plexamp's `landscape` on the desktop: over 500 wide and wider than tall. Side by
        // side when it is also over 680 high (its setting, on by default and here always).
        let layout: Layout = w > 500 && w / h > 1 ? (h > 680 ? .sideBySide : .landscape) : .portrait
        let changed = layout != self.layout
        self.layout = layout

        for piece in [seek, titleBlock, codec, transportRow, toolbar, sideToolbar, posterCell] { piece.isVisible = true }
        var posterSize: Double
        var wide: Double
        var block: Double
        switch layout {
        case .portrait:
            // `PosterSize` on the desktop, and the block it heads.
            let fullBleed = w < 300 || (h > 700 && w < 350)
            posterSize = (fullBleed ? w : min(w - 70, 300)) * z
            block = min(h, 700) * z
            var room = h - posterSize / z
            if w <= 300 { room += 40 }
            seek.isVisible = room > 220
            titleBlock.isVisible = room > 135
            codec.isVisible = room > 245
            volume.isVisible = h >= 675
            sideToolbar.isVisible = false
            // The visualiser spans the window at the cover's height; the lyrics, the
            // window less its margins.
            wide = mode == .visualizer ? width : mode == .lyrics ? width - 2 * m * z : posterSize
            playerBox.orientation(GTK_ORIENTATION_VERTICAL)
            playerBox.size(width: -1, height: Int32(block))
            playerBox.hexpand(true).halign(GTK_ALIGN_FILL).valign(GTK_ALIGN_FILL)
            posterColumn.halign(GTK_ALIGN_FILL).valign(GTK_ALIGN_START)
            posterPad.vexpand(false).size(width: -1, height: Int32(posterPadHeight(bar: bar, w: w, h: h, poster: posterSize)))
            posterCell.halign(GTK_ALIGN_CENTER).margins(top: 0, bottom: 0, start: 0, end: 0)
            side.vexpand(true).hexpand(true).valign(GTK_ALIGN_FILL)
            spacers(flexible: [true, true, true, false], fixed: [0, 0, 0, 0])
            adw_clamp_set_maximum_size(infoClamp.widget.cast(), Int32(500 * z))
            adw_clamp_set_maximum_size(controlsClamp.widget.cast(), Int32(width))
            volume.size(width: Int32(min(width * 0.75, 500 * z)), height: -1)
            volume.margins(top: Int32(m * z), bottom: 0, start: 0, end: 0)
            toolbar.margins(top: 0, bottom: Int32(10 * z), start: Int32(m * z), end: Int32(m * z))
            reorder(seekFirst: true)
            titleBlock.setCSS("large", false)
        case .landscape:
            let tiny = h <= 100
            posterSize = (h > 100 ? min(w - 250, h - 4 * m) : h) * z
            // Clear of the window controls over the top.
            posterSize = min(posterSize, height - 2 * bar)
            block = height
            wide = posterSize
            seek.isVisible = h > 150
            codec.isVisible = h > 200
            volume.isVisible = h > 420
            toolbar.isVisible = h > 325
            sideToolbar.isVisible = false
            playerBox.orientation(GTK_ORIENTATION_HORIZONTAL)
            playerBox.size(width: -1, height: Int32(block))
            playerBox.hexpand(true).halign(GTK_ALIGN_FILL).valign(GTK_ALIGN_FILL)
            // The cover in a cell its own width plus a margin, against its right edge.
            posterColumn.halign(GTK_ALIGN_START).valign(GTK_ALIGN_CENTER)
            posterPad.vexpand(false).size(width: -1, height: 0)
            posterCell.halign(GTK_ALIGN_END).margins(top: 0, bottom: 0, start: Int32(m * z), end: tiny ? 0 : Int32(m * z))
            side.vexpand(true).hexpand(true).valign(GTK_ALIGN_FILL)
            spacers(flexible: [true, true, true, false], fixed: [0, 0, 0, Int(m * z)])
            adw_clamp_set_maximum_size(infoClamp.widget.cast(), Int32(500 * z))
            adw_clamp_set_maximum_size(controlsClamp.widget.cast(), Int32(500 * z))
            volume.size(width: Int32(max(min(width - posterSize - 5 * m * z, 500 * z), 120)), height: -1)
            volume.margins(top: Int32(m * z / 2), bottom: 0, start: 0, end: 0)
            toolbar.margins(top: 0, bottom: Int32(10 * z), start: Int32(m * z), end: Int32(m * z))
            reorder(seekFirst: false)
            titleBlock.setCSS("large", false)
        case .sideBySide:
            posterSize = (h / 2.5).rounded() * z
            block = height
            wide = posterSize
            volume.isVisible = true
            toolbar.isVisible = false
            playerBox.orientation(GTK_ORIENTATION_VERTICAL)
            playerBox.size(width: Int32(width / 2), height: Int32(block))
            // Hidden, the queue leaves the player centred in the window.
            playerBox.hexpand(!showsQueueColumn).valign(GTK_ALIGN_FILL)
            playerBox.halign(showsQueueColumn ? GTK_ALIGN_START : GTK_ALIGN_CENTER)
            // Plexamp's three flexible spacers — above the cover, under the volume, under
            // the toolbar — are set to thirds of what is left once the rest is measured.
            posterColumn.halign(GTK_ALIGN_FILL).valign(GTK_ALIGN_START)
            posterPad.vexpand(false).size(width: -1, height: Int32(bar))
            posterCell.halign(GTK_ALIGN_CENTER).margins(top: 0, bottom: 0, start: 0, end: 0)
            side.vexpand(false).hexpand(true).valign(GTK_ALIGN_START)
            spacers(flexible: [false, false, false, false], fixed: [Int(m * z), Int(m * z), 0, 0])
            adw_clamp_set_maximum_size(infoClamp.widget.cast(), Int32(500 * z))
            adw_clamp_set_maximum_size(controlsClamp.widget.cast(), Int32(width / 2))
            volume.size(width: Int32(min(width / 2 - 4 * m * z, 500 * z)), height: -1)
            volume.margins(top: Int32(m * z), bottom: 0, start: 0, end: 0)
            sideToolbar.margins(top: 0, bottom: 0, start: 0, end: 0)
            reorder(seekFirst: true)
            titleBlock.setCSS("large", true)
        }
        // Shuffle and repeat beside the transport only side by side; otherwise they are at
        // the ends of the toolbar, as in Plexamp — and gone from it under 310 across.
        let extra = layout == .sideBySide
        inlineShuffle.isVisible = extra
        inlineRepeat.isVisible = extra
        toolbarShuffle.isVisible = !extra && w >= 310
        toolbarRepeat.isVisible = !extra && w >= 310
        transportRow.setCSS("roomy", layout == .portrait)

        // Fit. In the stacked layouts the cover shares the block's height with the rest;
        // in landscape it stands beside them and needs only width.
        let stacked = layout != .landscape
        let sideWidth = Int32(layout == .landscape ? max(width - posterSize - 3 * m * z, 1) : layout == .sideBySide ? width / 2 : width)
        let posterTop = layout == .portrait ? posterPadHeight(bar: bar, w: w, h: h, poster: posterSize) : layout == .sideBySide ? bar : 0
        let minimumPoster = 100.0
        // Below the window controls, which sit over the top of the landscape layout.
        side.margins(top: layout == .landscape ? Int32(bar) : 0, bottom: 0, start: 0, end: 0)
        if !stacked, posterSize < minimumPoster || width - posterSize - 3 * m * z < 240 {
            posterCell.isVisible = false
        }
        func needed() -> Double {
            let rest = measuredHeight(side, width: sideWidth)
            return stacked && posterCell.isVisible ? posterTop + posterSize + rest : rest
        }
        let available = block
        for piece in [volume, codec, toolbar] where needed() > available {
            piece.isVisible = false
        }
        if stacked, posterCell.isVisible, needed() > available {
            let room = available - posterTop - measuredHeight(side, width: sideWidth)
            if room >= minimumPoster {
                posterSize = room
                if mode != .visualizer, mode != .lyrics || layout != .portrait { wide = room }
            } else {
                posterCell.isVisible = false
            }
        }
        for piece in [seek, titleBlock] where needed() > available {
            piece.isVisible = false
        }
        if layout == .sideBySide {
            let third = max((available - needed()) / 3, 0)
            posterPad.size(width: -1, height: Int32(max(third, bar)))
            sideSpacers[2].size(width: -1, height: Int32(third))
            sideSpacers[3].size(width: -1, height: Int32(third))
        }

        let square = Int32(max(posterSize, 40))
        let across = Int32(max(wide, Double(square)))
        poster.size(width: across, height: square)
        gtk_scrolled_window_set_min_content_width(posterFrame.widget.cast(), across)
        gtk_scrolled_window_set_max_content_width(posterFrame.widget.cast(), across)
        gtk_scrolled_window_set_min_content_height(posterFrame.widget.cast(), square)
        gtk_scrolled_window_set_max_content_height(posterFrame.widget.cast(), square)

        placeQueue(layout: layout, changed: changed, windowHeight: height, block: block)
        // A new layout starts at the top: an offset kept from the last one would cut its
        // top off.
        if changed {
            let scroller = scroller
            DispatchQueue.main.async {
                gtk_adjustment_set_value(gtk_scrolled_window_get_vadjustment(scroller.widget.cast()), 0)
            }
        }
        refreshMode()
    }

    /// The space above the cover in portrait: Plexamp's 30 — or, when the window is too
    /// narrow for the cover to clear the window's buttons beside it, their height.
    private func posterPadHeight(bar: Double, w: Double, h: Double, poster: Double) -> Double {
        let fullBleed = w < 300 || (h > 700 && w < 350)
        if fullBleed { return 0 }
        let clear = (w * Self.zoom - poster) / 2 > Self.windowButtonsWidth
        return clear ? 30 * Self.zoom : max(30 * Self.zoom, bar)
    }

    /// Room the window's own buttons take at either end of the top strip.
    private static let windowButtonsWidth = 130.0

    private func spacers(flexible: [Bool], fixed: [Int]) {
        for (index, spacer) in sideSpacers.enumerated() {
            spacer.vexpand(flexible[index])
            spacer.size(width: -1, height: Int32(fixed[index]))
        }
    }

    /// What a widget asks for in height at a width, as laid out now.
    private func measuredHeight(_ widget: Widget, width: Int32) -> Double {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(widget.widget, GTK_ORIENTATION_VERTICAL, width, &minimum, &natural, nil, nil)
        return Double(natural)
    }

    /// The seekbar above the title in portrait and side by side, below it in landscape.
    private func reorder(seekFirst: Bool) {
        if seekFirst {
            gtk_box_reorder_child_after(info.widget.cast(), seek.widget, nil)
        } else {
            gtk_box_reorder_child_after(info.widget.cast(), seek.widget, titleBlock.widget)
        }
    }

    /// Plexamp's queue has one home per layout: beside the player side by side, otherwise
    /// under it — filling the window below the player when there is room, a window's
    /// height of it a scroll away when there is not.
    private func placeQueue(layout: Layout, changed: Bool, windowHeight: Double, block: Double) {
        let widget = queuePane.root
        if changed {
            g_object_ref(widget.widget)
            queueColumn.child = nil
            queueDock.child = nil
            if layout == .sideBySide { queueColumn.child = widget } else { queueDock.child = widget }
            g_object_unref(widget.widget)
        }
        queueColumn.isVisible = layout == .sideBySide && showsQueueColumn
        queueColumn.margins(top: Int32(layout == .sideBySide ? max(measuredHeight(topBar, width: size.width), 28) : 0), bottom: 0, start: Int32(Self.margin * Self.zoom), end: 0)
        queueDock.isVisible = layout != .sideBySide
        let below = windowHeight - block
        let dock = below >= 200 ? below : windowHeight
        queueDock.size(width: -1, height: Int32(dock))
        mainRow.size(width: -1, height: Int32(layout == .sideBySide ? windowHeight : block))
    }

    // MARK: - Modes

    private func select(_ target: Mode) {
        mode = target
        // Lyrics are for the track at hand; only the visualiser is remembered.
        if target != .lyrics { UserDefaults.standard.set(target == .visualizer, forKey: Self.visualizerKey) }
        arrange()
    }

    private func toggleQueueColumn() {
        showsQueueColumn.toggle()
        UserDefaults.standard.set(showsQueueColumn, forKey: Self.showsQueueKey)
        arrange()
    }

    private func refreshMode() {
        poster.visibleName = mode.rawValue
        for (candidate, button) in modeButtons { button.setCSS("selected", candidate == mode) }
        for (candidate, button) in sideModeButtons { button.setCSS("selected", candidate == mode) }
        queueToggle?.setCSS("selected", showsQueueColumn)
    }

    private var queueToggle: Button?

    /// Select Visualizer, which also shows the visualiser it chooses.
    private func selectVisualizer() {
        let reference = WeakReference(self)
        VisualizerPicker.present(over: root) { reference.value?.select(.visualizer) }
    }

    // MARK: - Top

    /// The window's own buttons over the top of the player, on a strip that drags the
    /// window and maximizes it on a double click as a header bar does. Plexamp's desktop
    /// window has no title bar either.
    private static func topBar() -> Widget {
        let bar = Box.horizontal(spacing: 6) {
            Widget(gtk_window_controls_new(GTK_PACK_START)!)
            Spacer()
            Widget(gtk_window_controls_new(GTK_PACK_END)!)
        }.margin(horizontal: 6, vertical: 4)
        let handle = Widget(gtk_window_handle_new()!)
        gtk_window_handle_set_child(handle.widget.cast(), bar.widget)
        handle.valign(GTK_ALIGN_START).hexpand()
        return handle
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

        // What Plexamp's queue menu holds, here with the rest.
        let player = app.player
        let env = env
        sections.append([
            .action("Save Play Queue as Playlist…", enabled: !player.queue.tracks.isEmpty) {
                let songs = player.queue.order.compactMap { player.queue.tracks.indices.contains($0) ? player.queue.tracks[$0] : nil }
                Menus.newPlaylist(env, songs, suggested: player.queue.sourceDescription)
            },
            .action("Clear Play Queue", destructive: true, enabled: player.queue.hasUpNext) {
                Dialogs.alert(
                    "Clear Play Queue?",
                    body: "The track playing keeps playing.",
                    responses: [("cancel", "Cancel", ADW_RESPONSE_DEFAULT), ("clear", "Clear Play Queue", ADW_RESPONSE_DESTRUCTIVE)]
                ) { if $0 == "clear" { player.clearQueue() } }
            },
        ])

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

    /// Plexamp's three lines, centred in nine-tenths of the width: the artist, the title in
    /// bold, the album and its year dimmer. The artist and album lead to their pages.
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
        let box = Box.vertical(spacing: 0) {
            artist
            title
            album
        }
        box.css("np-meta").margin(horizontal: 18, vertical: 4)
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

    /// Plexamp's codec line: the format on the left of the track's stars, the rate and depth
    /// (or bitrate) on the right. What else is worth knowing — downloaded, the speed, a
    /// sleep timer, the Guest DJ — follows the rate when it applies.
    private static func codecRow(_ app: AppState) -> Widget {
        let player = app.player
        let format = Label("", "np-codec").xalign(1).hexpand()
        let detail = Label("", "np-codec").xalign(0).hexpand().ellipsize()
        let stars = Box.horizontal(spacing: 0)
        let row = Box.horizontal(spacing: 8) {
            format
            stars
            detail
        }
        row.margin(horizontal: 12, vertical: 4)
        row.observe {
            guard let song = player.currentSong else { return }
            let parts = quality(app, song).components(separatedBy: " · ")
            format.text = parts.first ?? ""
            var rest = Array(parts.dropFirst())
            if app.downloads.isDownloaded(song.id) { rest.append("Downloaded") }
            if let dj = app.guestDJ.dj { rest.append("✦ \(dj.name)") }
            if player.speed != 1 { rest.append(String(format: "%.1f×", player.speed)) }
            if let timer = app.sleepTimer.label { rest.append("☾ \(timer)") }
            detail.text = rest.joined(separator: " · ")

            let user = app.userState
            let rating = user.rating(id: song.id, serverValue: song.userRating)
            stars.removeAll()
            for value in 1...5 {
                let star = Button(value <= rating ? "★" : "☆", "flat", "np-star")
                star.setCSS("filled", value <= rating)
                star.tooltip("\(value) Star\(value == 1 ? "" : "s")")
                star.onClicked { user.setRating(id: song.id, to: value, current: rating) }
                stars.append(star)
            }
        }
        return row
    }

    /// "FLAC · 96 / 24", "MP3 · 320 kbps": for lossless the rate and depth, in Plexamp's
    /// order, are the useful numbers; for a converted stream, that it was converted.
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
                parts.append("\(kilohertz(rate)) / \(depth)")
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
        // A slide, not a crossfade: a crossfading revealer keeps its height while hidden.
        let revealer = Revealer(strip, transition: GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN)
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

    /// Shown while the track playing could not be fetched because the server did not
    /// answer: why it stopped, and the way to try again.
    private static func unreachableStrip(_ app: AppState) -> Widget {
        let player = app.player
        let label = Label("", "caption")
        let retry = Button("Try Again", "flat", "caption-heading") { player.play() }
        let strip = Box.horizontal(spacing: 10) {
            Icon("network-offline-symbolic", size: 14)
            label
            retry
        }.css("resume-strip").halign(GTK_ALIGN_CENTER)
        let revealer = Revealer(strip, transition: GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN)
        revealer.observe {
            guard let songID = player.unreachableSongID, songID == player.currentSong?.id else {
                revealer.isRevealed = false
                return
            }
            // Playing here means a try is under way.
            label.text = player.isPlaying ? "Trying the server again…" : "Can't reach the server"
            retry.isVisible = !player.isPlaying
            revealer.isRevealed = true
        }
        return revealer
    }



    // MARK: - Controls

    /// Plexamp's transport: previous and next, and play in a 60-pixel circle tinted with the
    /// cover's accent, spaced wider in portrait; side by side, shuffle and repeat either
    /// end. Skip back and forward join it when the setting asks.
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
        play.margin(horizontal: 8, vertical: 0)
        shuffle.margin(horizontal: 12, vertical: 0)
        repeatButton.margin(horizontal: 12, vertical: 0)
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

    /// Plexamp's Guest DJ button: the DJs to choose from, the one playing lit.
    private static func djButton(_ app: AppState) -> Widget {
        let guest = app.guestDJ
        let button = MenuButton(icon: "starred-symbolic", "flat", "np-small") {
            Menu([[
                .choice(
                    guest.dj.map { "Guest DJ — \($0.name)" } ?? "Guest DJ",
                    options: [("off", "Off")] + GuestDJ.allCases.map { ($0.rawValue, $0.name) },
                    selected: guest.dj?.rawValue ?? "off"
                ) { id in guest.setDJ(GuestDJ(rawValue: id)) },
            ]])
        }
        button.observe {
            button.setCSS("active", guest.dj != nil)
            button.tooltip(guest.dj.map { "Guest DJ — \($0.name)" } ?? "Guest DJ")
        }
        return button
    }

    /// The stream's own volume, the same one the desktop's mixer shows for the app.
    private static func volumeRow() -> Widget {
        let volume = OutputVolume.shared
        let scale = Scale(min: 0, max: 1, step: 0.01, value: volume.level)
        scale.hexpand().onUserChange { volume.level = min(max($0, 0), 1) }
        scale.observe { if abs(scale.value - volume.level) > 0.005 { scale.value = volume.level } }
        return Box.horizontal(spacing: 8) {
            Icon("audio-volume-high-symbolic", size: 14).opacity(0.7)
            scale
        }.halign(GTK_ALIGN_CENTER)
    }

    /// Plexamp's two toolbars. Under the player: the menu, the Guest DJ and shuffle on the
    /// left, the way down in the middle, repeat and the cover's flip sides on the right
    /// (where Plexamp has its speakers and casting). Side by side, one row under the
    /// controls: the flip sides, the DJ, the menu, Up Next beside the player, the way down.
    private func buildToolbars() {
        let reference = WeakReference(self)
        func modeButton(_ target: Mode, _ icon: String, _ name: String) -> Button {
            let button = Button(icon: icon, "flat", "np-small", "mode-button") {
                guard let player = reference.value else { return }
                player.select(player.mode == target ? .artwork : target)
            }
            button.tooltip(name)
            return button
        }
        func menuButton() -> Widget {
            MenuButton(icon: "view-more-horizontal-symbolic", "flat", "np-small") { reference.value?.menu() ?? Menu([]) }
                .tooltip("More")
        }
        func closeButton() -> Widget {
            Button(icon: "go-down-symbolic", "flat", "np-small") { [app] in app.navigator.showsPlayer = false }
                .tooltip("Close Player")
        }
        let app = app
        let lyrics = modeButton(.lyrics, "format-justify-left-symbolic", "Lyrics")
        let visualizer = modeButton(.visualizer, "music-waveform-symbolic", "Visualizer")
        let sideLyrics = modeButton(.lyrics, "format-justify-left-symbolic", "Lyrics")
        let sideVisualizer = modeButton(.visualizer, "music-waveform-symbolic", "Visualizer")
        modeButtons = [.lyrics: lyrics, .visualizer: visualizer]
        sideModeButtons = [.lyrics: sideLyrics, .visualizer: sideVisualizer]

        toolbar.append(Box.horizontal(spacing: 4) {
            menuButton()
            Self.djButton(app)
            toolbarShuffle
        }.hexpand().halign(GTK_ALIGN_START))
        toolbar.append(closeButton())
        toolbar.append(Box.horizontal(spacing: 4) {
            toolbarRepeat
            lyrics
            visualizer
        }.hexpand().halign(GTK_ALIGN_END))
        toolbar.css("np-toolbar")

        let queue = Button(icon: "view-list-symbolic", "flat", "np-small") { reference.value?.toggleQueueColumn() }
        queue.tooltip("Up Next")
        queueToggle = queue
        sideToolbar.append(sideLyrics)
        sideToolbar.append(sideVisualizer)
        sideToolbar.append(Self.djButton(app))
        sideToolbar.append(menuButton())
        sideToolbar.append(queue)
        sideToolbar.append(closeButton())
        sideToolbar.css("np-toolbar").halign(GTK_ALIGN_CENTER)
        for child in [sideLyrics, sideVisualizer, queue] { child.margin(horizontal: 6, vertical: 0) }
    }

    private var sideModeButtons: [Mode: Button] = [:]
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
