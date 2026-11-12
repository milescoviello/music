"""`python -m sonic scan-damage`: every file in the library read end to end, for the damage
the decoders cannot show -- a stretch of a megabyte or more of nothing but zero bytes where
the audio should be.

Real audio never has one: silence still encodes as frames, each with a header. A copy cut
short and padded out does -- a download or a copy that stopped, the rest of the file left as
zeros -- and plays as a song that stops, or never starts: one in this library had 62 MB of
zeros where its audio should begin, and analysed, decoded and played as nothing. What is
before the audio is skipped, since a FLAC's padding and an MP3's ID3 tag may be zeros by
design. Read at the lowest priority, at night: it is the whole library off the share.
Reports to `data/damage-report.json` and the log.
"""

from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path

from . import library
from .config import Config

log = logging.getLogger("sonic.damage")

BLOCK = 1 << 16
# A megabyte of zeros, in aligned blocks.
RUN = 16


def audio_start(file) -> int:
    """Where a file's audio begins: after an ID3v2 tag, and after a FLAC's metadata."""
    file.seek(0)
    head = file.read(10)
    start = 0
    if head[:3] == b"ID3" and len(head) == 10:
        size = 0
        for byte in head[6:10]:
            size = (size << 7) | (byte & 0x7F)
        start = 10 + size + (10 if head[5] & 0x10 else 0)
    file.seek(start)
    if file.read(4) == b"fLaC":
        start += 4
        while True:
            file.seek(start)
            block = file.read(4)
            if len(block) < 4:
                break
            start += 4 + int.from_bytes(block[1:4], "big")
            if block[0] & 0x80:
                break
    return start


def zero_runs(path: str) -> tuple[int, int]:
    """(where the first megabyte-long run of zeros in the audio starts, how many zero bytes
    the audio has in such runs); (-1, 0) when there is none."""
    zero = bytes(BLOCK)
    first, total, run = -1, 0, 0
    with open(path, "rb") as file:
        start = audio_start(file)
        offset = start - start % BLOCK
        file.seek(offset)
        while chunk := file.read(BLOCK):
            if chunk == zero and offset >= start:
                run += 1
                if run == RUN:
                    if first < 0:
                        first = offset - (RUN - 1) * BLOCK
                    total += RUN * BLOCK
                elif run > RUN:
                    total += BLOCK
            else:
                run = 0
            offset += len(chunk)
    return first, total


def run(config: Config, report: Path | None = None) -> dict:
    tracks = library.read(config)
    report = report or config.data_dir / "damage-report.json"
    damaged, unreadable = [], []
    started = time.time()
    for number, track in enumerate(tracks, 1):
        try:
            first, total = zero_runs(track.path)
        except OSError as error:
            unreadable.append({"id": track.id, "path": track.path, "error": str(error)})
            continue
        if first >= 0:
            size = os.path.getsize(track.path)
            damaged.append({"id": track.id, "path": track.path, "artist": track.artist, "title": track.title,
                            "zerosFrom": first, "zeroBytes": total, "size": size,
                            "share": round(total / size, 3) if size else 0})
            log.warning("damaged: %s (%d MB of zeros)", track.path, total >> 20)
        if number % 1000 == 0:
            log.info("%d of %d read, %d damaged", number, len(tracks), len(damaged))
    summary = {"read": len(tracks), "damaged": damaged, "unreadable": unreadable,
               "hours": round((time.time() - started) / 3600, 2), "finished": time.time()}
    partial = report.with_suffix(".part")
    partial.write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    partial.replace(report)
    log.info("done: %d read, %d damaged, %d unreadable", len(tracks), len(damaged), len(unreadable))
    return {"read": len(tracks), "damaged": len(damaged), "unreadable": len(unreadable)}
