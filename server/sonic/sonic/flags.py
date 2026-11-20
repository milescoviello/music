"""About summaries flagged in the apps as needing a fix: "Flag for a fix" on About This Song, Album or Artist, with
what is wrong when he says.

Kept in `data/about-flags.json` = {"song/<id>": {"kind", "id", "title", "artist", "note", "at"}}. A flag is open
until the summary is written again after it (its file in `data/<kind>-about-summaries/` is newer than the flag) or
the app takes it back. `open_flags()` lists the open ones, oldest first, for whoever rewrites them; `GET
/v1/about/flags` answers the same. Standard library only.
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
from pathlib import Path

KINDS = ("song", "album", "artist")
NOTE_CHARS = 1_000
NAME_CHARS = 300
ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


class AboutFlags:
    def __init__(self, data_dir: Path, clock=time.time):
        self.path = data_dir / "about-flags.json"
        self.summaries = {kind: data_dir / f"{kind}-about-summaries" for kind in KINDS}
        self._clock = clock
        self._lock = threading.Lock()

    def _read(self) -> dict:
        try:
            stored = json.loads(self.path.read_text())
        except (OSError, ValueError):
            return {}
        return stored if isinstance(stored, dict) else {}

    def _write(self, flags: dict) -> None:
        temporary = self.path.with_name(self.path.name + ".tmp")
        temporary.write_text(json.dumps(flags, ensure_ascii=False, indent=1))
        os.replace(temporary, self.path)

    def _rewritten(self, flag: dict) -> bool:
        """The summary was written again after the flag: that was the fix."""
        try:
            return (self.summaries[flag["kind"]] / f"{flag['id']}.json").stat().st_mtime > flag["at"]
        except (OSError, KeyError, TypeError):
            return False

    def flag(self, body: dict) -> dict:
        """`{"kind", "id", "note"?, "title"?, "artist"?, "clear"?}` from the app. Raises ValueError on a bad one."""
        kind, item_id = body.get("kind"), body.get("id")
        if kind not in KINDS:
            raise ValueError(f"kind is one of {', '.join(KINDS)}")
        if not isinstance(item_id, str) or not ID.match(item_id):
            raise ValueError("an id")
        key = f"{kind}/{item_id}"
        with self._lock:
            flags = self._read()
            if body.get("clear"):
                flags.pop(key, None)
                self._write(flags)
                return {"flagged": False}

            def text(name: str, limit: int) -> str:
                value = body.get(name)
                return value.strip()[:limit] if isinstance(value, str) else ""

            flags[key] = {"kind": kind, "id": item_id, "title": text("title", NAME_CHARS),
                          "artist": text("artist", NAME_CHARS), "note": text("note", NOTE_CHARS),
                          "at": self._clock()}
            self._write(flags)
        return {"flagged": True}

    def state(self, kind: str, item_id: str) -> dict | None:
        """For an About answer: `{"at", "note"}` while the flag is open, else None."""
        flag = self._read().get(f"{kind}/{item_id}")
        if not isinstance(flag, dict) or self._rewritten(flag):
            return None
        return {"at": flag.get("at"), "note": flag.get("note") or ""}

    def open_flags(self) -> list[dict]:
        return sorted((flag for flag in self._read().values() if isinstance(flag, dict) and not self._rewritten(flag)),
                      key=lambda flag: flag.get("at") or 0)
