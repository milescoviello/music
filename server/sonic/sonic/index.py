"""The sonic space, in memory, and every question Plexamp asks of it.

Distances are cosine distance (1 − cos) between the 50-dimensional vectors — the metric
Plex's Annoy trees use, on which Plexamp's thresholds (DJ Gemini's `maxDistance=0.175`)
are expressed. A library of tens of thousands of tracks is a few megabytes of vectors,
so every query is an exact matrix product rather than an approximate index.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

import numpy as np

from .config import TAGS

_BRACKET = re.compile(r"^(.*[a-zA-Z ]+)[(\[].+[)\]]$")


def clean_title(title: str) -> str:
    """Plexamp's: a trailing "(Live)" or "[2011 Remaster]" goes, so two versions of a song
    count as one."""
    match = _BRACKET.match(title)
    if match:
        title = title[: max(title.rfind("("), title.rfind("["))]
    return re.sub(r" +", " ", title).strip().lower()


@dataclass
class Hit:
    id: str
    distance: float

    def json(self) -> dict:
        return {"id": self.id, "distance": round(self.distance, 5)}


class Index:
    def __init__(self, rows: list[tuple]):
        """`rows`: (id, album_id, artist_id, track_artist_id, title, artist, plays, vector bytes)."""
        self.ids: list[str] = []
        albums, artists, track_artists, songs, plays, vectors = [], [], [], [], [], []
        for track_id, album_id, artist_id, track_artist_id, title, artist, play_count, blob in rows:
            vector = np.frombuffer(blob, dtype=np.float32)
            if vector.shape != (len(TAGS),) or not np.isfinite(vector).all():
                continue
            self.ids.append(track_id)
            albums.append(album_id)
            artists.append(artist_id)
            track_artists.append(track_artist_id)
            songs.append(f"{clean_title(title)}\u001f{artist.lower()}")
            plays.append(play_count or 0)
            vectors.append(vector)

        self.row = {track_id: index for index, track_id in enumerate(self.ids)}
        self.album = np.array(albums, dtype=object)
        self.artist = np.array(artists, dtype=object)
        self.track_artist = np.array(track_artists, dtype=object)
        self.song = np.array(songs, dtype=object)
        self.plays = np.array(plays, dtype=np.int64)
        self.raw = np.array(vectors, dtype=np.float32).reshape(-1, len(TAGS))
        self.unit = _normalise(self.raw)

        self.album_ids, self.album_unit, self.album_artist = self._centroids(self.album, self.artist)
        self.artist_ids, self.artist_unit, _ = self._centroids(self.artist, self.artist)
        self.album_row = {album_id: index for index, album_id in enumerate(self.album_ids)}
        self.artist_row = {artist_id: index for index, artist_id in enumerate(self.artist_ids)}

    def __len__(self) -> int:
        return len(self.ids)

    def _centroids(self, keys: np.ndarray, owners: np.ndarray):
        """The mean direction of every group's tracks: an album's or an artist's sound."""
        order: dict[str, list[int]] = {}
        for index, key in enumerate(keys):
            if key:
                order.setdefault(key, []).append(index)
        ids = list(order)
        if not ids:
            return [], np.zeros((0, len(TAGS)), np.float32), []
        means = np.array([self.unit[members].mean(axis=0) for members in order.values()], dtype=np.float32)
        owner = [owners[members[0]] for members in order.values()]
        return ids, _normalise(means), owner

    # MARK: - Tracks

    def similar(self, track_id: str, limit: int = 50, exclude_artist: bool = False,
                max_distance: float | None = None) -> list[Hit] | None:
        """Plexamp's Sonically Similar: nearest first, never the track itself or another
        version of it."""
        row = self.row.get(track_id)
        if row is None:
            return None
        distances = 1 - self.unit @ self.unit[row]
        return self._pick(distances, limit, skip={row}, avoid_artist=self.artist[row] if exclude_artist else None,
                          avoid_songs={self.song[row]}, max_distance=max_distance)

    def distant(self, track_id: str, limit: int = 50) -> list[Hit] | None:
        """Plexamp's Outside Your Comfort Zone: related, not close — from past the nearest
        few dozen out to a few hundred — and favouring what has hardly been played, by
        artists other than this one, two per artist at most."""
        row = self.row.get(track_id)
        if row is None:
            return None
        distances = 1 - self.unit @ self.unit[row]
        order = np.argsort(distances)
        band = order[min(len(order), 30): min(len(order), 600)]
        band = [index for index in band if self.artist[index] != self.artist[row] and self.song[index] != self.song[row]]
        # Unplayed first, then by distance; stable, so ties keep distance order.
        band.sort(key=lambda index: 0 if self.plays[index] == 0 else 1)
        hits, per_artist, songs = [], {}, set()
        for index in band:
            if per_artist.get(self.artist[index], 0) >= 2 or self.song[index] in songs:
                continue
            per_artist[self.artist[index]] = per_artist.get(self.artist[index], 0) + 1
            songs.add(self.song[index])
            hits.append(Hit(self.ids[index], float(distances[index])))
            if len(hits) >= limit:
                break
        return hits

    def radio(self, seeds: list[str], exclude: list[str] = (), limit: int = 25) -> list[Hit] | None:
        """A radio around the seeds' common sound: nearest to their mean, no seed, nothing
        excluded, at most two by any one artist so it does not become one artist's
        discography."""
        rows = [self.row[seed] for seed in seeds if seed in self.row]
        if not rows:
            return None
        centre = _normalise(self.unit[rows].mean(axis=0, keepdims=True))[0]
        distances = 1 - self.unit @ centre
        skip = set(rows) | {self.row[item] for item in exclude if item in self.row}
        avoid_songs = {self.song[row] for row in skip}
        return self._pick(distances, limit, skip=skip, avoid_songs=avoid_songs, per_artist=2)

    def path(self, start: str, end: str, steps: int = 10) -> list[Hit] | None:
        """Plexamp's Sonic Adventure: tracks along the way from one to the other.

        Walks the great circle between the two vectors in `steps` even steps and takes the
        nearest unused track to each point, never two in a row by one artist, and never
        another version of either end."""
        a, b = self.row.get(start), self.row.get(end)
        if a is None or b is None or a == b:
            return None
        used = {a, b}
        songs = {self.song[a], self.song[b]}
        previous_artist = self.artist[a]
        hits = []
        for step in range(1, steps + 1):
            point = _slerp(self.unit[a], self.unit[b], step / (steps + 1))
            distances = 1 - self.unit @ point
            for index in np.argsort(distances):
                if index in used or self.song[index] in songs or self.artist[index] == previous_artist:
                    continue
                used.add(index)
                songs.add(self.song[index])
                previous_artist = self.artist[index]
                hits.append(Hit(self.ids[index], float(distances[index])))
                break
        return hits

    def tags(self, track_id: str, limit: int = 8) -> list[dict] | None:
        row = self.row.get(track_id)
        if row is None:
            return None
        order = np.argsort(-self.raw[row])[:limit]
        return [{"tag": TAGS[index], "score": round(float(self.raw[row][index]), 4)} for index in order]

    def tagged(self, tag: str, limit: int = 50) -> list[Hit] | None:
        """The tracks that sound most like a tag — a mood station: "chill", "sad", "party"."""
        names = {name.lower(): index for index, name in enumerate(TAGS)}
        column = names.get(tag.lower())
        if column is None or not len(self):
            return None
        scores = self.raw[:, column]
        distances = 1 - scores
        return self._pick(distances, limit, skip=set(), per_artist=2)

    # MARK: - Albums and artists

    def similar_albums(self, album_id: str, limit: int = 20, exclude_artist: bool = True) -> list[Hit] | None:
        row = self.album_row.get(album_id)
        if row is None:
            return None
        distances = 1 - self.album_unit @ self.album_unit[row]
        hits = []
        for index in np.argsort(distances):
            if index == row or (exclude_artist and self.album_artist[index] == self.album_artist[row]):
                continue
            hits.append(Hit(self.album_ids[index], float(distances[index])))
            if len(hits) >= limit:
                break
        return hits

    def similar_artists(self, artist_id: str, limit: int = 20) -> list[Hit] | None:
        row = self.artist_row.get(artist_id)
        if row is None:
            return None
        distances = 1 - self.artist_unit @ self.artist_unit[row]
        return [Hit(self.artist_ids[index], float(distances[index]))
                for index in np.argsort(distances) if index != row][:limit]

    # MARK: - Picking

    def _pick(self, distances: np.ndarray, limit: int, skip: set, avoid_artist=None, avoid_songs=frozenset(),
              max_distance: float | None = None, per_artist: int | None = None) -> list[Hit]:
        hits, songs, counts = [], set(avoid_songs), {}
        for index in np.argsort(distances):
            distance = float(distances[index])
            if max_distance is not None and distance > max_distance:
                break
            if index in skip or self.song[index] in songs:
                continue
            artist = self.artist[index]
            if avoid_artist is not None and artist == avoid_artist:
                continue
            if per_artist is not None and counts.get(artist, 0) >= per_artist:
                continue
            counts[artist] = counts.get(artist, 0) + 1
            songs.add(self.song[index])
            hits.append(Hit(self.ids[index], distance))
            if len(hits) >= limit:
                break
        return hits


def bucket_levels(levels: np.ndarray, points: int) -> list[float]:
    """The seekbar's subsampling, identical to the app's local fallback: readings already
    floored, bucket i is readings [i·n/points, (i+1)·n/points), the arithmetic mean of
    the decibels, to 0.1 dB. With no more readings than points, the readings as they are."""
    values = np.asarray(levels, dtype=np.float32)
    count = len(values)
    if points <= 0 or count <= points:
        return [round(float(value), 1) for value in values]
    buckets = []
    for index in range(points):
        lower, upper = index * count // points, (index + 1) * count // points
        buckets.append(round(float(values[lower:max(upper, lower + 1)].mean()), 1))
    return buckets


def _normalise(matrix: np.ndarray) -> np.ndarray:
    norms = np.linalg.norm(matrix, axis=-1, keepdims=True)
    return (matrix / np.where(norms == 0, 1, norms)).astype(np.float32)


def _slerp(a: np.ndarray, b: np.ndarray, t: float) -> np.ndarray:
    dot = float(np.clip(a @ b, -1, 1))
    angle = np.arccos(dot)
    if angle < 1e-6:
        return a
    return ((np.sin((1 - t) * angle) * a + np.sin(t * angle) * b) / np.sin(angle)).astype(np.float32)
