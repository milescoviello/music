"""The running service: keeps the store in step with Navidrome, analyses what is new, and
keeps the in-memory index current for the HTTP layer."""

from __future__ import annotations

import logging
import threading
import time
import urllib.request
from concurrent.futures import ProcessPoolExecutor, as_completed

import numpy as np

from . import library
from .analyse import analyse, init_worker
from .config import ANALYSIS_VERSION, MODEL_NAME, MODEL_URL, Config
from .index import Index, bucket_levels
from .store import Store

log = logging.getLogger("sonic")


class Service:
    def __init__(self, config: Config):
        self.config = config
        self.store = Store(config.database)
        self.index = Index(self.store.rows())
        self.analysing = False
        self.library_tracks = 0
        self.last_sync: float | None = None
        self._wake = threading.Event()

    # MARK: - Answers

    def status(self) -> dict:
        counts = self.store.counts()
        return {
            "tracks": counts["tracks"],
            "analysed": counts["analysed"],
            "failed": counts["failed"],
            "indexed": len(self.index),
            "analysing": self.analysing,
            "model": MODEL_NAME,
            "version": ANALYSIS_VERSION,
            "lastSync": self.last_sync,
        }

    def levels(self, track_id: str, points: int) -> dict | None:
        blob = self.store.levels(track_id)
        if blob is None:
            return None
        readings = np.frombuffer(blob, dtype=np.float16).astype(np.float32)
        return {"id": track_id, "hop": 0.1, "levels": bucket_levels(readings, points)}

    def rhythm(self, track_id: str) -> dict | None:
        """Beats, tempo and key, for beat-matched crossfades. 404 until analysed; a track
        whose beats could not be found answers with an empty list and no tempo."""
        row = self.store.rhythm(track_id)
        if row is None:
            return None
        bpm, confidence, beats, key, scale, strength, duration, loudness = row
        return {
            "id": track_id,
            "bpm": None if bpm is None else round(bpm, 2),
            "confidence": None if confidence is None else round(confidence, 3),
            "beats": [] if beats is None else [round(float(t), 3) for t in np.frombuffer(beats, dtype=np.float32)],
            "key": key,
            "scale": scale,
            "keyStrength": None if strength is None else round(strength, 3),
            "duration": duration,
            "loudness": loudness,
        }

    # MARK: - Work

    def run_forever(self) -> None:
        """Sync, analyse everything pending, rebuild the index; then wait for the next
        resync (or a nudge) and do it again."""
        self._ensure_model()
        while True:
            try:
                self.sync()
                self.analyse_pending()
            except Exception:  # noqa: BLE001 — keep serving whatever the library does
                log.exception("analysis pass failed")
            self._wake.wait(timeout=self.config.resync_hours * 3600)
            self._wake.clear()

    def nudge(self) -> None:
        self._wake.set()

    def sync(self) -> None:
        tracks = library.read(self.config)
        added, changed, removed = self.store.sync(tracks)
        self.library_tracks = len(tracks)
        self.last_sync = time.time()
        log.info("library: %d tracks (%d new, %d changed, %d gone)", len(tracks), added, changed, removed)
        if removed or changed:
            self.refresh_index()

    def analyse_pending(self) -> None:
        jobs = self.store.pending()
        if not jobs:
            return
        log.info("analysing %d tracks with %d workers", len(jobs), self.config.workers)
        self.analysing = True
        done = 0
        last_refresh = time.time()
        try:
            with ProcessPoolExecutor(
                max_workers=self.config.workers, initializer=init_worker, initargs=(str(self.config.model),)
            ) as pool:
                for future in as_completed(pool.submit(analyse, job) for job in jobs):
                    result = future.result()
                    self.store.save(result)
                    done += 1
                    if "error" in result:
                        log.warning("%s: %s", result["id"], result["error"])
                    # New vectors join the index every couple of minutes, so the service
                    # is useful long before the first pass over a big library finishes.
                    if time.time() - last_refresh > 120:
                        self.refresh_index()
                        last_refresh = time.time()
                        log.info("analysed %d of %d", done, len(jobs))
        finally:
            self.analysing = False
            self.refresh_index()
            log.info("analysis pass finished: %d tracks", done)

    def refresh_index(self) -> None:
        self.index = Index(self.store.rows())

    def _ensure_model(self) -> None:
        if self.config.model.exists():
            return
        self.config.model.parent.mkdir(parents=True, exist_ok=True)
        log.info("downloading %s", MODEL_URL)
        partial = self.config.model.with_suffix(".part")
        urllib.request.urlretrieve(MODEL_URL, partial)
        partial.rename(self.config.model)
