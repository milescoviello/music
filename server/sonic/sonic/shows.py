"""Concerts coming up near home by the artists played most: Home's Shows shelf.

The artists are the release radar's (`Radar.artists`: the most played and the most lately
played), each asked of Ticketmaster's Discovery API for music events within a radius of a
place. An event counts only when the artist is one of its acts by name -- the API's keyword
search also matches tribute bands and festivals that merely mention them. Kept for a day,
like the radar, and refreshed in the background when stale.

Needs a key of the Discovery API (free, from developer.ticketmaster.com) in
`SONIC_TICKETMASTER_KEY`; without one there is no shelf, and the endpoint says so.
"""

from __future__ import annotations

import json
import logging
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from .radar import normalised

log = logging.getLogger("sonic.shows")

STALE_AFTER = 86_400
API = "https://app.ticketmaster.com/discovery/v2/events.json"


class Shows:
    def __init__(self, key: str, place: str, radius: int, artists, path: Path, fetch=None, clock=time.time, pause=0.3):
        self.key = key
        self.place = place
        self.radius = radius
        self._artists = artists
        self.path = path
        self._fetch = fetch or self._ask
        self._clock = clock
        self._pause = pause
        self._lock = threading.Lock()
        self._refreshing = False

    @property
    def is_set_up(self) -> bool:
        return bool(self.key)

    def answer(self) -> dict | None:
        if not self.is_set_up:
            return None
        kept = self._kept()
        if kept is None or self._clock() - kept.get("updated", 0) > STALE_AFTER:
            self.refresh_soon()
        today = time.strftime("%Y-%m-%d", time.localtime(self._clock()))
        items = [item for item in (kept or {}).get("items", []) if item.get("date", "") >= today]
        return {"items": items, "updated": (kept or {}).get("updated"), "refreshing": self._refreshing}

    def refresh_soon(self) -> None:
        with self._lock:
            if self._refreshing:
                return
            self._refreshing = True
        threading.Thread(target=self._refresh, name="shows", daemon=True).start()

    def _kept(self) -> dict | None:
        try:
            return json.loads(self.path.read_text())
        except (OSError, ValueError):
            return None

    def _refresh(self) -> None:
        try:
            items = self.build()
            temporary = self.path.with_suffix(".tmp")
            temporary.write_text(json.dumps({"updated": self._clock(), "items": items}, ensure_ascii=False))
            temporary.replace(self.path)
            log.info("shows: %d coming up", len(items))
        except Exception:  # noqa: BLE001 — the kept answer stays
            log.exception("shows refresh failed")
        finally:
            with self._lock:
                self._refreshing = False

    def build(self) -> list[dict]:
        items, seen = [], set()
        for artist in self._artists():
            name = artist["name"]
            try:
                events = self._fetch(name)
            except Exception as error:  # noqa: BLE001 — one artist's answer, not the shelf
                log.warning("shows for an artist: %s", error)
                continue
            for event in events:
                item = self._item(event, name)
                if item and item["id"] not in seen:
                    seen.add(item["id"])
                    items.append(item)
            time.sleep(self._pause)
        items.sort(key=lambda item: (item["date"], item.get("time") or ""))
        return items

    @staticmethod
    def _item(event: dict, artist: str) -> dict | None:
        embedded = event.get("_embedded", {})
        acts = [act.get("name", "") for act in embedded.get("attractions", [])]
        if normalised(artist) not in {normalised(act) for act in acts}:
            return None
        start = event.get("dates", {}).get("start", {})
        if not start.get("localDate"):
            return None
        venue = (embedded.get("venues") or [{}])[0]
        images = sorted(event.get("images", []), key=lambda image: image.get("width", 0))
        wide = [image for image in images if image.get("ratio") == "16_9" and image.get("width", 0) >= 500]
        image = (wide or images or [{}])[0].get("url")
        return {
            "id": event.get("id", ""),
            "artist": artist,
            "name": event.get("name", ""),
            "date": start["localDate"],
            "time": start.get("localTime"),
            "venue": venue.get("name", ""),
            "city": venue.get("city", {}).get("name", ""),
            "url": event.get("url", ""),
            "image": image,
        }

    def _ask(self, artist: str) -> list[dict]:
        query = urllib.parse.urlencode({
            "apikey": self.key, "keyword": artist, "classificationName": "music", "latlong": self.place,
            "radius": self.radius, "unit": "miles", "sort": "date,asc", "size": 20,
        })
        request = urllib.request.Request(f"{API}?{query}", headers={"User-Agent": "sonic"})
        with urllib.request.urlopen(request, timeout=15) as reply:
            return json.load(reply).get("_embedded", {}).get("events", [])
