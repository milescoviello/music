import CGtk
import Foundation

/// The pieces of the player the phone's layout (`PhonePlayer`) shares with what came
/// before it: the Song | Video switch and the video's pane, the format line, the strips
/// that say playback resumed part-way or cannot reach the server, and Plexamp's Smooth
/// and Flat backdrops.
@MainActor
enum NowPlaying {
    /// Plexamp's desktop zoom: its pixels to ours. The visualisers are drawn at it.
    static let zoom = 0.8

    /// YouTube Music's Song | Video switch, under where the music is playing from. A right
    /// click is Change Video. Under it, why the cover shows when Video is chosen.
    /// `showVideo` brings the picture forward: choosing Video from the lyrics or the
    /// visualiser is asking to see it.
    static func videoSwitch(
        _ app: AppState,
        showVideo: @escaping @MainActor () -> Void,
        changeVideo: @escaping @MainActor () -> Void
    ) -> Widget {
        let video = app.video
        let songButton = ToggleButton("Song")
        let videoButton = ToggleButton("Video")
        func sync() {
            songButton.isActive = !video.wantsVideo
            videoButton.isActive = video.wantsVideo
        }
        // Connected here rather than in the initialisers, so `sync` can name both. Setting
        // `isActive` back from the service's state only ever lands where it already is.
        Signal.connect(songButton.widget, "toggled") {
            if songButton.isActive { video.setWantsVideo(false) }
            DispatchQueue.main.async { sync() }
        }
        Signal.connect(videoButton.widget, "toggled") {
            if videoButton.isActive {
                video.setWantsVideo(true)
                if video.wantsVideo { showVideo() }
            }
            DispatchQueue.main.async { sync() }
        }
        videoButton.group(with: songButton)
        let pill = Box.horizontal(spacing: 0) {
            songButton
            videoButton
        }.css("video-switch").halign(GTK_ALIGN_CENTER)
        pill.contextMenu {
            guard app.player.currentSong != nil, video.isAvailable else { return nil }
            return Menu([[.action("Change Video…") { changeVideo() }]])
        }
        let note = Label("", "video-note").xalign(0.5)
        let box = Box.vertical(spacing: 2) {
            pill
            note
        }
        box.observe {
            sync()
            box.isVisible = (video.isAvailable || video.wantsVideo) && app.player.currentSong != nil
            var text = ""
            if video.wantsVideo {
                if !video.isAvailable {
                    text = "Videos aren't reachable right now"
                } else if video.showing == .noVideo {
                    text = "No video for this song"
                } else if case .failed = video.showing {
                    text = "The video wouldn't play · playing the song"
                }
            }
            note.text = text
            note.isVisible = !text.isEmpty
        }
        return box
    }

    /// The song's video where the cover goes, with a button and a double click for full
    /// screen.
    static func videoPane(_ app: AppState, fullScreen: @escaping @MainActor () -> Void) -> Widget {
        let surface = VideoSurfaceView(app)
        let full = Button(icon: "view-fullscreen-symbolic", "circular", "np-video-full") { fullScreen() }
        full.tooltip("Full Screen")
        full.halign(GTK_ALIGN_END).valign(GTK_ALIGN_END)
        surface.root.add(full)
        let doubleClick = gtk_gesture_click_new()!
        Signal.connect(doubleClick, "pressed", press: { count, _, _ in
            if count == 2 { fullScreen() }
        })
        gtk_widget_add_controller(surface.root.widget, doubleClick.cast())
        return surface.root
    }

    /// "FLAC · 96 / 24", "MP3 · 320 kbps": for lossless the rate and depth, in Plexamp's
    /// order, are the useful numbers; for a converted stream, that it was converted.
    static func quality(_ app: AppState, _ song: Song) -> String {
        if let video = app.video.soundDescription(for: song) { return video }
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
    static func resumeStrip(_ app: AppState) -> Widget {
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
    static func unreachableStrip(_ app: AppState) -> Widget {
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
}

/// The cover's colours behind the player, drawn as Plexamp's desktop draws them. Except
/// Ultrablur, which is now the window's drifting backdrop (`WindowBackdrop`) showing
/// through, so the player and the pages under it are one surface.
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
            // Ultrablur, the default, is the window's own drifting backdrop, which shows
            // through; Smooth and Flat are drawn here, over it.
            reference.value?.picture.opacity(app.playerSettings.background == .ultrablur ? 0 : 1)
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
