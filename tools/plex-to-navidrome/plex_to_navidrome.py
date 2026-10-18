#!/usr/bin/env python3
"""Make Navidrome match Plex: Plex is authoritative, Navidrome is overwritten.

For one Plex account (the owner, id 1):

- Every Navidrome track that matches a Plex track by file gets Plex's play count, last
  played, rating and favourite — including zero, so stale Navidrome numbers do not
  survive. A Plex rating of 9–10 (five stars, Plexamp's "love") is a Navidrome favourite.
- Album and artist play counts, last played and ratings are rolled up from those tracks.
- Navidrome's play history (`scrobbles`) is replaced by Plex's, play for play.
- Plex playlists replace Navidrome playlists of the same name, in Plex's order, and new
  ones are created. Plex's smart playlists become Navidrome smart playlists, so they stay
  live. Navidrome playlists Plex has never heard of are left alone.
- Custom playlist covers are uploaded through Navidrome's own API (`--images`, with
  Navidrome running).
- With `--clean`, a clean carry-over: everything of the user's that Navidrome had before
  goes first — every annotation, all play history, every playlist Plex does not have,
  bookmarks and the saved play queue — so what is left is Plex's and nothing else.

Reads Plex's database, not its HTTP API: the API emits invalid UTF-8 for some tags,
and the database has exact per-account numbers and the full history. Plex is only ever
read (a copy of its database; the cover images over HTTP). Navidrome's database is
written, so Navidrome must be stopped for `--apply`; take a backup first — the wrapper
script does both.

Usage:
  plex_to_navidrome.py --navidrome-db PATH            # dry run: report, change nothing
  plex_to_navidrome.py --navidrome-db PATH --apply    # write (Navidrome stopped)
  plex_to_navidrome.py --images                       # covers (Navidrome running)

Plex token from PLEX_TOKEN, Navidrome login from ND_USER / ND_PASSWORD.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import unicodedata
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

PLEX_DB = ("/home/miles/media-stack/plex/config/Library/Application Support/Plex Media Server/"
           "Plug-in Support/Databases/com.plexapp.plugins.library.db")
PLEX_URL = "http://127.0.0.1:32400"
NAVIDROME_URL = "http://127.0.0.1:4533"
STATE = Path.home() / ".local" / "state" / "plex-to-navidrome.json"

# Plex section id -> (Navidrome library id, Plex's path prefix for it)
SECTIONS = {7: (1, "/media/my_music/"), 5: (2, "/media/music/")}

TRACK, ALBUM, ARTIST, PLAYLIST = 10, 9, 8, 15
LOVED = 9.0  # Plex rating (0–10) at or above which a track is a favourite

# Plex's automatic smart playlists, as Navidrome rules. Plex's own rules are not stored
# in a readable form; these say the same thing in Navidrome's terms.
SMART_RULES = {
    "❤️ Tracks": {"all": [{"is": {"loved": True}}], "sort": "dateLoved", "order": "desc"},
    "Fresh ❤️": {"all": [{"is": {"loved": True}}, {"notInTheLast": {"lastPlayed": 30}}],
                 "sort": "random", "limit": 50},
    "Recently Added": {"all": [{"inTheLast": {"dateAdded": 30}}], "sort": "dateAdded", "order": "desc"},
    "Recently Played": {"all": [{"inTheLast": {"lastPlayed": 14}}], "sort": "lastPlayed", "order": "desc",
                        "limit": 200},
    "All Music": {"all": [{"contains": {"title": ""}}], "sort": "title"},
}


def key(raw: bytes | str) -> str:
    """Match key for a path: decoded leniently (a few tags are not UTF-8), NFC, casefolded."""
    text = raw.decode("utf-8", "surrogateescape") if isinstance(raw, bytes) else raw
    return unicodedata.normalize("NFC", text).casefold()


def ts(unix) -> str | None:
    if not unix:
        return None
    return datetime.fromtimestamp(int(unix), timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def copy_db(path: str) -> sqlite3.Connection:
    scratch = tempfile.mkdtemp(prefix="plexdb-")
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(path + suffix):
            shutil.copy2(path + suffix, os.path.join(scratch, "plex.db" + suffix))
    connection = sqlite3.connect(f"file:{scratch}/plex.db?mode=ro", uri=True)
    connection.text_factory = bytes
    return connection


def text(value) -> str:
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else (value or "")


# MARK: - Plex


def read_plex(db_path: str, account: int):
    plex = copy_db(db_path)

    # Track id -> (library id, relative path key), for both sections.
    files: dict[int, tuple[int, str]] = {}
    guid_of: dict[int, bytes] = {}
    # The same recording in both libraries shares one guid; each play belongs to the copy
    # in the section it was played from.
    item_for: dict[tuple[bytes, int], int] = {}
    for item_id, guid, section, file in plex.execute(
        "select mi.id, mi.guid, mi.library_section_id, mp.file from metadata_items mi "
        "join media_items m on m.metadata_item_id = mi.id join media_parts mp on mp.media_item_id = m.id "
        "where mi.metadata_type = ?", (TRACK,)
    ):
        if section not in SECTIONS or not file:
            continue
        library, prefix = SECTIONS[section]
        path = file.decode("utf-8", "surrogateescape")
        if not path.startswith(prefix):
            continue
        files[item_id] = (library, key(path[len(prefix):]))
        guid_of[item_id] = guid
        item_for.setdefault((guid, section), item_id)

    settings = {}
    for guid, count, last, rating, rated in plex.execute(
        "select guid, view_count, last_viewed_at, rating, last_rated_at from metadata_item_settings "
        "where account_id = ?", (account,)
    ):
        settings[guid] = (count or 0, last, rating, rated)

    # Plays, as (Plex track item, when): each once, on the copy it was played from.
    sections_of: dict[bytes, list[int]] = {}
    for (guid, section) in item_for:
        sections_of.setdefault(guid, []).append(section)
    views: list[tuple[int, int]] = []
    for guid, section, viewed in plex.execute(
        "select guid, library_section_id, viewed_at from metadata_item_views where account_id = ? and metadata_type = ?",
        (account, TRACK),
    ):
        if not viewed:
            continue
        item = item_for.get((guid, section))
        if item is None and sections_of.get(guid):
            item = item_for[(guid, sections_of[guid][0])]
        if item is not None:
            views.append((item, int(viewed)))

    playlists = []
    for playlist_id, title, summary in plex.execute(
        "select id, title, summary from metadata_items where metadata_type = ?", (PLAYLIST,)
    ):
        items = [row[0] for row in plex.execute(
            "select metadata_item_id from play_queue_generators where playlist_id = ? "
            "and metadata_item_id is not null order by \"order\"", (playlist_id,)
        )]
        playlists.append({"plex_id": playlist_id, "title": text(title), "summary": text(summary), "items": items})

    return files, guid_of, settings, views, playlists


def plex_playlist_meta(token: str) -> dict[str, dict]:
    """Title -> {smart, thumb} from the HTTP API: the database does not say which
    playlists are smart in a readable way, and the cover is fetched over HTTP anyway."""
    request = urllib.request.Request(f"{PLEX_URL}/playlists?playlistType=audio",
                                     headers={"X-Plex-Token": token, "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        body = response.read().decode("utf-8", "replace")
    meta = {}
    for item in json.loads(body)["MediaContainer"].get("Metadata", []):
        meta[item.get("title")] = {"smart": bool(item.get("smart")), "thumb": item.get("thumb")}
    return meta


# MARK: - Navidrome


def read_navidrome(connection: sqlite3.Connection):
    connection.text_factory = bytes
    tracks = {}
    rows = {}
    for track_id, library, path, album, artist in connection.execute(
        "select id, library_id, path, album_id, artist_id from media_file where missing = 0"
    ):
        track_id = text(track_id)
        tracks[(library, key(path))] = track_id
        rows[track_id] = (text(album), text(artist))
    user = connection.execute("select id from user where is_admin = 1 order by created_at limit 1").fetchone()
    if not user:
        sys.exit("no Navidrome admin user")
    connection.text_factory = str
    return tracks, rows, text(user[0])


def wipe(connection, user_id: str, keep_playlists: set[str]) -> dict:
    """Removes the user's own Navidrome state, so only Plex's is written back."""
    counts = {}
    counts["annotations"] = connection.execute("delete from annotation where user_id = ?", (user_id,)).rowcount
    gone = [row[0] for row in connection.execute("select id, name from playlist where owner_id = ?", (user_id,))
            if row[1] not in keep_playlists]
    for playlist_id in gone:
        connection.execute("delete from playlist_tracks where playlist_id = ?", (playlist_id,))
        connection.execute("delete from playlist_fields where playlist_id = ?", (playlist_id,))
        connection.execute("delete from playlist where id = ?", (playlist_id,))
    counts["playlists"] = len(gone)
    counts["bookmarks"] = connection.execute("delete from bookmark where user_id = ?", (user_id,)).rowcount
    counts["play queue"] = connection.execute("delete from playqueue where user_id = ?", (user_id,)).rowcount
    return counts


def apply_changes(connection, plan, user_id, now):
    upsert = """
        insert into annotation (user_id, item_id, item_type, play_count, play_date, rating, starred, starred_at, rated_at)
        values (?,?,?,?,?,?,?,?,?)
        on conflict(user_id, item_id, item_type) do update set
            play_count = excluded.play_count, play_date = excluded.play_date, rating = excluded.rating,
            starred = excluded.starred, starred_at = excluded.starred_at, rated_at = excluded.rated_at
    """
    for track_id, a in plan["tracks"].items():
        connection.execute(upsert, (user_id, track_id, "media_file", a["plays"], a["last"], a["stars"],
                                    1 if a["loved"] else 0, a["rated"] if a["loved"] else None,
                                    a["rated"] if a["stars"] else None))
    for kind in ("album", "artist"):
        for item_id, a in plan[kind].items():
            connection.execute(upsert, (user_id, item_id, kind, a["plays"], a["last"], a["stars"], 0, None,
                                        now if a["stars"] else None))

    connection.execute("delete from scrobbles where user_id = ?", (user_id,))
    connection.executemany(
        "insert into scrobbles (media_file_id, user_id, submission_time) values (?,?,?)",
        [(track_id, user_id, when) for track_id, when in plan["scrobbles"]],
    )

    for playlist in plan["playlists"]:
        existing = connection.execute(
            "select id from playlist where name = ? and owner_id = ?", (playlist["title"], user_id)
        ).fetchone()
        rules = json.dumps(playlist["rules"], ensure_ascii=False) if playlist["rules"] else None
        if existing:
            playlist_id = existing[0]
            connection.execute(
                "update playlist set comment = ?, rules = ?, evaluated_at = null, updated_at = ? where id = ?",
                (playlist["comment"], rules, now, playlist_id),
            )
        else:
            playlist_id = uuid.uuid4().hex[:22]
            connection.execute(
                "insert into playlist (id, name, comment, public, created_at, updated_at, owner_id, sync, path, "
                "size, song_count, duration, rules) values (?,?,?,0,?,?,?,0,'',0,0,0,?)",
                (playlist_id, playlist["title"], playlist["comment"], now, now, user_id, rules),
            )
        playlist["navidrome_id"] = playlist_id
        connection.execute("delete from playlist_tracks where playlist_id = ?", (playlist_id,))
        connection.execute("delete from playlist_fields where playlist_id = ?", (playlist_id,))
        if rules:
            for field in sorted(rule_fields(playlist["rules"])):
                connection.execute("insert into playlist_fields (field, playlist_id) values (?, ?)", (field, playlist_id))
            continue
        for position, track_id in enumerate(playlist["tracks"], start=1):
            connection.execute("insert into playlist_tracks (id, playlist_id, media_file_id) values (?,?,?)",
                               (position, playlist_id, track_id))
        stats = connection.execute(
            "select coalesce(sum(duration), 0), coalesce(sum(size), 0) from media_file where id in "
            "(select media_file_id from playlist_tracks where playlist_id = ?)", (playlist_id,)
        ).fetchone()
        connection.execute("update playlist set song_count = ?, duration = ?, size = ? where id = ?",
                           (len(playlist["tracks"]), stats[0], stats[1], playlist_id))
    connection.commit()


def rule_fields(rules: dict) -> set[str]:
    """The fields a smart playlist's conditions test — `{"is": {"loved": true}}` tests
    "loved" — which Navidrome records so it knows when to re-evaluate."""
    return {field.lower() for condition in rules.get("all", []) for test in condition.values() for field in test}


# MARK: - Covers


def navidrome_login(user: str, password: str) -> str:
    body = json.dumps({"username": user, "password": password}).encode()
    request = urllib.request.Request(f"{NAVIDROME_URL}/auth/login", data=body,
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)["token"]


def upload_covers(token: str, state: dict) -> None:
    session = navidrome_login(os.environ["ND_USER"], os.environ["ND_PASSWORD"])
    for cover in state.get("covers", []):
        plex_request = urllib.request.Request(PLEX_URL + cover["thumb"], headers={"X-Plex-Token": token})
        with urllib.request.urlopen(plex_request, timeout=60) as response:
            image = response.read()
            mime = response.headers.get_content_type() or "image/jpeg"
        extension = {"image/png": "png", "image/webp": "webp"}.get(mime, "jpg")
        boundary = uuid.uuid4().hex
        body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"cover.{extension}\"\r\n"
                f"Content-Type: {mime}\r\n\r\n").encode() + image + f"\r\n--{boundary}--\r\n".encode()
        request = urllib.request.Request(
            f"{NAVIDROME_URL}/api/playlist/{cover['navidrome_id']}/image", data=body, method="POST",
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}",
                     "X-ND-Authorization": f"Bearer {session}"},
        )
        with urllib.request.urlopen(request, timeout=60) as response:
            print(f"cover: {cover['title']} ({len(image) // 1024} KB) -> HTTP {response.status}")


# MARK: - Main


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--navidrome-db")
    parser.add_argument("--plex-db", default=PLEX_DB)
    parser.add_argument("--account", type=int, default=1)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--clean", action="store_true",
                        help="remove all of the user's Navidrome state first: a clean carry-over")
    parser.add_argument("--images", action="store_true", help="upload playlist covers (Navidrome running)")
    args = parser.parse_args()
    token = os.environ["PLEX_TOKEN"]

    if args.images:
        upload_covers(token, json.loads(STATE.read_text()))
        return
    if not args.navidrome_db:
        sys.exit("--navidrome-db is required")

    files, guid_of, settings, views, plex_playlists = read_plex(args.plex_db, args.account)
    meta = plex_playlist_meta(token)
    if args.apply:
        navidrome = sqlite3.connect(args.navidrome_db)
    else:
        # A dry run reads a copy, so it is safe with Navidrome running.
        scratch = tempfile.mkdtemp(prefix="nddb-")
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(args.navidrome_db + suffix):
                shutil.copy2(args.navidrome_db + suffix, os.path.join(scratch, "nd.db" + suffix))
        navidrome = sqlite3.connect(os.path.join(scratch, "nd.db"))
    tracks, rows, user_id = read_navidrome(navidrome)

    plex_to_nd = {}
    unmatched = []
    for item_id, location in files.items():
        track_id = tracks.get(location)
        if track_id:
            plex_to_nd[item_id] = track_id
        else:
            unmatched.append(location)

    # Tracks: Plex's numbers for every matched track, zeros included.
    plan_tracks = {}
    for item_id, track_id in plex_to_nd.items():
        count, last, rating, rated = settings.get(guid_of[item_id], (0, None, None, None))
        stars = max(0, min(5, int(round(float(rating) / 2)))) if rating else 0
        plan_tracks[track_id] = {"plays": count, "last": ts(last), "stars": stars,
                                 "loved": bool(rating and float(rating) >= LOVED), "rated": ts(rated)}

    def rollup(index: int) -> dict:
        totals: dict[str, dict] = {}
        for track_id, a in plan_tracks.items():
            group = rows[track_id][index]
            if not group:
                continue
            entry = totals.setdefault(group, {"plays": 0, "last": None, "stars": 0})
            entry["plays"] += a["plays"]
            if a["last"] and (not entry["last"] or a["last"] > entry["last"]):
                entry["last"] = a["last"]
            entry["stars"] = max(entry["stars"], a["stars"])
        return totals

    scrobbles = sorted((plex_to_nd[item], when) for item, when in views if item in plex_to_nd)

    playlists, covers = [], []
    for playlist in plex_playlists:
        info = meta.get(playlist["title"], {})
        smart = info.get("smart", False)
        if smart and playlist["title"] not in SMART_RULES:
            print(f"  skip smart playlist with no Navidrome equivalent: {playlist['title']}")
            continue
        ids = [plex_to_nd[item] for item in playlist["items"] if item in plex_to_nd]
        playlists.append({
            "title": playlist["title"], "comment": playlist["summary"] or "imported from Plex",
            "rules": SMART_RULES.get(playlist["title"]) if smart else None, "tracks": ids,
            "thumb": info.get("thumb"),
        })
        missing = len(playlist["items"]) - len(ids)
        print(f"  playlist {playlist['title']!r}: " + ("smart" if smart else f"{len(ids)} tracks ({missing} unmatched)")
              + (" + cover" if info.get("thumb") else ""))

    current = navidrome.execute(
        "select count(*), sum(play_count), sum(starred), sum(rating > 0) from annotation "
        "where user_id = ? and item_type = 'media_file'", (user_id,)
    ).fetchone()
    loved = sum(1 for a in plan_tracks.values() if a["loved"])
    print(f"plex tracks {len(files)}, matched {len(plex_to_nd)}, unmatched {len(unmatched)}")
    for location in unmatched[:10]:
        print(f"  unmatched: library {location[0]}: {location[1]}")
    print(f"navidrome now: {current[0]} annotated, {current[1]} plays, {current[2]} favourites, {current[3]} rated")
    print(f"after: {sum(1 for a in plan_tracks.values() if a['plays'])} played, "
          f"{sum(a['plays'] for a in plan_tracks.values())} plays, {loved} favourites, "
          f"{sum(1 for a in plan_tracks.values() if a['stars'])} rated; {len(scrobbles)} history entries")

    if not args.apply:
        print("\nDRY RUN — nothing written. Re-run with --apply (Navidrome stopped).")
        return

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    if args.clean:
        removed = wipe(navidrome, user_id, {playlist["title"] for playlist in playlists})
        print("cleared: " + ", ".join(f"{count} {name}" for name, count in removed.items()))
    plan = {"tracks": plan_tracks, "album": rollup(0), "artist": rollup(1), "scrobbles": scrobbles,
            "playlists": playlists}
    apply_changes(navidrome, plan, user_id, now)
    for playlist in playlists:
        if playlist["thumb"]:
            covers.append({"title": playlist["title"], "thumb": playlist["thumb"], "navidrome_id": playlist["navidrome_id"]})
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps({"covers": covers, "at": now}, ensure_ascii=False, indent=2))
    print(f"written: {len(plan_tracks)} tracks, {len(plan['album'])} albums, {len(plan['artist'])} artists, "
          f"{len(scrobbles)} plays of history, {len(playlists)} playlists; {len(covers)} covers to upload with --images")


if __name__ == "__main__":
    main()
