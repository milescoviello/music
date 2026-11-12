"""Lyrics fixed in the app, written back into the file they came from.

The app times lyrics by hand -- every line moved at once, or each line timed as it is
sung -- and sends the result here, because this is the one place with the files. They go
back, as LRC, wherever Navidrome found them, in its order (`LyricsPriority`, by default
".lrc,.txt,embedded"): an `.lrc` beside the song with the same name, which most of the
library's lyrics are and which Navidrome reads afresh on every request; else a `.txt`; else
the song's own tags, which its watcher sees change, scanning the folder again.

A file beside the song is simply replaced. In the song itself only the tags change: it is
copied beside itself, the copy's tags are rewritten, and the copy takes the original's
place only once its audio has been read back and found identical to the original's
(`_audio_checksum`). A save that would have touched one byte of the music is refused.

Which tag: every lyrics tag whose words are the lyrics being fixed, and none other -- a
song can carry a synced and an unsynced copy, or a translation, and only the one on screen
was fixed. Tags whose words differ mean the file changed since the app read it, and the
save is refused rather than guessed at.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import threading
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

# One save at a time: they are rare, by hand, and two at once on one file would race.
_lock = threading.Lock()

# Navidrome's default `LyricsPriority`: files beside the song, in this order, before its tags.
SIDECARS = (".lrc", ".txt")

# `[01:02.34]`, `[1:02]`, `[01:02:345]`; minutes past 59 for a long track.
_STAMP = re.compile(r"\[(\d+):(\d{1,2})(?:[.:](\d{1,3}))?\]")
# `[ar: Glass Harbor]`, `[offset:+120]`: about the lyrics, not a line of them.
_HEADER = re.compile(r"^\[([a-zA-Z#]+):(.*)\]$")


class Refused(Exception):
    """A save that was not made, with an HTTP status and words for the app to show."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


@dataclass(frozen=True)
class Line:
    start: int | None   # milliseconds; None for lyrics saved as words alone
    value: str


@dataclass(frozen=True)
class Request:
    track_id: str
    original: list[str]     # the words of the lyrics being fixed, as the app had them
    synced: bool            # whether those were timed
    lines: list[Line]
    auth: dict[str, str]    # the app's Subsonic sign-in: u, t, s


def request(body: dict) -> Request:
    """`{"id", "original": [str], "synced": bool, "lines": [{"start", "value"}],
    "auth": {"u", "t", "s"}}`, checked."""
    track_id = body.get("id")
    if not isinstance(track_id, str) or not 0 < len(track_id) <= 64:
        raise Refused(400, "id must be a song id")
    original = body.get("original")
    if not isinstance(original, list) or not all(isinstance(line, str) for line in original) or len(original) > 5000:
        raise Refused(400, "original must be the lines as they were")
    synced = body.get("synced")
    if not isinstance(synced, bool):
        raise Refused(400, "synced must be true or false")
    raw = body.get("lines")
    if not isinstance(raw, list) or not 0 < len(raw) <= 5000:
        raise Refused(400, "lines must be between 1 and 5000 lines")
    lines = []
    for item in raw:
        start, value = (item.get("start"), item.get("value")) if isinstance(item, dict) else (None, None)
        timed = isinstance(start, int) and not isinstance(start, bool) and start >= 0
        if not isinstance(value, str) or not (timed or start is None):
            raise Refused(400, "every line needs its words, and a start in milliseconds or none")
        lines.append(Line(start if timed else None, value))
    # Every line timed, or -- words alone -- none.
    if len({line.start is None for line in lines}) > 1:
        raise Refused(400, "every line needs a start, or none of them")
    if lines[0].start is not None and any(later.start < earlier.start for earlier, later in zip(lines, lines[1:])):
        raise Refused(400, "lines must be in time order")
    auth = body.get("auth")
    if not isinstance(auth, dict) or not all(isinstance(auth.get(key), str) and auth.get(key) for key in "uts"):
        raise Refused(401, "Sign in to the server to save lyrics.")
    return Request(track_id, original, synced, lines, {key: auth[key] for key in "uts"})


def check_admin(navidrome_url: str, auth: dict[str, str], open_url=urllib.request.urlopen) -> None:
    """Whoever is saving signed in to Navidrome as one of its admins: writing into the
    library's files is an admin's business, and this service has no accounts of its own."""
    query = urllib.parse.urlencode({**auth, "v": "1.16.1", "c": "sonic", "f": "json", "username": auth["u"]})
    try:
        with open_url(f"{navidrome_url.rstrip('/')}/rest/getUser.view?{query}", timeout=10) as reply:
            answer = json.load(reply).get("subsonic-response", {})
    except (urllib.error.URLError, OSError, ValueError) as error:
        raise Refused(502, f"Couldn't ask the music server who you are: {error}") from error
    if answer.get("status") != "ok":
        raise Refused(401, "The music server didn't accept the sign-in.")
    if not answer.get("user", {}).get("adminRole"):
        raise Refused(403, "Only an admin of the music server can change its files.")


def ask_scan(navidrome_url: str, auth: dict[str, str], open_url=urllib.request.urlopen) -> None:
    """Asks Navidrome to look at the library again, for lyrics in a song's tags: it keeps
    those in its database, and its watcher may miss a change on a network share. A quick
    scan, of folders that changed. Best effort: the watcher, or the next scheduled scan,
    finds it anyway."""
    query = urllib.parse.urlencode({**auth, "v": "1.16.1", "c": "sonic", "f": "json"})
    try:
        with open_url(f"{navidrome_url.rstrip('/')}/rest/startScan.view?{query}", timeout=10):
            pass
    except (urllib.error.URLError, OSError, ValueError):
        pass


def lrc(lines: list[Line]) -> str:
    """The lines as LRC, to the hundredth of a second: what every player reads. Lines
    without times are the words alone, one to a line."""
    if lines and all(line.start is None for line in lines):
        return "\n".join(" ".join(line.value.split()) for line in lines)
    out = []
    for line in lines:
        hundredths = round(max(0, line.start) / 10)
        minutes, rest = divmod(hundredths, 6000)
        seconds, fraction = divmod(rest, 100)
        text = " ".join(line.value.split())
        out.append(f"[{minutes:02d}:{seconds:02d}.{fraction:02d}]{text}")
    return "\n".join(out)


def _milliseconds(match: re.Match) -> int:
    minutes, seconds, fraction = match.groups()
    total = (int(minutes) * 60 + int(seconds)) * 1000
    if fraction:
        # Two digits are hundredths, three thousandths, one a tenth.
        total += int(fraction.ljust(3, "0"))
    return total


def timed_lines(text: str) -> tuple[list[tuple[int | None, str]], bool]:
    """The lines of a lyrics file or tag as a reader sees them -- each with when it starts,
    if it is timed -- without blanks, and whether it is timed. A line stamped twice, a
    chorus sung twice and written once, is two lines, and timed lyrics are put in time
    order, both as Navidrome serves them."""
    timed: list[tuple[int, int, str]] = []
    plain: list[str] = []
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        line = raw.strip()
        stamps = []
        while True:
            match = _STAMP.match(line)
            if not match:
                break
            stamps.append(_milliseconds(match))
            line = line[match.end():].lstrip()
        if not stamps and _HEADER.match(line):
            continue
        value = " ".join(line.split())
        if stamps:
            for stamp in stamps:
                if value:
                    timed.append((stamp, len(timed), value))
        elif value:
            plain.append(value)
    if timed:
        return [(stamp, value) for stamp, _, value in sorted(timed)], True
    return [(None, value) for value in plain], False


def words(text: str) -> tuple[list[str], bool]:
    """`timed_lines`' words alone, made comparable (`_same`)."""
    lines, timed = timed_lines(text)
    return [_same(value) for _, value in lines], timed


def _same(text: str) -> str:
    """For comparing words: one composed form, runs of space made one."""
    return " ".join(unicodedata.normalize("NFC", text).split())


def _matches(text: str, original: list[str], synced: bool) -> bool:
    found, timed = words(text)
    return timed == synced and found == [_same(line) for line in original if _same(line)]


def _replacement(old: str, lines: list[Line]) -> str:
    """The new lines, under the old text's headers -- title, artist, who made them -- but
    not its `[offset:]`, which the app has put into the times."""
    headers = []
    for raw in old.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        header = _HEADER.match(raw.strip())
        if header and header[1].lower() != "offset" and not _STAMP.match(raw.strip()):
            headers.append(raw.strip())
    return "\n".join(headers + [lrc(lines)]) + ("\n" if headers or old.endswith("\n") else "")


def read_text(path: Path) -> str:
    data = path.read_bytes()
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return data.decode("utf-16", errors="replace")
    return data.decode("utf-8-sig", errors="replace")


# MARK: - Tags


def _is_lyrics_key(key: str) -> bool:
    name = key.lower()
    return "lyric" in name and "lyricist" not in name


def _rewrite(audio, original: list[str], synced: bool, lines: list[Line]) -> list[str]:
    """Puts `lines` in every lyrics tag holding `original`. The tags changed, by name."""
    import mutagen._vorbis
    import mutagen.id3
    import mutagen.mp4

    tags = audio.tags
    changed = []
    if isinstance(tags, mutagen.id3.ID3):
        for frame in tags.getall("USLT"):
            if _matches(frame.text, original, synced):
                frame.text = _replacement(frame.text, lines)
                changed.append(f"USLT:{frame.lang}")
    elif isinstance(tags, mutagen.mp4.MP4Tags):
        values = list(tags.get("\xa9lyr", []))
        if any(_matches(value, original, synced) for value in values):
            tags["\xa9lyr"] = [_replacement(value, lines) if _matches(value, original, synced) else value
                               for value in values]
            changed.append("\xa9lyr")
    elif isinstance(tags, mutagen._vorbis.VComment):
        # Vorbis comments: FLAC, Ogg, Opus. Replaced where they stand, by position, so
        # the name keeps its case and its place among the others.
        for index, (key, value) in enumerate(list(tags)):
            if _is_lyrics_key(key) and _matches(value, original, synced):
                tags[index:index + 1] = [(key, _replacement(value, lines))]
                changed.append(key.upper())
    else:
        raise Refused(422, "Lyrics can't be written into this kind of file.")
    return sorted(set(changed))


def _save(audio) -> None:
    import mutagen.id3

    if isinstance(audio.tags, mutagen.id3.ID3):
        # In the version it was, not 2.4 for every file: older players read 2.3 only.
        version = 3 if audio.tags.version[1] == 3 else 4
        audio.save(v2_version=version)
    else:
        audio.save()


def _audio_checksum(path: str) -> str:
    """A digest of what must not change: the audio, tags left out.

    FLAC and MP3 keep their tags ahead of the audio (and MP3 one more at the very end), so
    for them it is the bytes of every audio frame, read straight through -- 98% of the
    songs with lyrics. Anything else, MP4 with its tags in the middle, is Essentia's MD5 of
    the encoded audio packets, which costs decoding the file."""
    with open(path, "rb") as file:
        size = os.fstat(file.fileno()).st_size
        start = _after_id3(file)
        file.seek(start)
        head = file.read(4)
        if head == b"fLaC":
            start, end = _flac_frames(file, start + 4), size
        elif len(head) >= 2 and head[0] == 0xFF and head[1] & 0xE0 == 0xE0:
            end = size - _mp3_trailer(file, size)
        else:
            return _packets_checksum(path)
        digest = hashlib.sha256()
        file.seek(start)
        left = end - start
        while left > 0:
            chunk = file.read(min(left, 1 << 20))
            if not chunk:
                break
            digest.update(chunk)
            left -= len(chunk)
        return digest.hexdigest()


def _after_id3(file) -> int:
    """Where an ID3v2 tag at the start ends: an MP3's, or one put before a FLAC's."""
    file.seek(0)
    header = file.read(10)
    if len(header) < 10 or header[:3] != b"ID3":
        return 0
    size = 0
    for byte in header[6:10]:
        size = (size << 7) | (byte & 0x7F)
    return 10 + size + (10 if header[5] & 0x10 else 0)


def _flac_frames(file, position: int) -> int:
    """Where a FLAC's audio frames start: after its last metadata block."""
    while True:
        file.seek(position)
        header = file.read(4)
        if len(header) < 4:
            raise ValueError("a FLAC file that ends in its metadata")
        position += 4 + int.from_bytes(header[1:4], "big")
        if header[0] & 0x80:
            return position


def _mp3_trailer(file, size: int) -> int:
    """How much of an MP3's end is tags: an ID3v1 tag, and an APEv2 one before it."""
    trailer = 0
    if size >= 128:
        file.seek(size - 128)
        if file.read(3) == b"TAG":
            trailer = 128
    if size - trailer >= 32:
        file.seek(size - trailer - 32)
        footer = file.read(32)
        if footer[:8] == b"APETAGEX":
            length = int.from_bytes(footer[12:16], "little")
            has_header = int.from_bytes(footer[20:24], "little") & 0x80000000
            trailer += length + (32 if has_header else 0)
    return trailer


def _packets_checksum(path: str) -> str:
    import essentia.standard as es

    return es.AudioLoader(filename=path, computeMD5=True)()[3]


def write(path: str, original: list[str], synced: bool, lines: list[Line],
          checksum=_audio_checksum) -> list[str]:
    """Writes `lines` for the song at `path`, in place of the lyrics `original` (synced or
    not, as the app was showing them). Returns what changed. Raises `Refused`."""
    try:
        return _write(path, original, synced, lines, checksum)
    except PermissionError as error:
        # The share's permissions are made up on this side (`file_mode=0775`); a file or
        # folder the NAS has as root's says so only when written to.
        raise Refused(403, "The NAS won't let this folder be written to. Its owner there "
                           "needs to be the music share's user.") from error


def _write(path: str, original: list[str], synced: bool, lines: list[Line], checksum) -> list[str]:
    import mutagen

    if not lines:
        raise Refused(400, "There are no lines to save.")
    if not os.path.isfile(path):
        raise Refused(404, "The song's file isn't there.")

    with _lock:
        source = Path(path)
        for suffix in SIDECARS:
            sidecar = source.with_suffix(suffix)
            if not sidecar.is_file():
                continue
            text = read_text(sidecar)
            if not words(text)[0]:
                continue        # nothing in it, so Navidrome looks further
            if not _matches(text, original, synced):
                raise Refused(409, "The lyrics in the file aren't the ones shown. Open them again and redo the fix.")
            _replace_text(sidecar, _replacement(text, lines))
            return [f"{suffix} beside the song"]

        kind = mutagen.File(path)
        if kind is None or kind.tags is None:
            raise Refused(422, "Lyrics can't be written into this kind of file.")
        # Beside the original, so the swap is a rename on one share, and not an audio
        # name: hidden, and not something the library would take for a new song.
        copy = _beside(source)
        try:
            shutil.copyfile(source, copy)
            audio = type(kind)(copy)
            changed = _rewrite(audio, original, synced, lines)
            if not changed:
                raise Refused(409, "The lyrics in the file aren't the ones shown. Open them again and redo the fix.")
            _save(audio)
            before, after = checksum(str(source)), checksum(str(copy))
            if not before or before != after:
                raise Refused(500, "Saving would have changed the audio, so nothing was saved.")
            os.replace(copy, source)
            return changed
        finally:
            copy.unlink(missing_ok=True)


def _beside(path: Path) -> Path:
    return path.with_name(f".{path.name}.sonic-lyrics")


def _replace_text(path: Path, text: str) -> None:
    """A file of lyrics, replaced whole: written beside it, then renamed over it."""
    copy = _beside(path)
    try:
        copy.write_text(text, encoding="utf-8")
        os.replace(copy, path)
    finally:
        copy.unlink(missing_ok=True)
