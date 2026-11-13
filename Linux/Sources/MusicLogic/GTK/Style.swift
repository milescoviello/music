import CGtk
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// The app's look: dark, as the phone is, with its one accent colour — and the handful of
/// classes the screens use for artwork, cards and the player.
@MainActor
enum Style {
    /// The phone's `Color.appTint`.
    static let tint = ArtworkStore.RGB(red: 0.98, green: 0.28, blue: 0.36)

    static func install() {
        // The phone forces dark; a music app's artwork reads best on black.
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), ADW_COLOR_SCHEME_FORCE_DARK)

        installFonts()
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, isSlowMachine ? css + lighter : css)
        gtk_style_context_add_provider_for_display(
            gdk_display_get_default(),
            OpaquePointer(provider),
            guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
        )
    }

    /// Two cores or fewer (the 2009 MacBook): the soft shadows under every cover and the
    /// player bar are left out. Each is a blur its GPU worked out again for every frame of a
    /// scroll, for dozens of covers at once.
    static let isSlowMachine = ProcessInfo.processInfo.activeProcessorCount <= 2

    private static let lighter = """
    .card-button .artwork, gridview > child .artwork { box-shadow: none; }
    .player-bar { box-shadow: inset 0 1px alpha(#ffffff, 0.14); }
    .artwork.player { box-shadow: 0 4px 10px alpha(black, 0.4); }
    """

    /// Inter, which the app ships so it looks the same on every desktop: installed beside
    /// the app's data by `install.sh`, or read from the source tree while developing.
    /// Fontconfig is asked for it by name, so the app needs no build of its own against it.
    private static func installFonts() {
        typealias AddFile = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> Int32
        guard let library = dlopen("libfontconfig.so.1", RTLD_NOW),
              let symbol = dlsym(library, "FcConfigAppFontAddFile")
        else { return }
        let add = unsafeBitCast(symbol, to: AddFile.self)
        let folders = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/com.milescoviello.Music/fonts"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Resources/fonts").standardized,
        ]
        for name in ["InterVariable.ttf", "InterVariable-Italic.ttf"] {
            guard let folder = folders.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) })
            else { continue }
            _ = add(nil, folder.appendingPathComponent(name).path)
        }
    }

    /// The accent follows the backdrop's colours: light enough to read as text on the
    /// dark glass, and a deeper shade under white type on a button.
    private static let accent: OpaquePointer = {
        let provider = gtk_css_provider_new()!
        gtk_style_context_add_provider_for_display(
            gdk_display_get_default(), OpaquePointer(provider), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 2)
        )
        return OpaquePointer(provider)
    }()

    private static var accentCSS = ""

    static func setAccent(_ colour: VisualizerPalette.RGB?) {
        guard let colour else {
            load("")
            return
        }
        let (h, s, _) = hsl(colour)
        let saturation = min(max(s, 0.45), 0.85)
        let text = rgb(h, saturation, 0.7)
        let fill = rgb(h, saturation, 0.42)
        func css(_ c: (Double, Double, Double)) -> String {
            "rgb(\(Int(c.0 * 255)), \(Int(c.1 * 255)), \(Int(c.2 * 255)))"
        }
        load(":root { --accent-color: \(css(text)); --accent-bg-color: \(css(fill)); }")
    }

    /// Only when it differs: every load restyles every widget the window has.
    private static func load(_ css: String) {
        guard css != accentCSS else { return }
        accentCSS = css
        gtk_css_provider_load_from_string(UnsafeMutablePointer(accent), css)
    }

    static func hsl(_ c: VisualizerPalette.RGB) -> (h: Double, s: Double, l: Double) {
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

    static func rgb(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
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

    private static let css = """
    :root {
        --accent-bg-color: #fa475c;
        --accent-fg-color: #ffffff;
        --accent-color: #ff6b7c;
    }

    .accent { color: var(--accent-color); }

    /* The recap's headline number. */
    .recap-big { font-size: 56px; font-weight: 800; }

    /* A row being dragged to a new place in its list. */
    row.dragging { background-color: alpha(var(--accent-bg-color), 0.18); }

    /* The visualiser's name, shown briefly when it changes. */
    .visualizer-name {
        background: alpha(black, 0.45);
        color: alpha(white, 0.75);
        border-radius: 9999px;
        padding: 5px 10px;
        font-size: smaller;
        font-weight: 600;
    }
    .dim { opacity: 0.55; }
    .dimmer { opacity: 0.4; }
    .numeric { font-feature-settings: "tnum"; }

    /* Artwork: rounded, clipped, with a quiet placeholder and initials. */
    .artwork { border-radius: 8px; }
    .artwork.thumb { border-radius: 6px; }
    .artwork.player { border-radius: 12px; box-shadow: 0 12px 32px alpha(black, 0.5); }
    .artwork.round { border-radius: 9999px; }
    .artwork.flat-corners { border-radius: 0; }
    .artwork-placeholder { background-color: alpha(currentColor, 0.08); }
    .monogram { font-weight: 600; opacity: 0.45; }

    /* Cards in grids and shelves. */
    .card-button { padding: 6px; border-radius: 12px; background: none; }
    .card-button:hover { background-color: alpha(currentColor, 0.06); }
    /* The Autoplay card that is chosen, ringed as the phone rings it. */
    .card-button.suggested-action { background-color: alpha(var(--accent-bg-color), 0.16); box-shadow: inset 0 0 0 2px var(--accent-color); color: #ffffff; }
    .card-title { font-weight: 600; }
    .card-subtitle { opacity: 0.6; font-size: 0.9em; }
    gridview > child { padding: 4px; border-radius: 12px; }
    gridview > child:hover { background-color: alpha(currentColor, 0.06); }

    /* Shelves on Home and artist pages. */
    .shelf-title { font-size: 1.4em; font-weight: 800; letter-spacing: -0.2px; }
    .see-all { color: var(--accent-color); font-weight: 600; }

    /* A light refresh (his "make the app look a bit better on Linux"): the phone's tinted
       symbols in rows and the sidebar, a little depth under artwork, and cards that answer
       the pointer. */
    .row-icon { color: var(--accent-color); }
    .row-chevron { opacity: 0.35; }
    .navigation-sidebar > row { border-radius: 10px; margin: 1px 6px; }
    .navigation-sidebar > row:selected { background-color: alpha(var(--accent-bg-color), 0.18); }
    .navigation-sidebar > row:selected image { color: var(--accent-color); }
    .navigation-sidebar > row:selected label { font-weight: 700; }
    .card-button .artwork, gridview > child .artwork { box-shadow: 0 6px 18px alpha(black, 0.35); }
    .card-button:hover .artwork, gridview > child:hover .artwork { filter: brightness(1.12); }
    .card-button:active .artwork { filter: brightness(0.92); }
    .mini-player { background-color: alpha(white, 0.03); border-top: 1px solid alpha(white, 0.07); }
    .page-title { font-size: 2em; font-weight: 800; }
    .page-subtitle { opacity: 0.65; }

    /* Song rows. */
    .song-row { padding: 6px 12px; }
    .song-row .title.current { color: var(--accent-color); }
    .song-number { opacity: 0.45; font-feature-settings: "tnum"; min-width: 24px; }
    .song-meta { opacity: 0.45; font-size: 0.9em; font-feature-settings: "tnum"; }
    .play-on-banner { padding: 6px 10px; border-radius: 10px; background-color: alpha(var(--accent-bg-color), 0.25); color: #ffffff; }
    .selection-bar { padding: 10px 12px; border-radius: 12px; background-color: alpha(currentColor, 0.06); }
    .alphabet-rail { background-color: alpha(currentColor, 0.06); border-radius: 10px; padding: 4px 0; }
    .alphabet-letter { min-width: 22px; min-height: 0; padding: 0 2px; font-size: 10px; font-weight: 700; color: var(--accent-color); }

    /* The mini player. */
    .mini-player { padding: 6px 12px; }
    .mini-player .title { font-weight: 600; }
    .progress-line { min-height: 2px; background-color: var(--accent-bg-color); }

    /* The full player. */
    .now-playing { background-color: transparent; color: #ffffff; }
    /* Plexamp's own sizes at its desktop zoom of 0.8: title lines 15 (20 side by side),
       the codec line 13, the transport 60 with 20 icons, toolbar icons 28, queue rows 59
       with 46 covers — each times 0.8. */
    .now-playing .np-meta button, .now-playing .np-meta label { font-size: 12px; min-height: 0; padding-top: 0; padding-bottom: 0; }
    .now-playing .np-meta.large button, .now-playing .np-meta.large label { font-size: 16px; }
    .now-playing .np-title { font-weight: 700; }
    .now-playing .np-album { color: alpha(#ffffff, 0.6); }
    .now-playing .np-codec { font-size: 10.5px; font-weight: 300; color: alpha(#ffffff, 0.6); }
    .now-playing .np-star { font-size: 11px; min-width: 0; min-height: 0; padding: 0 1px; color: alpha(#ffffff, 0.6); }
    .now-playing .np-star.filled { color: var(--accent-color); }
    .now-playing .np-heart { min-width: 0; min-height: 0; padding: 0 2px; -gtk-icon-size: 12px; color: alpha(#ffffff, 0.6); }
    .now-playing .np-heart.filled { color: var(--accent-color); }
    .now-playing .np-source-heading { font-size: 9.5px; font-weight: 600; color: alpha(#ffffff, 0.5); }
    .now-playing .np-source { font-size: 11px; font-weight: 500; color: alpha(#ffffff, 0.85); }
    .now-playing .desktop-seekbar .time { font-size: 10px; font-weight: 700; opacity: 1; }
    .np-transport button { color: #ffffff; }
    .np-transport .np-skip { min-width: 48px; min-height: 48px; padding: 0; border-radius: 24px; -gtk-icon-size: 16px; }
    .np-transport.roomy .np-skip { margin-left: 16px; margin-right: 16px; }
    .np-transport .np-play { min-width: 48px; min-height: 48px; padding: 0; border-radius: 24px; -gtk-icon-size: 18px;
                             background-color: alpha(#ffffff, 0.15); }
    .np-transport .np-play:hover { filter: brightness(1.25); }
    .now-playing .np-small { min-width: 30px; min-height: 30px; padding: 0; border-radius: 15px; -gtk-icon-size: 16px;
                             color: alpha(#ffffff, 0.7); }
    .now-playing .np-small.active, .now-playing .np-small.selected { color: var(--accent-color); }
    .now-playing .np-toolbar menubutton > button { min-width: 30px; min-height: 30px; padding: 0; }

    /* Plexamp's queue: three tabs over the list, the chosen one underlined. */
    .queue-tabs .queue-tab { font-size: 10px; font-weight: 700; letter-spacing: 0.5px; color: alpha(#ffffff, 0.55);
                             border-radius: 0; min-height: 28px; box-shadow: inset 0 -1px alpha(#ffffff, 0.12); background: none; }
    .queue-tabs .queue-tab.selected, .queue-tabs .queue-tab:checked { color: #ffffff; box-shadow: inset 0 -2px #ffffff; background: none; }
    .queue-pane row { padding: 0; min-height: 0; }
    .queue-row { min-height: 47px; padding: 0 4px; }
    .queue-title { font-size: 11.5px; }
    .queue-artist { font-size: 10px; color: alpha(#ffffff, 0.55); }
    .queue-stars { font-size: 8.5px; color: alpha(#ffffff, 0.45); }
    .queue-heading { font-size: 10px; font-weight: 700; color: alpha(#ffffff, 0.55); }
    .queue-more { min-width: 26px; min-height: 26px; padding: 0; color: alpha(#ffffff, 0.55); }
    .now-playing .source-caption { font-size: 0.75em; font-weight: 700; opacity: 0.5; }
    .now-playing .source-title { font-size: 0.9em; font-weight: 600; opacity: 0.85; }
    .now-playing .time { font-size: 0.85em; opacity: 0.6; font-feature-settings: "tnum"; }
    .transport button { color: #ffffff; }
    .transport .play { min-width: 64px; min-height: 64px; border-radius: 9999px;
                       background-color: #ffffff; color: #000000; }
    .transport .play:hover { background-color: alpha(#ffffff, 0.85); }
    .transport .active { color: var(--accent-color); }
    .mode-button { color: alpha(#ffffff, 0.6); }
    .mode-button.selected { color: var(--accent-color); }
    .link-button { padding: 0 2px; min-height: 0; }
    .now-playing list, .now-playing list > row { background: none; }
    .now-playing list > row:hover { background-color: alpha(#ffffff, 0.06); }
    .resume-strip { background-color: alpha(#ffffff, 0.12); border-radius: 9999px; padding: 4px 12px; }

    /* Lyrics. */
    .lyric-line { font-size: 1.5em; font-weight: 800; opacity: 0.35; }
    .lyric-line.current { opacity: 1; }
    .lyric-line.past { opacity: 0.55; }
    /* The line the next tap times, while timing lyrics by hand. */
    .lyric-line.lyric-marked { opacity: 1; color: var(--accent-color); }
    .lyrics-timing { background-color: alpha(black, 0.4); border-radius: 14px; padding: 8px; }
    .lyric-translation { font-size: 1.05em; font-style: italic; opacity: 0.6; }
    .lyric-note { font-size: 0.8em; opacity: 0.4; }

    /* Rating stars and hearts. */
    .star { color: alpha(currentColor, 0.35); padding: 2px; min-width: 0; min-height: 0; }
    .star.filled { color: var(--accent-color); }

    /* Chips: filters, quick picks. */
    .chip { border-radius: 9999px; padding: 4px 12px; }

    .badge { background-color: var(--accent-bg-color); color: white; border-radius: 9999px;
             padding: 0 6px; font-size: 0.75em; font-weight: 700; min-width: 12px; }

    /* Music videos: the player's Song | Video switch, the picture, YouTube rows. */
    .video-switch { background-color: alpha(#ffffff, 0.12); border-radius: 9999px; padding: 3px; margin-top: 4px; }
    .video-switch button { border-radius: 9999px; min-width: 68px; min-height: 24px; padding: 0 10px;
                           font-size: 0.85em; font-weight: 700; color: alpha(#ffffff, 0.8);
                           background: none; box-shadow: none; }
    .video-switch button:checked { background-color: #ffffff; color: #000000; }
    .now-playing .video-note { font-size: 0.8em; color: alpha(#ffffff, 0.6); }
    .video-surface { background-color: #000000; border-radius: 10px; }
    .video-window .video-surface { border-radius: 0; }
    .video-window { background-color: #000000; }
    .video-controls { background: linear-gradient(to bottom, transparent, alpha(#000000, 0.8)); color: #ffffff; }
    .video-controls button { color: #ffffff; }
    .video-controls .video-play { min-width: 52px; min-height: 52px; background-color: #ffffff; color: #000000; }
    .video-window-title { font-weight: 700; font-size: 1.1em; color: #ffffff; }
    .video-window-subtitle, .video-time { color: alpha(#ffffff, 0.7); font-size: 0.85em; }
    .video-error { color: #ffffff; font-weight: 600; }
    .video-thumb { border-radius: 6px; }
    .video-length { background-color: alpha(#000000, 0.75); color: #ffffff; border-radius: 3px;
                    padding: 0 4px; font-size: 0.75em; font-weight: 700; font-feature-settings: "tnum"; }
    .video-row { padding: 4px; }
    .video-title-chosen { color: var(--accent-color); font-weight: 700; }
    .np-video-full { background-color: alpha(#000000, 0.45); color: #ffffff; margin: 6px; }

    /* The redesign: everything over the cover's colours (WindowBackdrop), the sidebar and the
       player bar as frosted glass, the pages clear, cards and lists as lighter glass. */
    :root {
        --window-bg-color: transparent;
        --view-bg-color: transparent;
        --headerbar-bg-color: transparent;
        --headerbar-backdrop-color: transparent;
        --headerbar-shade-color: transparent;
        --headerbar-darker-shade-color: transparent;
        --sidebar-bg-color: alpha(#000000, 0.24);
        --sidebar-backdrop-color: alpha(#000000, 0.24);
        --sidebar-shade-color: transparent;
        --sidebar-border-color: alpha(#ffffff, 0.07);
        --card-bg-color: alpha(#ffffff, 0.07);
        --card-shade-color: alpha(#000000, 0.18);
        --thumbnail-bg-color: alpha(#ffffff, 0.07);
        --popover-bg-color: rgb(24, 24, 31);
        --dialog-bg-color: rgb(24, 24, 31);
    }
    window, popover, dialog, tooltip { font-family: "Inter Variable", Inter, sans-serif; }
    window.background { background-color: rgb(10, 10, 14); }
    headerbar { background: none; box-shadow: none; }
    .sidebar-pane { background-color: alpha(#000000, 0.24); box-shadow: inset -1px 0 alpha(#ffffff, 0.07); }
    .navigation-sidebar { background: none; }
    .navigation-sidebar > row { border-radius: 10px; margin: 1px 8px; padding: 1px 4px; }
    .navigation-sidebar > row:hover { background-color: alpha(#ffffff, 0.06); }
    .navigation-sidebar > row:selected { background-color: alpha(#ffffff, 0.13); }
    .sidebar-heading { font-size: 11px; font-weight: 700; letter-spacing: 0.8px; color: alpha(#ffffff, 0.55); }
    .page-heading { font-size: 34px; font-weight: 800; letter-spacing: -0.8px; }
    .shelf-title { font-size: 1.4em; font-weight: 750; letter-spacing: -0.3px; }
    list.boxed-list { background-color: alpha(#ffffff, 0.06); box-shadow: inset 0 0 0 1px alpha(#ffffff, 0.06); border-radius: 14px; }
    list.boxed-list > row { background: none; }
    list.boxed-list > row:hover { background-color: alpha(#ffffff, 0.05); }
    popover > contents, popover > arrow { background-color: alpha(rgb(22, 22, 29), 0.96); box-shadow: inset 0 0 0 1px alpha(#ffffff, 0.08); }
    popover > contents { border-radius: 14px; }
    .glass { background-color: alpha(#ffffff, 0.075); border-radius: 12px; box-shadow: inset 0 0 0 1px alpha(#ffffff, 0.07); }
    .glass:hover { background-color: alpha(#ffffff, 0.11); }
    .history-buttons button { min-width: 32px; padding: 0 4px; }
    .history-buttons button:disabled { opacity: 0.35; }
    button.pill.suggested-action { color: #ffffff; }
    button.top-result { padding: 18px; border-radius: 16px; }
    .top-name { font-size: 26px; font-weight: 800; letter-spacing: -0.5px; }
    .top-kind { color: alpha(#ffffff, 0.65); font-weight: 550; }
    button.top-play { min-width: 48px; min-height: 48px; }
    .artist-hero { border-radius: 18px; background-color: alpha(#ffffff, 0.05); }
    .hero-scrim { background-image: linear-gradient(to bottom, transparent 45%, alpha(#000000, 0.6)); }
    .hero-name { font-size: 52px; font-weight: 800; letter-spacing: -1.2px; color: #ffffff; }
    .library-tabs button.library-tab { font-weight: 600; padding: 4px 12px; border-radius: 9999px; color: alpha(#ffffff, 0.7); }
    .library-tabs button.library-tab:checked { background-color: alpha(#ffffff, 0.14); color: #ffffff; }
    .hero-kind { font-size: 12px; font-weight: 700; letter-spacing: 0.8px; color: alpha(#ffffff, 0.65); }
    .hero-title { font-size: 40px; font-weight: 800; letter-spacing: -1px; }
    .hero-artist { font-size: 1.15em; font-weight: 650; color: var(--accent-color); padding: 0; }
    .hero-meta { color: alpha(#ffffff, 0.65); }
    button.glass-pill { background-color: alpha(#ffffff, 0.1); box-shadow: inset 0 0 0 1px alpha(#ffffff, 0.08); }
    button.glass-pill:hover { background-color: alpha(#ffffff, 0.16); }
    list.track-list { background: none; }
    list.track-list > row { border-radius: 8px; padding: 2px 8px; }
    list.track-list > row:hover { background-color: alpha(#ffffff, 0.07); }
    .side-panel { padding: 14px 16px; }
    .side-heading { font-size: 12px; font-weight: 700; letter-spacing: 0.6px; color: alpha(#ffffff, 0.6); margin-bottom: 2px; }
    .side-fact { font-weight: 550; }
    .side-detail { font-size: 0.85em; color: alpha(#ffffff, 0.6); }
    button.side-link { padding: 4px 6px; margin: 0 -6px; border-radius: 8px; }
    .player-bar { background-color: alpha(#ffffff, 0.08); padding: 10px 18px 8px 14px;
                  box-shadow: inset 0 1px alpha(#ffffff, 0.14), 0 -10px 30px alpha(#000000, 0.22); }
    .player-bar .bar-title { font-weight: 700; }
    .player-bar .bar-artist { font-size: 0.88em; color: alpha(#ffffff, 0.65); }
    .player-bar .bar-heart { color: alpha(#ffffff, 0.6); min-width: 32px; min-height: 32px; padding: 0; }
    .player-bar .bar-heart.filled { color: var(--accent-color); }
    .player-bar .bar-play { min-width: 40px; min-height: 40px; padding: 0; background-color: #ffffff; color: #000000; }
    .player-bar .np-small { min-width: 32px; min-height: 32px; padding: 0; color: alpha(#ffffff, 0.7); }
    .player-bar .np-small.active { color: var(--accent-color); }
    .player-bar .desktop-seekbar .time { font-size: 10px; font-weight: 600; }
    .jump-tile { padding: 0; min-height: 56px; border-radius: 10px; }
    .station-tile { padding: 10px 14px; min-height: 48px; }
    .tile-title { font-weight: 650; }
    .tile-subtitle { font-size: 0.85em; color: alpha(#ffffff, 0.6); }
    .station-icon { color: var(--accent-color); background-color: alpha(var(--accent-bg-color), 0.28); border-radius: 10px; padding: 9px; }
    .tile-play { min-width: 34px; min-height: 34px; padding: 0; background-color: var(--accent-bg-color); color: #ffffff; }
    """
}
