"""Plays to point at a song by hand, when the apps cannot work out where it went.

The apps repair their listening history once a day: a song the server no longer has is
looked for by title, artist and album, and taken only when it is plainly the same
recording. Some are not plain. A single deleted in a cleanup can survive as the album's
copy under a translated title, or with the artist's name in another script. Those are
listed in `data/history-links.json`, which is not in the repository, checked by hand:

    {"links": {"<old song id>": {"to": "<new song id>", "why": "…"}}}

and the apps ask for them during the repair, so a link added here reaches them without
a new build. `why` is for whoever reads the file; the apps get only the ids.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

log = logging.getLogger(__name__)


def history_links(path: Path) -> dict[str, str]:
    """Old song id → new song id. Empty when there is no file; a bad file is logged and
    left out rather than answered half-read."""
    try:
        text = path.read_text()
    except FileNotFoundError:
        return {}
    try:
        links = json.loads(text).get("links", {})
        return {
            old: entry["to"]
            for old, entry in links.items()
            if isinstance(old, str) and isinstance(entry, dict) and isinstance(entry.get("to"), str) and entry["to"] != old
        }
    except (ValueError, AttributeError) as error:
        log.warning("history links: %s is not readable: %s", path, error)
        return {}
