"""The running service: keeps the store in step with Navidrome, analyses what is new, and
keeps the in-memory index current for the HTTP layer."""

from __future__ import annotations

import logging
import sqlite3
import threading
import time
import urllib.request
from concurrent.futures import ProcessPoolExecutor, as_completed
from concurrent.futures.process import BrokenProcessPool

import numpy as np

from . import duplicates, library, lrclib, lyricsfile, serverplays
from . import lyrics as lyric_files
from .analyse import analyse, init_worker
from .config import ANALYSIS_VERSION, MODEL_NAME, MODEL_URL, Config
from .index import Index, bucket_levels, stored_levels
from .lyrics import LyricIndex
from .words import Readings, Translations
from .radar import Radar
from .shows import Shows
from .wordsync import WordTimings
from .store import Store
from .taste import TasteStore
from .video import Videos

log = logging.getLogger("sonic")


class Service:
    def __init__(self, config: Config):
        self.config = config
        self.store = Store(config.database)
        self.taste = TasteStore(config.data_dir / "taste.db")
        self.radar = Radar(config.navidrome_db, config.data_dir / "radar.json")
        self.shows = Shows(config.ticketmaster_key, config.shows_place, config.shows_radius,
                           self.radar.artists, config.data_dir / "shows.json")
        self.word_timings = WordTimings(config.data_dir / "word-timings.db")
        # The library's songs at the last pass, for what a song is without a copy of the
        # database: title, artist, album, length.
        self.songs: dict = {}
        self._duplicates: tuple[float, list] | None = None
        self.index = Index(self.store.rows())
        # Filled by the first sync, a few seconds after start.
        self.lyrics = LyricIndex([])
        self.readings = Readings()
        self.translations = Translations(config.data_dir, config.ollama, config.translate_model)
        self.videos = Videos(config.data_dir)
        self.analysing = False
        self._done = 0
        self._last_refresh = 0.0
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
        readings = None if blob is None else stored_levels(blob)
        if readings is None:
            return None
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

    def save_lyrics(self, body: dict) -> dict:
        """Lyrics fixed in the app, into the song's file: see `lyricsfile`. Raises
        `lyricsfile.Refused`."""
        fix = lyricsfile.request(body)
        lyricsfile.check_admin(self.config.navidrome_url, fix.auth)
        song = library.locate(self.config, fix.track_id)
        if song is None:
            raise lyricsfile.Refused(404, "The music server doesn't know this song.")
        changed = lyricsfile.write(song.path, fix.original, fix.synced, fix.lines)
        log.info("lyrics saved into %s: %s", fix.track_id, ", ".join(changed))
        if not any(name.endswith("beside the song") for name in changed):
            lyricsfile.ask_scan(self.config.navidrome_url, fix.auth)
        self._index_lyrics(fix.track_id, song, lyricsfile.lrc(fix.lines))
        return {"ok": True, "changed": changed}

    def find_lyrics(self, body: dict) -> dict:
        """`POST /v1/lyrics/find {id, auth}`: LRCLIB's lyrics for a song with none, written
        beside it as a `.lrc` (`lrclib`). Raises `lyricsfile.Refused`."""
        track_id = body.get("id")
        if not isinstance(track_id, str) or not 0 < len(track_id) <= 64:
            raise lyricsfile.Refused(400, "id must be a song id")
        auth = body.get("auth")
        if not isinstance(auth, dict) or not all(isinstance(auth.get(key), str) and auth.get(key) for key in "uts"):
            raise lyricsfile.Refused(401, "Sign in to the server to find lyrics.")
        auth = {key: auth[key] for key in "uts"}
        lyricsfile.check_admin(self.config.navidrome_url, auth)
        song = library.locate(self.config, track_id)
        if song is None:
            raise lyricsfile.Refused(404, "The music server doesn't know this song.")
        found, lines = lrclib.save_for(song.path, song.title, song.artist, song.album, song.duration)
        if found is None:
            log.info("lyrics for %s: none on LRCLIB", track_id)
            return {"found": False, "instrumental": False}
        if found.instrumental:
            log.info("lyrics for %s: instrumental on LRCLIB", track_id)
            return {"found": False, "instrumental": True}
        log.info("lyrics for %s: %d lines from LRCLIB, %s", track_id, len(lines), "timed" if found.synced else "not timed")
        self._index_lyrics(track_id, song, found.text)
        return {
            "found": True,
            "synced": found.synced,
            "lines": [{"start": start, "value": value} if found.synced else {"value": value} for start, value in lines],
        }

    def server_plays(self, after: int, user: str, limit: int) -> dict:
        """Navidrome's own play log, a page at a time (`serverplays`). Read straight from the
        live database, read-only: a page is one indexed query, not worth a 170 MB copy."""
        connection = sqlite3.connect(f"file:{self.config.navidrome_db}?mode=ro", uri=True)
        try:
            return serverplays.page(connection, after, user, limit)
        finally:
            connection.close()

    def duplicate_albums(self) -> dict:
        """Albums in both libraries, side by side (`duplicates`); worked out at most every
        ten minutes, as it reads a copy of the whole database."""
        if self._duplicates is None or time.time() - self._duplicates[0] > 600:
            with library._snapshot(self.config) as connection:
                self._duplicates = (time.time(), duplicates.find(connection))
        pairs = self._duplicates[1]
        return {"items": pairs, "count": len(pairs)}

    def words(self, track_id: str) -> dict | None:
        """When each word of the song's lyrics is sung, from LRCLIB (`wordsync`); None for
        a song unknown, or with no word timing to be had."""
        song = self.songs.get(track_id)
        if song is None:
            located = library.locate(self.config, track_id)
            if located is None:
                return None
            title, artist, duration = located.title, located.artist, located.duration
        else:
            title, artist, duration = song.title, song.artist, song.duration
        lines = self.word_timings.answer(track_id, title, artist, duration)
        return None if lines is None else {"id": track_id, "lines": lines}

    def _index_lyrics(self, track_id: str, song, text: str) -> None:
        """Lyrics just written, into the search at once rather than at the next pass."""
        track = lyric_files.from_text(track_id, song.title, song.artist, text)
        if track is not None:
            self.lyrics = self.lyrics.with_track(track)

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
        tracks, lyric_tracks = library.read_with_lyrics(self.config)
        self.songs = {track.id: track for track in tracks}
        # The tags' lyrics at once on a first start, while the files beside the songs are
        # read: that is minutes the first time, and a search meanwhile finds something.
        if not len(self.lyrics):
            self.lyrics = LyricIndex(lyric_tracks)
        added, changed, removed = self.store.sync(tracks)
        self.library_tracks = len(tracks)
        self.last_sync = time.time()
        log.info("library: %d tracks (%d new, %d changed, %d gone)", len(tracks), added, changed, removed)
        if removed or changed:
            self.refresh_index()
        self.lyrics = LyricIndex(lyric_files.with_sidecars(tracks, lyric_tracks, self.config.data_dir / "lyric-files.db"))
        log.info("lyrics: %d tracks", len(self.lyrics))

    def analyse_pending(self) -> None:
        """Every track waiting, a few workers at a time.

        In waves of a few tracks rather than all at once: a file can crash the decoder
        outright (`free(): invalid pointer`), which kills its worker and the whole pool
        with it, and then nothing says which track it was. Submitted all at once, that
        one track failed the pass every six hours, and the tracks beside it were never
        analysed either. A broken wave is run again one track at a time, and the track
        that breaks its own worker is marked as having crashed the decoder."""
        jobs = self.store.pending()
        if not jobs:
            return
        workers = self.config.workers
        log.info("analysing %d tracks with %d workers", len(jobs), workers)
        self.analysing = True
        self._done = 0
        self._last_refresh = time.time()
        wave = workers * 2
        try:
            pool = self._pool(workers)
            try:
                for start in range(0, len(jobs), wave):
                    left = self._run(pool, jobs[start:start + wave], len(jobs))
                    if not left:
                        continue
                    pool.shutdown(cancel_futures=True)
                    log.warning("a worker crashed; trying %d tracks one at a time", len(left))
                    for job in left:
                        alone = self._pool(1)
                        try:
                            if self._run(alone, [job], len(jobs)):
                                self.store.save({"id": job[0], "error": "crashed the decoder"})
                                log.warning("%s: crashed the decoder", job[0])
                        finally:
                            alone.shutdown(cancel_futures=True)
                    pool = self._pool(workers)
            finally:
                pool.shutdown(cancel_futures=True)
        finally:
            self.analysing = False
            self.refresh_index()
            log.info("analysis pass finished: %d tracks", self._done)

    def _pool(self, workers: int) -> ProcessPoolExecutor:
        return ProcessPoolExecutor(max_workers=workers, initializer=init_worker, initargs=(str(self.config.model),))

    def _run(self, pool: ProcessPoolExecutor, jobs: list, total: int) -> list:
        """Runs `jobs`, saving each result. The jobs left unsaved if a worker died."""
        futures = {pool.submit(analyse, job): job for job in jobs}
        saved = set()
        try:
            for future in as_completed(futures):
                result = future.result()
                self.store.save(result)
                saved.add(futures[future][0])
                self._done += 1
                if "error" in result:
                    log.warning("%s: %s", result["id"], result["error"])
                # New vectors join the index every couple of minutes, so the service
                # is useful long before the first pass over a big library finishes.
                if time.time() - self._last_refresh > 120:
                    self.refresh_index()
                    self._last_refresh = time.time()
                    log.info("analysed %d of %d", self._done, total)
        except BrokenProcessPool:
            return [job for job in jobs if job[0] not in saved]
        return []

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
