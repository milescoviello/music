"""Lyrics for a song that has none, from LRCLIB, saved as a `.lrc` beside it.

LRCLIB (lrclib.net) is the open lyrics database plexlyrics filled the library's `.lrc`
files from, and this asks it the way plexlyrics did, for one song at a time from the app.

The length decides. Searching a title brings back the album cut, the radio edit, the
extended mix and the live take, often all under the same name, and timed lyrics for the
wrong one drift out of step within a verse. So only a recording within a few seconds of
the file's length is taken; timed lyrics before plain ones, then the nearest length. A
song LRCLIB marks instrumental gets nothing written, and the app says so.
"""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from .lyricsfile import Refused, read_text, timed_lines, words

BASE = "https://lrclib.net/api"
# LRCLIB asks every client to say what it is.
USER_AGENT = "sonic (https://github.com/milescoviello/music)"
# How far a recording's length may be from the file's and still be the same recording.
TOLERANCE = 3.0

# What a title carries that LRCLIB's usually does not: "(Remastered 2024)", "[Live]",
# " - 2011 Remaster", "(feat. ...)".
_NOISE = re.compile(
    r"\s*[\(\[][^\)\]]*\b(remaster(ed)?|live|version|edit|mix|mono|stereo|feat\.?|ft\.?|explicit|"
    r"bonus|deluxe|demo|acoustic)\b[^\)\]]*[\)\]]|\s+-\s+.*\b(remaster(ed)?|version|edit|mix|live)\b.*$",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class Found:
    text: str           # LRC, or plain lines
    synced: bool
    instrumental: bool = False


def _ask(path: str, query: dict, open_url) -> object:
    url = f"{BASE}/{path}?{urllib.parse.urlencode(query)}"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with open_url(request, timeout=15) as reply:
            return json.load(reply)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise Refused(502, f"LRCLIB answered {error.code}.") from error
    except (urllib.error.URLError, OSError, ValueError) as error:
        raise Refused(502, f"Couldn't reach LRCLIB: {error}") from error


def clean(title: str) -> str:
    return _NOISE.sub("", title).strip() or title


def best(candidates: list, duration: float) -> dict | None:
    """The candidate for a file `duration` seconds long, or None: within `TOLERANCE`,
    with words or marked instrumental; timed first, then the nearest length."""
    near = []
    for item in candidates:
        if not isinstance(item, dict):
            continue
        length = item.get("duration")
        if duration and isinstance(length, (int, float)) and abs(length - duration) > TOLERANCE:
            continue
        if not (item.get("syncedLyrics") or item.get("plainLyrics") or item.get("instrumental")):
            continue
        near.append(item)
    if not near:
        return None
    return min(near, key=lambda item: (
        not item.get("syncedLyrics"),
        abs((item.get("duration") or duration) - duration),
    ))


def find(title: str, artist: str, album: str, duration: float, open_url=urllib.request.urlopen) -> Found | None:
    """LRCLIB's lyrics for the song, or None when it has none for this recording."""
    seconds = round(duration)
    exact = _ask("get", {"track_name": title, "artist_name": artist, "album_name": album, "duration": seconds}, open_url)
    candidates = [exact] if isinstance(exact, dict) else []
    choice = best(candidates, duration)
    if choice is None:
        for name in dict.fromkeys([title, clean(title)]):
            found = _ask("search", {"track_name": name, "artist_name": artist}, open_url)
            choice = best(found if isinstance(found, list) else [], duration)
            if choice:
                break
    if choice is None:
        return None
    if choice.get("syncedLyrics"):
        return Found(choice["syncedLyrics"], synced=True)
    if choice.get("plainLyrics"):
        return Found(choice["plainLyrics"], synced=False)
    return Found("", synced=False, instrumental=True)


def lrc_file(found: Found, title: str, artist: str, album: str, duration: float) -> str:
    """The `.lrc` to write: plexlyrics' headers, then the lines."""
    minutes, seconds = divmod(max(0.0, duration), 60)
    headers = [f"[ti:{title}]", f"[ar:{artist}]", f"[al:{album}]", f"[length:{int(minutes):02d}:{seconds:05.2f}]",
               "[by:LRCLIB via sonic]"]
    body = "\n".join(line.rstrip() for line in found.text.replace("\r\n", "\n").split("\n")).strip("\n")
    return "\n".join(headers) + "\n" + body + "\n"


def save_for(song_path: str, title: str, artist: str, album: str, duration: float,
             open_url=urllib.request.urlopen) -> tuple[Found | None, list[tuple[int | None, str]]]:
    """Finds lyrics for the song at `song_path` and writes them beside it as `<name>.lrc`.
    Returns what was found and its lines; nothing is written for no match or an
    instrumental. Refuses a song that has a lyrics file with words in it already."""
    if has_lyrics_file(song_path):
        raise Refused(409, "This song has lyrics already. Open them again.")
    found = find(title, artist, album, duration, open_url)
    if found is None or found.instrumental:
        return found, []
    lines = write_beside(song_path, found, title, artist, album, duration)
    return (found, lines) if lines else (None, [])


def has_lyrics_file(song_path: str) -> bool:
    sidecar = Path(song_path).with_suffix(".lrc")
    return sidecar.is_file() and bool(words(read_text(sidecar))[0])


def write_beside(song_path: str, found: Found, title: str, artist: str, album: str,
                 duration: float) -> list[tuple[int | None, str]]:
    """`found` written beside the song as `<name>.lrc`; its lines, or none if it had none."""
    source = Path(song_path)
    sidecar = source.with_suffix(".lrc")
    text = lrc_file(found, title, artist, album, duration)
    lines, _ = timed_lines(text)
    if not lines:
        return []
    copy = source.with_name(f".{sidecar.name}.sonic-lyrics")
    try:
        copy.write_text(text, encoding="utf-8")
        copy.replace(sidecar)
    except PermissionError as error:
        raise Refused(403, "The NAS won't let this folder be written to. Its owner there "
                           "needs to be the music share's user.") from error
    finally:
        copy.unlink(missing_ok=True)
    return lines
