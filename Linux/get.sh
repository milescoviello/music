#!/bin/sh
# Installs or updates Music for Linux from its newest ready-made build, for this user: the
# `music` command, its launcher entry, its icon and its typeface. No Swift, no building.
#
#   curl -fsSL https://raw.githubusercontent.com/milescoviello/music/main/Linux/get.sh | sh
#
# Once installed it is also `music-update`, and the app's own Settings > Updates does the
# same. A Music that is open keeps running the old build until it is reopened.
#
# The build runs on the system's GTK 4 (4.20 or newer), libadwaita, FFmpeg 8, PulseAudio,
# Rubber Band, libcurl and epoxy; a library missing is named before anything is installed.
set -eu
URL=${MUSIC_RELEASE_URL:-https://github.com/milescoviello/music/releases/download/linux-latest/Music-linux-x86_64.tar.gz}

[ "$(uname -m)" = x86_64 ] || { echo "Only x86_64 builds are made." >&2; exit 1; }
for tool in curl tar sha256sum; do
    command -v "$tool" >/dev/null || { echo "$tool is needed." >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
echo "Downloading the newest Music..."
curl -fsSL "$URL" -o "$work/music.tar.gz"
curl -fsSL "$URL.sha256" -o "$work/music.sha256"
expected=$(cut -d' ' -f1 "$work/music.sha256")
actual=$(sha256sum "$work/music.tar.gz" | cut -d' ' -f1)
[ "$expected" = "$actual" ] || { echo "The download is damaged (checksum differs); nothing was installed." >&2; exit 1; }
tar -xzf "$work/music.tar.gz" -C "$work"

missing=$(ldd "$work/Music/music" 2>/dev/null | sed -n 's/^[[:space:]]*\([^ ]*\) => not found.*/\1/p' | tr '\n' ' ')
if [ -n "$missing" ]; then
    echo "Missing libraries: $missing" >&2
    echo "Install GTK 4, libadwaita, FFmpeg, PulseAudio, Rubber Band, libcurl and epoxy from your distribution, then run this again." >&2
    exit 1
fi

sh "$work/Music/Linux/install.sh" --prebuilt
