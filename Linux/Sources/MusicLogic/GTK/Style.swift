import CGtk

/// The app's look: dark, as the phone is, with its one accent colour — and the handful of
/// classes the screens use for artwork, cards and the player.
@MainActor
enum Style {
    /// The phone's `Color.appTint`.
    static let tint = ArtworkStore.RGB(red: 0.98, green: 0.28, blue: 0.36)

    static func install() {
        // The phone forces dark; a music app's artwork reads best on black.
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), ADW_COLOR_SCHEME_FORCE_DARK)

        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(
            gdk_display_get_default(),
            OpaquePointer(provider),
            guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
        )
    }

    private static let css = """
    :root {
        --accent-bg-color: #fa475c;
        --accent-fg-color: #ffffff;
        --accent-color: #ff6b7c;
    }

    .accent { color: var(--accent-color); }

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
    .card-title { font-weight: 600; }
    .card-subtitle { opacity: 0.6; font-size: 0.9em; }
    gridview > child { padding: 4px; border-radius: 12px; }
    gridview > child:hover { background-color: alpha(currentColor, 0.06); }

    /* Shelves on Home and artist pages. */
    .shelf-title { font-size: 1.25em; font-weight: 800; }
    .page-title { font-size: 2em; font-weight: 800; }
    .page-subtitle { opacity: 0.65; }

    /* Song rows. */
    .song-row { padding: 6px 12px; }
    .song-row .title.current { color: var(--accent-color); }
    .song-number { opacity: 0.45; font-feature-settings: "tnum"; min-width: 24px; }
    .song-meta { opacity: 0.45; font-size: 0.9em; font-feature-settings: "tnum"; }

    /* The mini player. */
    .mini-player { padding: 6px 12px; }
    .mini-player .title { font-weight: 600; }
    .progress-line { min-height: 2px; background-color: var(--accent-bg-color); }

    /* The full player. */
    .now-playing { background-color: #000000; color: #ffffff; }
    /* Plexamp's sizes: its title lines 15 pixels, 20 side by side; its transport 60. */
    .now-playing .np-meta button, .now-playing .np-meta label { font-size: 15px; }
    .now-playing .np-meta.large button, .now-playing .np-meta.large label { font-size: 20px; }
    .now-playing .np-title { font-weight: 700; }
    .now-playing .np-album { color: alpha(#ffffff, 0.6); }
    .now-playing .detail-line { font-size: 12px; opacity: 0.55; }
    .np-transport button { color: #ffffff; }
    .np-transport .np-skip { min-width: 60px; min-height: 60px; padding: 0; border-radius: 30px; -gtk-icon-size: 20px; }
    .np-transport .np-play { min-width: 60px; min-height: 60px; padding: 0; border-radius: 30px; -gtk-icon-size: 22px;
                             background-color: alpha(#ffffff, 0.15); }
    .np-transport .np-play:hover { filter: brightness(1.25); }
    .now-playing .np-small { min-width: 40px; min-height: 40px; padding: 0; border-radius: 20px; -gtk-icon-size: 18px;
                             color: alpha(#ffffff, 0.7); }
    .now-playing .np-small.active, .now-playing .np-small.selected { color: var(--accent-color); }
    .np-hover { background: linear-gradient(to top, alpha(#000000, 0.55), transparent); border-radius: 0 0 12px 12px; }
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

    /* Rating stars and hearts. */
    .star { color: alpha(currentColor, 0.35); padding: 2px; min-width: 0; min-height: 0; }
    .star.filled { color: var(--accent-color); }

    /* Chips: filters, quick picks. */
    .chip { border-radius: 9999px; padding: 4px 12px; }

    .badge { background-color: var(--accent-bg-color); color: white; border-radius: 9999px;
             padding: 0 6px; font-size: 0.75em; font-weight: 700; min-width: 12px; }
    """
}
