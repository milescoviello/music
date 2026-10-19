/// SF Symbols, as the Core names them, to freedesktop icon names, which every Linux icon
/// theme — Adwaita, Breeze, Papirus — draws in its own style.
enum Icons {
    static func named(_ symbol: String) -> String {
        table[symbol] ?? fallback(symbol)
    }

    private static func fallback(_ symbol: String) -> String {
        if symbol.contains("radiowaves") { return "network-wireless-symbolic" }
        if symbol.contains("person") { return "avatar-default-symbolic" }
        if symbol.contains("waveform") { return "audio-x-generic-symbolic" }
        return "audio-x-generic-symbolic"
    }

    private static let table: [String: String] = [
        "repeat": "media-playlist-repeat-symbolic",
        "repeat.1": "media-playlist-repeat-song-symbolic",
        "shuffle": "media-playlist-shuffle-symbolic",
        "moon.zzz": "weather-clear-night-symbolic",
        "moon": "weather-clear-night-symbolic",
        "moon.fill": "weather-clear-night-symbolic",
        "backward.end": "media-skip-backward-symbolic",
        "forward.end": "media-skip-forward-symbolic",
        "square.stack": "media-optical-symbolic",
        "square.stack.3d.up": "media-optical-symbolic",
        "person.wave.2": "avatar-default-symbolic",
        "person.2.wave.2": "system-users-symbolic",
        "person.2": "system-users-symbolic",
        "dot.radiowaves.left.and.right": "network-wireless-symbolic",
        "calendar": "x-office-calendar-symbolic",
        "library": "folder-music-symbolic",
        "waveform.path.ecg": "music-waveform-symbolic",
        "waveform.path": "audio-x-generic-symbolic",
        "clock.arrow.circlepath": "document-open-recent-symbolic",
        "die.face.5": "media-playlist-shuffle-symbolic",
        "guitars": "audio-x-generic-symbolic",
        "point.topleft.down.to.point.bottomright.curvepath": "mark-location-symbolic",
        "sparkles": "starred-symbolic",
        "heart": "music-heart-symbolic",
        "heart.fill": "music-heart-symbolic",
        "music.note": "audio-x-generic-symbolic",
        "music.note.list": "view-list-symbolic",
        "music.mic": "audio-input-microphone-symbolic",
        "play.fill": "media-playback-start-symbolic",
        "pause.fill": "media-playback-pause-symbolic",
        "arrow.down.circle": "folder-download-symbolic",
        "arrow.down.circle.fill": "folder-download-symbolic",
        "house": "go-home-symbolic",
        "magnifyingglass": "system-search-symbolic",
        "gearshape": "emblem-system-symbolic",
        "chart.bar": "view-continuous-symbolic",
    ]
}
