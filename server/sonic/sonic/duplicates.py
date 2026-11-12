"""Albums held in both libraries, side by side, for deduplicating by hand.

The two folders hold much of the same music, and which copy to keep is a call made album
by album: the better format, the complete one, the one with the plays. This lays the copies
out next to each other -- format, bit depth and rate, track count, size, plays, where it is
-- weakest first. It only shows them: nothing here moves, merges or deletes anything.

Read from Navidrome's database in one pass (`library._snapshot`) rather than through the
API, which would take an album's detail for every album to know its format.
"""

from __future__ import annotations

import os
from collections import defaultdict

from .lyrics import normalised

LOSSLESS = {"flac", "alac", "wav", "aiff", "aif", "ape", "wv", "dsf", "dff"}


def _format(codec: str, suffix: str, bit_depth: int, sample_rate: int, bit_rate: int) -> tuple[str, bool]:
    name = (codec or suffix or "?").lower()
    if name in ("aac", "mp4a") and suffix == "m4a":
        name = "aac"
    lossless = name in LOSSLESS or suffix in ("flac", "wav", "aiff") or (suffix == "m4a" and "alac" in name)
    if lossless:
        rate = f"{sample_rate / 1000:g}" if sample_rate else "?"
        return f"{name.upper()} {bit_depth or '?'}/{rate}", True
    return f"{name.upper()} {bit_rate or '?'}", False


def find(connection) -> list[dict]:
    """Every album in more than one library, each copy described, weakest copy first."""
    rows = connection.execute("""
        select mf.album_id, mf.album, coalesce(nullif(mf.album_artist, ''), mf.artist), mf.library_id, l.name,
               mf.suffix, coalesce(mf.codec, ''), coalesce(mf.bit_depth, 0), coalesce(mf.sample_rate, 0),
               coalesce(mf.bit_rate, 0), coalesce(mf.size, 0), coalesce(mf.year, 0), mf.path,
               coalesce((select sum(play_count) from annotation a where a.item_id = mf.id and a.item_type = 'media_file'), 0)
        from media_file mf join library l on l.id = mf.library_id
        where mf.missing = 0
    """).fetchall()
    albums: dict[str, dict] = {}
    for (album_id, album, artist, library_id, library_name, suffix, codec, depth, rate, bit_rate, size,
         year, path, plays) in rows:
        entry = albums.setdefault(album_id, {
            "albumId": album_id, "name": album or "", "artist": artist or "", "libraryId": library_id,
            "library": library_name or "", "tracks": 0, "size": 0, "plays": 0, "year": year or None,
            "folder": os.path.dirname(path or ""), "_formats": defaultdict(int), "_best": (False, 0, 0, 0),
        })
        label, lossless = _format(codec, (suffix or "").lower(), depth, rate, bit_rate)
        entry["tracks"] += 1
        entry["size"] += size
        entry["plays"] += int(plays or 0)
        entry["_formats"][label] += 1
        entry["_best"] = max(entry["_best"], (lossless, depth, rate, bit_rate))

    groups: dict[tuple, list[dict]] = defaultdict(list)
    for entry in albums.values():
        if entry["name"]:
            groups[(normalised(entry["name"]), normalised(entry["artist"]))].append(entry)

    pairs = []
    for copies in groups.values():
        if len({copy["libraryId"] for copy in copies}) < 2:
            continue
        for copy in copies:
            formats = copy.pop("_formats")
            copy["format"] = max(formats, key=formats.get) if len(formats) == 1 else " + ".join(sorted(formats))
            copy["lossless"], copy["bitDepth"], copy["sampleRate"], copy["bitRate"] = copy.pop("_best")
        # Weakest first: lossy before lossless, then fewer bits, a lower rate, fewer tracks.
        copies.sort(key=lambda copy: (copy["lossless"], copy["bitDepth"], copy["sampleRate"], copy["tracks"],
                                      copy["bitRate"], copy["plays"]))
        weakest, strongest = copies[0], copies[-1]
        alike = all((copy["lossless"], copy["bitDepth"], copy["sampleRate"], copy["tracks"]) ==
                    (weakest["lossless"], weakest["bitDepth"], weakest["sampleRate"], weakest["tracks"]) for copy in copies)
        pairs.append({
            "name": strongest["name"], "artist": strongest["artist"], "alike": alike, "copies": copies,
        })
    pairs.sort(key=lambda pair: (normalised(pair["artist"]), normalised(pair["name"])))
    return pairs
