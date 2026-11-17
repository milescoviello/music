#!/usr/bin/env python3
"""Copies the Phosphor icons the app draws with into Linux/Resources/symbols and writes the
SF Symbol -> Phosphor table to Linux/Sources/MusicLogic/UI/Components/SymbolTable.swift.

    python3 -I tools/symbols.py <path to @phosphor-icons/core package>

The phone names its icons by SF Symbol; SF Symbols may not be used off Apple's platforms,
so the Linux app draws each with the Phosphor icon (MIT) closest to it, by the same name."""
import os, sys

# SF Symbol (without .fill) -> Phosphor name. A ".fill" SF name takes Phosphor's fill weight.
MAP = {
    "house": "house", "square.stack": "stack", "square.stack.3d.up": "stack",
    "rectangle.stack": "stack-simple", "arrow.down.circle": "arrow-circle-down",
    "arrow.down.circle.dotted": "circle-dashed", "magnifyingglass": "magnifying-glass",
    "music.note.list": "playlist", "music.microphone": "microphone-stage",
    "music.mic": "microphone", "music.mic.circle": "microphone", "music.note": "music-note",
    "music.note.house": "house-line", "clock.arrow.circlepath": "clock-counter-clockwise",
    "chart.bar": "chart-bar", "chart.bar.xaxis": "chart-bar-horizontal",
    "chart.line.uptrend.xyaxis": "chart-line-up", "guitars": "guitar",
    "dot.radiowaves.left.and.right": "broadcast", "waveform.path.ecg": "pulse",
    "folder": "folder", "heart": "heart", "heart.slash": "heart-break", "sparkles": "sparkle",
    "sparkles.rectangle.stack": "sparkle", "text.magnifyingglass": "list-magnifying-glass",
    "airplane": "airplane", "stethoscope": "stethoscope", "square.on.square": "copy",
    "arrow.down.heart": "hand-heart", "gearshape": "gear-six", "shuffle": "shuffle",
    "shuffle.circle": "shuffle", "repeat": "repeat", "repeat.1": "repeat-once",
    "play": "play", "pause": "pause", "forward": "fast-forward", "backward": "rewind",
    "forward.end": "skip-forward", "backward.end": "skip-back", "play.circle": "play-circle",
    "pause.circle": "pause-circle", "quote.bubble": "chat-centered-text", "photo": "image",
    "photo.badge.exclamationmark": "image-broken", "waveform": "waveform",
    "waveform.path": "waveform", "list.bullet": "list-bullets",
    "list.bullet.indent": "text-indent", "desktopcomputer": "desktop", "ellipsis": "dots-three",
    "ellipsis.circle": "dots-three-circle", "chevron.left": "caret-left",
    "chevron.right": "caret-right", "chevron.down": "caret-down", "chevron.up": "caret-up",
    "xmark": "x", "xmark.circle": "x-circle", "plus": "plus", "plus.circle": "plus-circle",
    "minus.circle": "minus-circle", "star": "star", "star.leadinghalf.filled": "star-half",
    "info.circle": "info", "pin": "push-pin", "pin.slash": "push-pin-slash", "trash": "trash",
    "pencil": "pencil-simple", "checkmark": "check", "checkmark.circle": "check-circle",
    "checkmark.seal": "seal-check", "speaker": "speaker-none", "speaker.wave.3": "speaker-high",
    "arrow.up.arrow.down": "arrows-down-up", "square.and.arrow.up": "export",
    "text.append": "list-plus", "text.insert": "list-plus", "text.badge.plus": "list-plus",
    "timer": "timer", "moon": "moon", "moon.zzz": "moon-stars", "moon.slash": "moon",
    "person.2": "users", "person.wave.2": "user-sound", "person.2.wave.2": "users-three",
    "wand.and.stars": "magic-wand", "infinity": "infinity", "globe": "globe", "tag": "tag",
    "face.smiling": "smiley", "flame": "flame", "snowflake": "snowflake", "sun.max": "sun",
    "building.2": "buildings", "ticket": "ticket", "die.face.5": "dice-five",
    "play.rectangle": "monitor-play", "play.rectangle.on.rectangle": "monitor-play",
    "wifi.slash": "wifi-slash", "wifi.exclamationmark": "wifi-x", "network.slash": "wifi-slash",
    "antenna.radiowaves.left.and.right.slash": "wifi-slash",
    "exclamationmark.triangle": "warning", "questionmark.circle": "question",
    "arrow.clockwise": "arrow-clockwise", "arrow.triangle.2.circlepath": "arrows-clockwise",
    "arrow.uturn.backward": "arrow-u-up-left", "arrow.up.right.square": "arrow-square-out",
    "arrow.up.left.and.arrow.down.right": "arrows-out",
    "slider.horizontal.3": "sliders-horizontal", "slider.vertical.3": "sliders",
    "gobackward.10": "clock-counter-clockwise", "goforward.10": "clock-clockwise",
    "hand.tap": "hand-tap", "iphone.radiowaves.left.and.right": "device-mobile-speaker",
    "point.topleft.down.to.point.bottomright.curvepath": "path",
    "rectangle.3.group": "squares-four", "textformat.abc": "text-aa", "translate": "translate",
    "text.quote": "quotes", "gauge.with.dots.needle.67percent": "gauge",
    "books.vertical": "books", "calendar": "calendar-blank", "music.quarternote.3": "music-notes",
    "opticaldisc": "disc", "film": "film-strip", "record.circle": "record",
    "line.3.horizontal.decrease": "funnel-simple", "arrow.down.to.line": "download-simple",
    "icloud.slash": "cloud-slash", "person.crop.circle": "user-circle", "lock": "lock",
    "music.note.tv": "television", "mic": "microphone", "radio": "radio",
    "headphones": "headphones", "hifispeaker": "speaker-hifi", "airplayaudio": "speaker-hifi",
    "airplay.audio": "speaker-hifi", "square.grid.2x2": "squares-four", "list.number": "list-numbers",
    "clock": "clock", "magnifyingglass.circle": "magnifying-glass", "arrow.left": "arrow-left",
    "arrow.right": "arrow-right", "sidebar.left": "sidebar-simple", "rectangle.portrait.and.arrow.right": "sign-out",
    "power": "power", "bolt": "lightning", "dial.medium": "gauge", "eye": "eye", "eye.slash": "eye-slash",
}

def main(package):
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(repo, "Linux/Resources/symbols")
    os.makedirs(out, exist_ok=True)
    wanted = set()
    for name in MAP.values():
        wanted.add((name, False))
        wanted.add((name, True))
    missing = []
    for name, fill in sorted(wanted):
        weight = "fill" if fill else "regular"
        source = os.path.join(package, "assets", weight, f"{name}-fill.svg" if fill else f"{name}.svg")
        if not os.path.exists(source):
            missing.append(source)
            continue
        target = os.path.join(out, f"ph-{name}{'-fill' if fill else ''}-symbolic.svg")
        with open(source) as f, open(target, "w") as g:
            g.write(f.read())
    with open(os.path.join(package, "LICENSE")) as f, open(os.path.join(out, "LICENSE-Phosphor.txt"), "w") as g:
        g.write(f.read())
    lines = ["// Written by tools/symbols.py: the phone's SF Symbol names, and the Phosphor icon",
             "// the Linux app draws for each.", "", "enum SymbolTable {",
             "    static let phosphor: [String: String] = ["]
    for sf in sorted(MAP):
        lines.append(f'        "{sf}": "{MAP[sf]}",')
    lines += ["    ]", "}", ""]
    swift = os.path.join(repo, "Linux/Sources/MusicLogic/UI/Components/SymbolTable.swift")
    with open(swift, "w") as f:
        f.write("\n".join(lines))
    print(len(os.listdir(out)), "files;", "missing:", missing or "none")

main(sys.argv[1])
