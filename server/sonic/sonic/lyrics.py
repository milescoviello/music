"""Searching the library by a line of its lyrics.

Navidrome keeps the lyrics it found in each file's tags in `media_file.lyrics`, as JSON: a
list of `{"lang", "line": [{"start", "value"}], "synced"}`. Subsonic serves them one track
at a time, so a phrase cannot be found through the API without asking for every track.
This reads them from the same database copy the library is read from, keeps them in
memory, and answers in milliseconds.

Most of the library's lyrics are not in that column at all: they are `.lrc` files beside
the songs (tens of thousands, from plexlyrics), which Navidrome reads when asked and never
stores, and which it prefers to the tags. So those are read too (`with_sidecars`), in
Navidrome's order, and take a song's place in the index. Reading them all over the share
takes minutes; each one's size and time are remembered with its lines (`SidecarCache`),
and only a file that changed is read again.

Matching ignores case, accents and punctuation. Best first: the phrase inside one line,
then the phrase running from one line into the next, then every word of it in one line,
then every word of it somewhere in the song.
"""

from __future__ import annotations

import json
import logging
import os
import sqlite3
import unicodedata
from dataclasses import dataclass
from pathlib import Path

from .lyricsfile import SIDECARS, read_text, timed_lines

log = logging.getLogger("sonic.lyrics")


@dataclass(frozen=True)
class LyricTrack:
    id: str
    title: str
    artist: str
    lines: tuple[str, ...]
    # Milliseconds into the track each line starts, for synced lyrics; None otherwise.
    # What lets the app play from the line that matched.
    starts: tuple[int | None, ...] = ()


def normalised(text: str) -> str:
    """Lower case, no accents, punctuation gone, runs of space made one. Letters of every
    script stay, so Japanese lyrics are searched as they are written."""
    decomposed = unicodedata.normalize("NFKD", text.casefold())
    kept = []
    for char in decomposed:
        category = unicodedata.category(char)
        if category.startswith("M"):
            continue  # accents, once decomposed
        kept.append(char if category[0] in "LN" else " ")
    return " ".join("".join(kept).split())


def parse(raw: str | None) -> tuple[str, ...]:
    return parse_timed(raw)[0]


def parse_timed(raw: str | None) -> tuple[tuple[str, ...], tuple[int | None, ...]]:
    """The lines of the column's lyric, in order, without blanks, and when each starts.
    The first lyric only when there are several, since they are usually one song in two
    languages, or synced and unsynced copies of the same words."""
    if not raw:
        return (), ()
    try:
        lyrics = json.loads(raw)
    except ValueError:
        # Older Navidromes stored the text itself.
        lines = tuple(line.strip() for line in raw.splitlines() if line.strip())
        return lines, (None,) * len(lines)
    if not isinstance(lyrics, list) or not lyrics:
        return (), ()
    first = lyrics[0] if isinstance(lyrics[0], dict) else {}
    synced = bool(first.get("synced"))
    lines, starts = [], []
    for line in first.get("line", []) or []:
        if not isinstance(line, dict):
            continue
        value = str(line.get("value", "")).strip()
        if not value:
            continue
        start = line.get("start")
        lines.append(value)
        starts.append(int(start) if synced and isinstance(start, (int, float)) else None)
    return tuple(lines), tuple(starts)


def read(connection: sqlite3.Connection) -> list[LyricTrack]:
    columns = {row[1] for row in connection.execute("pragma table_info(media_file)")}
    if "lyrics" not in columns:
        return []
    missing = "and missing = 0" if "missing" in columns else ""
    tracks = []
    for track_id, title, artist, raw in connection.execute(f"""
        select id, title, artist, lyrics from media_file
        where lyrics is not null and lyrics not in ('', '[]') {missing}
    """):
        lines, starts = parse_timed(raw)
        if lines:
            tracks.append(LyricTrack(id=track_id, title=title or "", artist=artist or "", lines=lines, starts=starts))
    return tracks


# MARK: - Files beside the songs


def from_text(track_id: str, title: str, artist: str, text: str) -> LyricTrack | None:
    """A lyrics file's lines as the index keeps them; None for one with no words."""
    lines, timed = timed_lines(text)
    if not lines:
        return None
    return LyricTrack(
        id=track_id, title=title, artist=artist,
        lines=tuple(value for _, value in lines),
        starts=tuple(start if timed else None for start, _ in lines),
    )


class SidecarCache:
    """Each lyrics file's size and time, and its lines, so a file unchanged since the last
    pass is not read again. Its own small database in the data folder."""

    def __init__(self, path: Path):
        self._db = sqlite3.connect(path)
        self._db.execute(
            "create table if not exists sidecars (path text primary key, key text not null, lines text not null)"
        )

    def all(self) -> dict[str, tuple[str, str]]:
        return {path: (key, lines) for path, key, lines in self._db.execute("select path, key, lines from sidecars")}

    def replace(self, rows: dict[str, tuple[str, str]]) -> None:
        with self._db:
            self._db.execute("delete from sidecars")
            self._db.executemany("insert into sidecars (path, key, lines) values (?, ?, ?)",
                                 [(path, key, lines) for path, (key, lines) in rows.items()])

    def close(self) -> None:
        self._db.close()


def with_sidecars(tracks, embedded: list[LyricTrack], cache_path: Path) -> list[LyricTrack]:
    """`embedded`, with every song that has a lyrics file beside it given that file's
    lines instead: `<name>.lrc`, else `<name>.txt`, the first with words in it. `tracks`
    are the library's (`library.LibraryTrack`: id, title, artist, local path)."""
    by_id = {track.id: track for track in embedded}
    cache = SidecarCache(cache_path)
    try:
        known = cache.all()
        seen: dict[str, tuple[str, str]] = {}
        folders: dict[str, list] = {}
        for track in tracks:
            folders.setdefault(os.path.dirname(track.path), []).append(track)
        read = 0
        for folder, members in folders.items():
            try:
                names = set(os.listdir(folder))
            except OSError:
                continue
            for track in members:
                stem = os.path.splitext(os.path.basename(track.path))[0]
                for suffix in SIDECARS:
                    if stem + suffix not in names:
                        continue
                    path = os.path.join(folder, stem + suffix)
                    try:
                        stat = os.stat(path)
                    except OSError:
                        continue
                    key = f"{stat.st_size}:{stat.st_mtime_ns}"
                    if path in known and known[path][0] == key:
                        stored = json.loads(known[path][1])
                    else:
                        try:
                            text = read_text(Path(path))
                        except OSError:
                            continue
                        read += 1
                        lines, timed = timed_lines(text)
                        stored = [[start if timed else None, value] for start, value in lines]
                    seen[path] = (key, json.dumps(stored, ensure_ascii=False, separators=(",", ":")))
                    if stored:
                        by_id[track.id] = LyricTrack(
                            id=track.id, title=track.title, artist=track.artist,
                            lines=tuple(value for _, value in stored),
                            starts=tuple(start for start, _ in stored),
                        )
                        break       # the first with words in it is what Navidrome serves
        cache.replace(seen)
        log.info("lyrics files: %d beside songs, %d read again", len(seen), read)
    finally:
        cache.close()
    return list(by_id.values())


@dataclass(frozen=True)
class Hit:
    id: str
    title: str
    artist: str
    line: str
    score: int
    at: int | None = None

    def json(self) -> dict:
        return {"id": self.id, "title": self.title, "artist": self.artist, "line": self.line,
                "score": self.score, "at": self.at}


@dataclass(frozen=True)
class _Entry:
    """A track's lines made ready once, at index time, rather than on every search:
    splitting every line into words per query cost 100 ms on the real library."""
    track: LyricTrack
    lines: tuple[str, ...]
    line_words: tuple[frozenset[str], ...]
    words: frozenset[str]


class LyricIndex:
    def __init__(self, tracks: list[LyricTrack]):
        self._tracks = [self._entry(track) for track in tracks]

    @staticmethod
    def _entry(track: LyricTrack) -> _Entry:
        lines = tuple(normalised(line) for line in track.lines)
        line_words = tuple(frozenset(line.split()) for line in lines)
        return _Entry(track, lines, line_words, frozenset().union(*line_words))

    def __len__(self) -> int:
        return len(self._tracks)

    def with_track(self, track: LyricTrack) -> "LyricIndex":
        """A copy with `track`'s lines in place of any it had: for lyrics just saved, so a
        search finds them before the next pass. A copy, as searches read this one from
        other threads."""
        changed = LyricIndex([])
        changed._tracks = [entry for entry in self._tracks if entry.track.id != track.id]
        if track.lines:
            changed._tracks.append(self._entry(track))
        return changed

    def track(self, track_id: str) -> LyricTrack | None:
        return next((entry.track for entry in self._tracks if entry.track.id == track_id), None)

    def search(self, query: str, limit: int = 20) -> list[Hit]:
        wanted = normalised(query)
        if len(wanted) < 3:
            return []
        words = wanted.split()
        hits = []
        for entry in self._tracks:
            found = self._best(entry, wanted, words)
            if found:
                hits.append(found)
        # Best match first; within one, the shorter title, which is likelier the song
        # itself than a live or remixed copy of it, then alphabetical so it is stable.
        hits.sort(key=lambda hit: (-hit.score, len(hit.title), hit.title.casefold(), hit.id))
        return _one_per_song(hits)[:limit]

    @staticmethod
    def _best(entry: _Entry, wanted: str, words: list[str]) -> Hit | None:
        track, lines = entry.track, entry.lines

        def hit(index: int, score: int) -> Hit:
            at = track.starts[index] if index < len(track.starts) else None
            return Hit(track.id, track.title, track.artist, track.lines[index], score, at)

        for index, line in enumerate(lines):
            if wanted in line:
                return hit(index, 4)
        for index in range(len(lines) - 1):
            if wanted in f"{lines[index]} {lines[index + 1]}":
                return hit(index, 3)
        if len(words) > 1 and all(word in entry.words for word in words):
            for index, present in enumerate(entry.line_words):
                if all(word in present for word in words):
                    return hit(index, 2)
            first = next((i for i, present in enumerate(entry.line_words) if words[0] in present), 0)
            return hit(first, 1)
        return None


def _one_per_song(hits: list[Hit]) -> list[Hit]:
    """The library's two folders hold many songs twice; one row each."""
    seen = set()
    unique = []
    for hit in hits:
        key = (normalised(hit.title), normalised(hit.artist))
        if key not in seen:
            seen.add(key)
            unique.append(hit)
    return unique
