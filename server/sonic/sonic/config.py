"""Settings, all from the environment so the same code runs in Docker and from a shell."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

# The public MusiCNN tagger trained on the Million Song Dataset — the network Plex's
# `Music.tflite` is a conversion of. Fetched on first start rather than committed:
# its licence (CC BY-NC-SA 4.0) is fine for personal use, not for redistribution.
MODEL_URL = "https://essentia.upf.edu/models/feature-extractors/musicnn/msd-musicnn-1.pb"
MODEL_NAME = "msd-musicnn-1"

# Bumped whenever the analysis changes in a way that makes stored results stale. A track
# analysed under an older version is analysed again.
ANALYSIS_VERSION = 1

# The model's 50 outputs, in order: Last.fm tags from the Million Song Dataset.
TAGS = [
    "rock", "pop", "alternative", "indie", "electronic", "female vocalists", "dance", "00s",
    "alternative rock", "jazz", "beautiful", "metal", "chillout", "male vocalists",
    "classic rock", "soul", "indie rock", "Mellow", "electronica", "80s", "folk", "90s",
    "chill", "instrumental", "punk", "oldies", "blues", "hard rock", "ambient", "acoustic",
    "experimental", "female vocalist", "guitar", "Hip-Hop", "70s", "party", "country",
    "easy listening", "sexy", "catchy", "funk", "electro", "heavy metal", "Progressive rock",
    "60s", "rnb", "indie pop", "sad", "House", "happy",
]


def _path_map(raw: str) -> list[tuple[str, str]]:
    """`/music/my_music=/mnt/media/my_music,/music/music=/mnt/media/music` → pairs."""
    pairs = []
    for item in raw.split(","):
        if "=" in item:
            source, target = item.split("=", 1)
            pairs.append((source.rstrip("/"), target.rstrip("/")))
    # Longest first, so a nested root wins over its parent.
    return sorted(pairs, key=lambda pair: len(pair[0]), reverse=True)


@dataclass(frozen=True)
class Config:
    navidrome_db: Path = field(default_factory=lambda: Path(os.environ.get("SONIC_NAVIDROME_DB", "/navidrome/navidrome.db")))
    # Navidrome's library roots as Navidrome sees them, mapped to where the files are here.
    path_map: list[tuple[str, str]] = field(default_factory=lambda: _path_map(os.environ.get("SONIC_PATH_MAP", "")))
    data_dir: Path = field(default_factory=lambda: Path(os.environ.get("SONIC_DATA", "data")))
    host: str = field(default_factory=lambda: os.environ.get("SONIC_HOST", "0.0.0.0"))
    port: int = field(default_factory=lambda: int(os.environ.get("SONIC_PORT", "8650")))
    token: str = field(default_factory=lambda: os.environ.get("SONIC_TOKEN", ""))
    workers: int = field(default_factory=lambda: int(os.environ.get("SONIC_WORKERS", "8")))
    resync_hours: float = field(default_factory=lambda: float(os.environ.get("SONIC_RESYNC_HOURS", "6")))

    @property
    def database(self) -> Path:
        return self.data_dir / "sonic.db"

    @property
    def model(self) -> Path:
        return self.data_dir / f"{MODEL_NAME}.pb"

    def local_path(self, navidrome_path: str) -> str | None:
        """Where a file Navidrome knows by `navidrome_path` is on this machine."""
        for source, target in self.path_map:
            if navidrome_path == source or navidrome_path.startswith(source + "/"):
                return target + navidrome_path[len(source):]
        return navidrome_path if not self.path_map else None
