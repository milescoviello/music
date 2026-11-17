import CGtk
import Foundation

/// The phone's icons, asked for by the phone's own SF Symbol names, so a screen ported from
/// SwiftUI keeps its `systemImage:` strings and the shared code's symbols (stations,
/// Autoplay) need no Linux names of their own. SF Symbols may only be drawn on Apple's
/// platforms, so each is drawn with the Phosphor icon (MIT) nearest to it
/// (`SymbolTable`, written by `tools/symbols.py`); a `.fill` name takes Phosphor's filled
/// weight.
@MainActor
enum Symbol {
    /// The icon name to give GTK: `house` → `ph-house-symbolic`, `heart.fill` →
    /// `ph-heart-fill-symbolic`. A name with no twin draws a question mark, not nothing.
    nonisolated static func icon(_ sf: String) -> String {
        var base = sf
        var fill = false
        if base.hasSuffix(".fill") {
            base.removeLast(5)
            fill = true
        }
        guard let name = SymbolTable.phosphor[base] else { return "ph-question-symbolic" }
        return "ph-\(name)\(fill ? "-fill" : "")-symbolic"
    }

    /// Any icon name a screen gives GTK: a GNOME one the app used before it took the phone's
    /// look is drawn as the phone's symbol for the same thing, so every button changes
    /// over at once; anything else is passed through.
    nonisolated static func resolve(_ name: String) -> String {
        guard name.hasSuffix("-symbolic"), !name.hasPrefix("ph-"),
              let sf = gnome[String(name.dropLast(9))]
        else { return name }
        return icon(sf)
    }

    /// GNOME's names (without `-symbolic`), and the phone's symbol for each.
    nonisolated private static let gnome: [String: String] = [
        "media-playback-start": "play.fill", "media-playback-pause": "pause.fill",
        "media-playlist-shuffle": "shuffle", "media-playlist-repeat": "repeat",
        "media-playlist-repeat-song": "repeat.1", "media-skip-forward": "forward.fill",
        "media-skip-backward": "backward.fill", "media-seek-forward": "goforward.10",
        "media-seek-backward": "gobackward.10", "starred": "star.fill", "music-heart": "heart.fill",
        "folder-download": "arrow.down.circle", "view-refresh": "arrow.clockwise", "object-select": "checkmark",
        "network-offline": "wifi.slash", "audio-x-generic": "music.note", "view-more": "ellipsis",
        "view-more-horizontal": "ellipsis", "list-add": "plus", "view-list": "list.bullet",
        "user-trash": "trash", "network-wireless": "dot.radiowaves.left.and.right",
        "music-waveform": "waveform", "go-next": "chevron.right", "go-previous": "chevron.left",
        "go-down": "chevron.down", "go-up": "chevron.up", "go-home": "house",
        "system-search": "magnifyingglass", "edit-find": "magnifyingglass", "media-optical": "opticaldisc",
        "format-justify-left": "quote.bubble", "document-open-recent": "clock.arrow.circlepath",
        "weather-clear-night": "moon", "weather-snow": "snowflake", "music-tag": "tag", "folder": "folder",
        "folder-open": "folder", "folder-music": "folder", "document-save": "arrow.down.to.line",
        "avatar-default": "person.crop.circle", "window-close": "xmark", "video-x-generic": "film",
        "camera-video": "film", "video-display": "desktopcomputer", "computer": "desktopcomputer",
        "system-users": "person.2", "mail-send": "paperplane", "list-remove": "minus.circle",
        "emblem-system": "gearshape", "edit-undo": "arrow.uturn.backward",
        "dialog-warning": "exclamationmark.triangle", "dialog-question": "questionmark.circle",
        "dialog-information": "info.circle", "audio-input-microphone": "mic", "x-office-calendar": "calendar",
        "view-sort-descending": "arrow.up.arrow.down", "view-restore": "arrow.down.right.and.arrow.up.left",
        "view-fullscreen": "arrow.up.left.and.arrow.down.right", "view-dual": "rectangle.stack",
        "view-continuous": "list.bullet", "system-log-out": "rectangle.portrait.and.arrow.right",
        "selection-mode": "checkmark.circle", "preferences-desktop-locale": "globe",
        "music-equalizer": "slider.vertical.3", "mark-location": "mappin", "list-drag-handle": "line.3.horizontal",
        "face-smile": "face.smiling", "emblem-ok": "checkmark.circle.fill", "edit-copy": "square.on.square",
        "audio-volume-high": "speaker.wave.3.fill", "applications-multimedia": "music.note",
        "adw-external-link": "arrow.up.right.square",
    ]

    /// The icons' folder: installed beside the app's data by `install.sh`, or read from the
    /// source tree while developing, as the fonts are.
    static func install() {
        let folders = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/\(Desktop.applicationID)/symbols"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../Resources/symbols").standardized,
        ]
        guard let folder = folders.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("ph-house-symbolic.svg").path) })
        else { return }
        gtk_icon_theme_add_search_path(gtk_icon_theme_get_for_display(gdk_display_get_default()), folder.path)
    }
}
