import CGtk
import Foundation
import Observation

/// Which visualiser is up: remembered under the phone's key, and shared by the player and
/// Select Visualizer.
@MainActor
@Observable
final class VisualizerChoice {
    static let shared = VisualizerChoice()

    var program: VisualizerProgram {
        didSet { UserDefaults.standard.set(program.name, forKey: VisualizerProgram.storageKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        program = .named(defaults.string(forKey: VisualizerProgram.storageKey) ?? VisualizerProgram.defaultName)
    }
}

/// The player's visualiser mode: Plexamp's visualisers, as the phone's `VisualizerView`
/// shows them where the artwork would be.
///
/// - **Click** to go back to the artwork; **right-click** (or long-press) for Select
///   Visualizer.
/// - **Swipe** or scroll sideways for the next or previous visualiser.
/// - **Paused**, a visualiser that is not meant to stay up while idle gives way to the
///   artwork until the music starts again.
///
/// Without GL, Plexamp's Spectrum is drawn with cairo instead, from the same feed.
@MainActor
final class VisualizerPane {
    let root: Overlay
    private let app: AppState
    private let choice = VisualizerChoice.shared
    private let feed: VisualizerFeed
    private let canvas: VisualizerCanvas
    private let stack = Stack(transition: GTK_STACK_TRANSITION_TYPE_CROSSFADE)
    private var spectrum: DrawingArea?
    private let name = Label("", "visualizer-name")
    private let nameRevealer: Revealer
    private var nameGeneration = 0
    private var tickID: guint = 0
    private var lastFrame: gint64 = 0
    private var pending: Double = 0
    private var lastSwitch: gint64 = 0
    private var colours: [VisualizerPalette.RGB] = []
    private var shownProgram: String?

    /// The motion is defined per frame — gravity, smoothing, the history and the
    /// crossfade all count frames, as Plexamp's do at the browser's 60 — so the feed
    /// steps at 60 a second whatever the display's refresh.
    private static let frame = 1.0 / 60

    init(app: AppState, onTap: @escaping @MainActor () -> Void = {}) {
        self.app = app
        feed = VisualizerFeed.shared(buffer: app.spectrumBuffer)
        feed.player = app.player
        canvas = VisualizerCanvas(feed: feed, program: VisualizerChoice.shared.program)

        let artwork = ArtworkView(app, size: .full, side: nil, shape: .player)
        let artworkFrame = Widget(gtk_aspect_frame_new(0.5, 0.5, 1, 0)!)
        gtk_aspect_frame_set_child(artworkFrame.widget.cast(), artwork.root.widget)
        artworkFrame.hexpand().vexpand()

        stack.add(canvas.area, name: "canvas")
        stack.add(artworkFrame, name: "artwork")
        stack.hexpand().vexpand()
        nameRevealer = Revealer(name.halign(GTK_ALIGN_CENTER), transition: GTK_REVEALER_TRANSITION_TYPE_CROSSFADE)
        gtk_revealer_set_transition_duration(nameRevealer.widget.cast(), 400)
        nameRevealer.halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_START).margins(top: 8).canTarget(false)
        root = Overlay(stack)
        root.add(nameRevealer)
        root.keep(self)

        let reference = WeakReference(self)
        canvas.onFailure = { reference.value?.fallBackToSpectrum() }
        root.onClick(onTap)
        root.onContextClick { _, _ in
            guard let pane = reference.value else { return }
            VisualizerPicker.present(over: pane.root)
        }
        installSwipes()

        // Animated only while on screen: an FFT nobody is looking at is pure battery.
        root.onMap {
            guard let pane = reference.value, pane.tickID == 0 else { return }
            app.player.startSpectrum()
            pane.lastFrame = 0
            pane.tickID = tick(pane.root) { reference.value?.step() ?? false }
        }
        root.onUnmap {
            guard let pane = reference.value, pane.tickID != 0 else { return }
            gtk_widget_remove_tick_callback(pane.root.widget, pane.tickID)
            pane.tickID = 0
        }

        root.observe { artwork.show(app.player.currentSong?.coverArt, fallback: app.player.currentSong?.album) }
        // The chosen program, and the artwork in its place while paused if it is not
        // one that stays up.
        root.observe {
            guard let pane = reference.value else { return }
            let program = pane.choice.program
            if pane.canvas.program != program { pane.canvas.program = program }
            if let shown = pane.shownProgram, shown != program.name { pane.flashName(program.name) }
            pane.shownProgram = program.name
            let idle = !app.player.isPlaying && !program.displayWhenIdle
            pane.stack.visibleName = idle ? "artwork" : (pane.spectrum == nil ? "canvas" : "spectrum")
        }
        // Plexamp sends the palette when the visualiser appears and on every track change
        // after, which is what fades it from one cover's colours to the next.
        root.observe {
            let cover = app.player.currentSong?.coverArt
            Task { @MainActor in
                guard let colours = await VisualizerArtworkPalette.colours(for: cover, artwork: app.artwork) else { return }
                reference.value?.colours = colours
                reference.value?.feed.setPalette(colours)
            }
        }
        // The seekbar's loudness for this track, which Soundprint draws. A track whose
        // levels have not arrived keeps the last track's, as Plexamp keeps them.
        root.observe {
            guard let id = app.player.currentSong?.id, let levels = app.seekbarLevels.levels(for: id) else { return }
            reference.value?.feed.setLoudness(VisualizerLoudness.texels(from: levels))
        }
    }

    /// One frame of the display: as many 60 Hz steps of the feed as are due, then a draw.
    private func step() -> Bool {
        guard stack.visibleName != "artwork" else {
            lastFrame = 0
            return true
        }
        let now = g_get_monotonic_time()
        if lastFrame == 0 { lastFrame = now - gint64(Self.frame * 1_000_000) }
        pending += Double(now - lastFrame) / 1_000_000
        lastFrame = now
        // After a stall, one step rather than a burst of catching up.
        if pending > 0.1 { pending = Self.frame }
        var stepped = false
        // A millisecond of slack, so a 60 Hz display steps every frame despite jitter.
        while pending >= Self.frame - 0.001 {
            feed.tick()
            pending -= Self.frame
            stepped = true
        }
        if stepped {
            if let spectrum { spectrum.redraw() } else { canvas.queueRender() }
        }
        return true
    }

    // MARK: - Switching

    private func installSwipes() {
        let reference = WeakReference(self)
        let swipe = gtk_gesture_swipe_new()!
        Signal.connect(swipe, "swipe", point: { velocity, _ in
            guard abs(velocity) > 400 else { return }
            reference.value?.cycle(forward: velocity < 0)
        })
        gtk_widget_add_controller(root.widget, swipe.cast())

        // Touchpads scroll sideways; each deliberate flick is one step.
        let scroll = gtk_event_controller_scroll_new(
            GtkEventControllerScrollFlags(GTK_EVENT_CONTROLLER_SCROLL_HORIZONTAL.rawValue | GTK_EVENT_CONTROLLER_SCROLL_DISCRETE.rawValue)
        )!
        Signal.connect(scroll, "scroll", scroll: { dx, _ in
            guard dx != 0 else { return false }
            reference.value?.cycle(forward: dx > 0)
            return true
        })
        gtk_widget_add_controller(root.widget, scroll)
    }

    /// The next or previous visualiser, at most one per half second however the gesture
    /// arrives.
    private func cycle(forward: Bool) {
        let now = g_get_monotonic_time()
        guard now - lastSwitch > 500_000 else { return }
        lastSwitch = now
        choice.program = forward ? choice.program.next : choice.program.previous
    }

    /// The name, briefly, whenever the visualiser changes: useful the moment it changes
    /// and clutter after.
    private func flashName(_ text: String) {
        name.text = text
        nameRevealer.isRevealed = true
        nameGeneration += 1
        let generation = nameGeneration
        let reference = WeakReference(self)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard let pane = reference.value, pane.nameGeneration == generation else { return }
            pane.nameRevealer.isRevealed = false
        }
    }

    // MARK: - Without GL

    private func fallBackToSpectrum() {
        let reference = WeakReference(self)
        let area = DrawingArea { cairo, width, height in
            reference.value?.drawSpectrum(cairo, width: width, height: height)
        }
        area.hexpand().vexpand()
        spectrum = area
        stack.add(area, name: "spectrum")
        feed.select(VisualizerData(frequency: true, peaks: true, alpha: 0.3))
        if stack.visibleName == "canvas" { stack.visibleName = "spectrum" }
    }

    /// Plexamp's Spectrum: 64 bands in the cover's colours, with falling peaks.
    private func drawSpectrum(_ cairo: Cairo, width: Double, height: Double) {
        let texels = feed.host.frequencyTexels
        let count = VisualizerSpectrum.bandCount
        guard texels.count >= count * 2, width > 0, height > 0 else { return }
        let slot = width / Double(count)
        let barWidth = max(1, slot * 0.7)
        // The band values top out a little under 0.48.
        let scale = height / 0.48
        for band in 0..<count {
            let colour = colours.isEmpty
                ? VisualizerPalette.RGB(Style.tint.red * 255, Style.tint.green * 255, Style.tint.blue * 255)
                : colours[band * colours.count / count]
            let rgb = ArtworkStore.RGB(red: colour.r / 255, green: colour.g / 255, blue: colour.b / 255)
            let level = min(height, Double(texels[band]) * scale)
            let x = Double(band) * slot + (slot - barWidth) / 2
            cairo.color(rgb, alpha: 0.9)
            cairo.roundedRectangle(x, height - level, barWidth, max(level, 2), radius: barWidth / 3)
            cairo.fill()
            let peak = min(height, Double(texels[count + band]) * scale)
            cairo.color(rgb, alpha: 1)
            cairo.rectangle(x, height - peak - 3, barWidth, 2)
            cairo.fill()
        }
    }
}

/// Plexamp's Select Visualizer: every visualiser, the current one ticked. Choosing one
/// switches to it there and then, behind the dialog, which stays until closed — so
/// several can be tried in a row.
@MainActor
enum VisualizerPicker {
    /// `onSelect` runs on every choice: from the artwork, choosing a visualiser also
    /// shows it.
    static func present(over parent: Widget, onSelect: @escaping @MainActor () -> Void = {}) {
        let choice = VisualizerChoice.shared
        let list = ListBox()
        var checks: [String: Icon] = [:]
        var current: Widget?
        for program in VisualizerProgram.all {
            let check = Icon("object-select-symbolic").css("accent")
            checks[program.name] = check
            let row = Box.horizontal(spacing: 12) {
                Icon("music-waveform-symbolic").css("dim")
                Label(program.name).xalign(0).hexpand()
                check
            }.margin(horizontal: 12, vertical: 10)
            list.append(row) {
                choice.program = program
                onSelect()
            }
            if program == choice.program { current = row }
        }
        list.observe {
            let selected = choice.program.name
            for (name, check) in checks { check.isVisible = name == selected }
        }
        let content = ScrolledWindow(Clamp(list.margin(12), maximum: 460)).vexpand()
        _ = Dialogs.sheet("Select Visualizer", content: content, width: 380, height: 560, over: parent)
        // Focusing the current row scrolls it into view, as the phone's list opens on it.
        if let current, let row = gtk_widget_get_parent(current.widget) { gtk_widget_grab_focus(row) }
    }
}
