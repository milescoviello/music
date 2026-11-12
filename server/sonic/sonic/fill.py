"""`python -m sonic fill-lyrics`: LRCLIB's lyrics for every song in the library that has
none, written beside each as a `.lrc` -- Find Lyrics, for the whole library at once.

Run overnight, by hand or on a timer, not from the service: it is thousands of requests,
a second apart, which is LRCLIB's to answer at its own pace. One request per recording,
not per file: a song in both folders is asked about once and written beside both copies.
A song LRCLIB had nothing for is not asked about again for a month, so a second run is
quick; what each run did is in `data/lyrics-fill.json`, and a summary in its log.
"""

from __future__ import annotations

import json
import logging
import time
from collections import defaultdict
from pathlib import Path

from . import library, lrclib
from . import lyrics as lyric_files
from .config import Config
from .lyrics import normalised
from .lyricsfile import Refused

log = logging.getLogger("sonic.fill")

# Longer than this is a mix or a whole concert, which LRCLIB does not time.
LONGEST = 20 * 60
RETRY_AFTER = 30 * 86_400


def run(config: Config, limit: int | None = None, delay: float = 1.0, sleep=time.sleep,
        find=lrclib.find, now=time.time) -> dict:
    tracks, embedded = library.read_with_lyrics(config)
    with_lyrics = {track.id for track in lyric_files.with_sidecars(
        tracks, embedded, config.data_dir / "lyric-files.db")}
    record_path = config.data_dir / "lyrics-fill.json"
    tried = _load(record_path)

    # One recording, every copy of it: the same title, artist and length to the second.
    recordings: dict[tuple, list] = defaultdict(list)
    for track in tracks:
        if track.id in with_lyrics or not 30 <= track.duration <= LONGEST:
            continue
        recordings[(normalised(track.title), normalised(track.artist), round(track.duration))].append(track)
    def due(copies) -> bool:
        last = tried.get(copies[0].id)
        return last is None or now() - last.get("at", 0) > RETRY_AFTER
    wanted = [copies for copies in recordings.values() if due(copies)]
    if limit is not None:
        wanted = wanted[:limit]
    log.info("%d songs have no lyrics; asking LRCLIB about %d recordings", len(recordings), len(wanted))

    counts = defaultdict(int)
    for number, copies in enumerate(wanted, 1):
        first = copies[0]
        try:
            found = find(first.title, first.artist, first.album, first.duration)
        except Refused as refused:
            counts["errors"] += 1
            log.warning("%s: %s", first.id, refused.message)
            if refused.status == 502 and counts["errors"] >= 20:
                log.error("LRCLIB keeps failing; stopping here")
                break
            sleep(delay * 5)
            continue
        if found is None:
            result = "none"
        elif found.instrumental:
            result = "instrumental"
        else:
            result = "timed" if found.synced else "plain"
            for track in copies:
                try:
                    if not lrclib.has_lyrics_file(track.path):
                        lrclib.write_beside(track.path, found, track.title, track.artist, track.album, track.duration)
                except (Refused, OSError) as error:
                    counts["unwritable"] += 1
                    log.warning("%s: %s", track.id, getattr(error, "message", error))
        counts[result] += 1
        for track in copies:
            tried[track.id] = {"at": now(), "result": result}
        if number % 100 == 0:
            _save(record_path, tried)
            log.info("%d of %d: %s", number, len(wanted), dict(counts))
        sleep(delay)
    _save(record_path, tried)
    summary = {"asked": sum(counts[k] for k in ("timed", "plain", "instrumental", "none")), **counts}
    log.info("done: %s", summary)
    return dict(summary)


def _load(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def _save(path: Path, tried: dict) -> None:
    partial = path.with_suffix(".part")
    partial.write_text(json.dumps(tried))
    partial.replace(path)
