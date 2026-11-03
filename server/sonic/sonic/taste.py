"""Taste shared between devices: each one's plays and skips, so the phone and the desktop
learn from each other.

Each app keeps its own play log and its own skips, and the mixes, radio and stats read
them; a skip on the desktop said nothing to the phone. Here every device posts what it
recorded and reads what the others did, by a sequence number that only grows. An event
is the app's own record, kept as it came, under the app's own id, so sending one twice
is harmless."""

from __future__ import annotations

import json
import sqlite3
import threading
from pathlib import Path

KINDS = ("play", "skip")
#: The most events one request may carry, and the most bytes one event may hold.
BATCH = 5000
EVENT_BYTES = 4096


class TasteStore:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._db = sqlite3.connect(str(path), check_same_thread=False)
        self._db.execute(
            "create table if not exists events ("
            " seq integer primary key autoincrement,"
            " id text unique not null,"
            " device text not null,"
            " kind text not null,"
            " at real not null,"
            " body text not null)"
        )
        self._db.execute("create index if not exists events_device on events(device, seq)")
        self._db.commit()

    def latest(self) -> int:
        with self._lock:
            row = self._db.execute("select coalesce(max(seq), 0) from events").fetchone()
        return int(row[0])

    def add(self, device: str, events: list) -> dict:
        """Keeps what is new; returns how many were new and the latest sequence number."""
        if not isinstance(device, str) or not 0 < len(device) <= 64:
            raise ValueError("device must be a short string")
        if not isinstance(events, list) or len(events) > BATCH:
            raise ValueError(f"events must be a list of at most {BATCH}")
        rows = []
        for event in events:
            if not isinstance(event, dict):
                raise ValueError("each event must be an object")
            kind, ident, at = event.get("kind"), event.get("id"), event.get("at")
            if kind not in KINDS or not isinstance(ident, str) or not 0 < len(ident) <= 64 \
                    or not isinstance(at, (int, float)):
                raise ValueError("each event needs a kind (play or skip), an id and a time")
            body = json.dumps(event, separators=(",", ":"), ensure_ascii=False)
            if len(body.encode()) > EVENT_BYTES:
                raise ValueError("an event is too big")
            rows.append((ident, device, kind, float(at), body))
        with self._lock:
            before = self._db.total_changes
            self._db.executemany(
                "insert or ignore into events (id, device, kind, at, body) values (?, ?, ?, ?, ?)", rows
            )
            self._db.commit()
            added = self._db.total_changes - before
            latest = self._db.execute("select coalesce(max(seq), 0) from events").fetchone()[0]
        return {"added": added, "seq": int(latest)}

    def since(self, seq: int, device: str, limit: int = BATCH) -> dict:
        """The other devices' events after `seq`, oldest first, and where to carry on from."""
        with self._lock:
            rows = self._db.execute(
                "select seq, body from events where seq > ? and device != ? order by seq limit ?",
                (seq, device, limit),
            ).fetchall()
            latest = self._db.execute("select coalesce(max(seq), 0) from events").fetchone()[0]
        events = []
        for number, body in rows:
            event = json.loads(body)
            event["seq"] = number
            events.append(event)
        # Where the next read starts: past everything seen, including this device's own.
        through = rows[-1][0] if len(rows) == limit else int(latest)
        return {"events": events, "seq": int(through)}
