"""Logs the app sends for fixing a bug: each report kept as a text file in `data/logs`,
where they can be read on this host without going through the phone.

The one thing the service accepts a write for. It stays bounded whoever sends it: a report
is at most `LIMIT` bytes and only the newest `KEEP` are kept, so the folder can never grow
past about `LIMIT * KEEP`."""

from __future__ import annotations

import os
import re
import secrets
from datetime import datetime, timezone
from pathlib import Path

LIMIT = 1_000_000
KEEP = 100


def source_name(raw: str | None) -> str:
    """What the app says it is ("ios", "linux-gentoo"), reduced to something that is safe
    in a file name."""
    cleaned = re.sub(r"[^a-z0-9-]+", "-", (raw or "").lower()).strip("-")
    return cleaned[:32] or "app"


class LogBox:
    def __init__(self, directory: Path, keep: int = KEEP):
        self.directory = directory
        self.keep = keep

    def save(self, text: str, source: str | None = None, now: datetime | None = None) -> str:
        """Writes one report and returns its file name. Written beside, then moved into
        place, so a reader never sees half of one."""
        self.directory.mkdir(parents=True, exist_ok=True)
        stamp = (now or datetime.now(timezone.utc)).strftime("%Y%m%d-%H%M%SZ")
        name = f"{stamp}-{source_name(source)}-{secrets.token_hex(3)}.txt"
        partial = self.directory / f".{name}.part"
        partial.write_text(text, encoding="utf-8")
        os.replace(partial, self.directory / name)
        self.prune()
        return name

    def prune(self) -> None:
        # Names start with the time, so sorting them is sorting by when they came in.
        reports = sorted(path for path in self.directory.glob("*.txt"))
        for old in reports[:-self.keep] if len(reports) > self.keep else []:
            old.unlink(missing_ok=True)
