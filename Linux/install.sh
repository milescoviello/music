#!/bin/sh
# Builds Music for Linux and installs it for this user: the `music` command, its
# launcher entry and its icon. PREFIX moves it (default ~/.local).
#
#   Linux/install.sh               build in release and install
#   Linux/install.sh --uninstall   remove what it installed (settings and downloads stay)
#
# SWIFT_BUILD_FLAGS is passed to `swift build`, for toolchains that need a linker flag.
set -eu

ID=com.milescoviello.Music
PREFIX=${PREFIX:-$HOME/.local}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SIZES="64 128 256 512"

uninstall() {
    rm -f "$PREFIX/bin/music" "$PREFIX/share/applications/$ID.desktop"
    for size in $SIZES; do rm -f "$PREFIX/share/icons/hicolor/${size}x$size/apps/$ID.png"; done
    refresh
    echo "Removed. Settings are in ~/.config/music.plist, the library cache and downloads in ~/.local/share/$ID."
}

refresh() {
    command -v update-desktop-database >/dev/null && update-desktop-database -q "$PREFIX/share/applications" 2>/dev/null || true
    # A changed folder is what tells a running desktop to look again. No icon cache is
    # written: one in ~/.local would hide icons that other apps add there later.
    touch "$PREFIX/share/icons/hicolor" 2>/dev/null || true
}

case "${1:-}" in
    --uninstall) uninstall; exit 0 ;;
    "") ;;
    *) sed -n '2,9s/^# \{0,1\}//p' "$0"; exit 0 ;;
esac

# What the build links against, by pkg-config name, with the package that provides it
# on Fedora / Debian and Ubuntu / Arch.
missing=""
for module in gtk4 libadwaita-1 epoxy libavformat libavcodec libswresample libavutil libpulse rubberband libsecret-1; do
    pkg-config --exists "$module" 2>/dev/null || missing="$missing $module"
done
if ! command -v swift >/dev/null; then
    echo "Swift 6 is needed: https://www.swift.org/install/linux/ (or Fedora's swift-lang)." >&2
    exit 1
fi
if [ -n "$missing" ]; then
    cat >&2 <<EOF
Missing development files for:$missing

  Fedora:         sudo dnf install gtk4-devel libadwaita-devel libepoxy-devel ffmpeg-free-devel pulseaudio-libs-devel rubberband-devel libsecret-devel
  Debian, Ubuntu: sudo apt install libgtk-4-dev libadwaita-1-dev libepoxy-dev libavformat-dev libavcodec-dev libswresample-dev libpulse-dev librubberband-dev libsecret-1-dev
  Arch:           sudo pacman -S gtk4 libadwaita libepoxy ffmpeg libpulse rubberband libsecret
EOF
    exit 1
fi

# Swift.org toolchains can link the Swift runtime in, so the binary keeps working after
# a toolchain update; distribution packages (Fedora's swift-lang) ship it shared only.
static=""
toolchain=$(dirname "$(readlink -f "$(command -v swift)")")/..
if [ -e "$toolchain/lib/swift_static/linux/libswiftCore.a" ]; then
    static="--static-swift-stdlib"
fi

cd "$ROOT"
# shellcheck disable=SC2086
swift build -c release --product music $static ${SWIFT_BUILD_FLAGS:-}
binary=$(swift build -c release --product music $static ${SWIFT_BUILD_FLAGS:-} --show-bin-path)/music

install -Dm755 "$binary" "$PREFIX/bin/music"
# The launcher entry names the binary by path: ~/.local/bin is not on every session's PATH.
mkdir -p "$PREFIX/share/applications"
sed "s|^Exec=music$|Exec=$PREFIX/bin/music|" "Linux/Resources/$ID.desktop" > "$PREFIX/share/applications/$ID.desktop"
for size in $SIZES; do
    install -Dm644 "Linux/Resources/icons/hicolor/${size}x$size/apps/$ID.png" "$PREFIX/share/icons/hicolor/${size}x$size/apps/$ID.png"
done
refresh

echo "Installed $PREFIX/bin/music. Start it from the app launcher (Music), or run: $PREFIX/bin/music"
