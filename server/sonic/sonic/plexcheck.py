"""How close our sonic space is to Plex's, on the tracks both have analysed.

Reads Plex's own stored vectors — the Annoy trees in "Music Analysis <section>" — and its
file paths, matches them to our tracks by file, and reports two numbers: the cosine
similarity between each pair of vectors, and how many of each track's ten nearest
neighbours the two spaces agree on. Read-only against Plex throughout.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

import numpy as np

from .config import TAGS, Config
from .store import Store

NODE_BYTES = 12 + 4 * len(TAGS)  # Annoy angular node: n_descendants, union, children[1], v[50]


def plex_vectors(analysis_dir: str) -> dict[int, np.ndarray]:
    """Plex metadata id → vector, from one section's Track.tree and Mapping.db."""
    directory = Path(analysis_dir)
    mapping = sqlite3.connect(f"file:{directory / 'Mapping.db'}?mode=ro", uri=True)
    pairs = mapping.execute("select id, external_id from mappings where metadata_type = 10").fetchall()
    nodes = np.fromfile(directory / "Track.tree", dtype=np.uint8).reshape(-1, NODE_BYTES)
    floats = nodes.view(np.float32)
    return {plex_id: floats[item, 3:].copy() for plex_id, item in pairs if item < len(floats)}


def plex_paths(plex_db: str) -> dict[int, str]:
    connection = sqlite3.connect(f"file:{plex_db}?mode=ro", uri=True)
    return dict(connection.execute(
        "select mi.metadata_item_id, mp.file from media_parts mp "
        "join media_items mi on mp.media_item_id = mi.id"
    ).fetchall())


def report(config: Config, plex_db: str, analysis_dirs: list[str], plex_root: str, local_root: str) -> None:
    paths = plex_paths(plex_db)
    theirs: dict[str, np.ndarray] = {}
    for directory in analysis_dirs:
        for plex_id, vector in plex_vectors(directory).items():
            path = paths.get(plex_id)
            if path and path.startswith(plex_root):
                theirs[local_root + path[len(plex_root):]] = vector

    store = Store(config.database)
    ours = {}
    with store._lock:  # noqa: SLF001 — a one-off report, not part of the service
        for path, blob in store._db.execute("select path, vector from tracks where vector is not null"):  # noqa: SLF001
            ours[path] = np.frombuffer(blob, dtype=np.float32)

    shared = sorted(set(ours) & set(theirs))
    print(f"ours {len(ours)}, Plex {len(theirs)}, both {len(shared)}")
    if not shared:
        return

    a = np.array([ours[path] for path in shared])
    b = np.array([theirs[path] for path in shared])
    a /= np.linalg.norm(a, axis=1, keepdims=True)
    b /= np.linalg.norm(b, axis=1, keepdims=True)
    cosine = (a * b).sum(axis=1)
    print(f"vector cosine: mean {cosine.mean():.5f}, median {np.median(cosine):.5f}, "
          f"5th percentile {np.percentile(cosine, 5):.5f}, min {cosine.min():.5f}")

    sample = np.random.default_rng(0).choice(len(shared), size=min(500, len(shared)), replace=False)
    overlaps = []
    for row in sample:
        mine = set(np.argsort(1 - a @ a[row])[1:11])
        plexs = set(np.argsort(1 - b @ b[row])[1:11])
        overlaps.append(len(mine & plexs) / 10)
    print(f"top-10 neighbour agreement over {len(sample)} tracks: {np.mean(overlaps):.3f}")
