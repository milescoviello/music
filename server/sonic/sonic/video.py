"""Music videos, for the apps' Song | Video switch and the YouTube results in search.

Three jobs:

- **Finding one.** A YouTube search through yt-dlp, scored for the official video: the
  artist's own or a verified channel, every word of the song's title, a length near the
  track's, and no live, lyric, cover or reaction cut. The pick is remembered per song --
  by artist and title, so both copies of a song in the two libraries share it -- and a pick
  made by hand replaces it for good.
- **Playing one, with no ads.** YouTube serves its best quality as separate video and
  audio streams: fragmented MP4, each with an index (`sidx`) of where every few seconds
  start. That index is all HLS needs, so this writes the playlists itself -- every segment
  a byte range of the one file -- and relays the bytes. AVPlayer plays the result natively,
  adaptive and seekable, and nothing is stored. It is lossy, because that is what YouTube
  has; the library's own files are what the Song side plays.
- **The desktop** opens the best video and audio streams directly, through the same relay.

The stream addresses YouTube hands out are tied to the address that asked for them and
expire after a few hours. That is why the bytes come through here rather than the apps
fetching them: a phone away from home has another address. They also refuse every request
for the first few seconds (yt-dlp's `available_at`), which the relay waits out -- and which
is why a song's video is looked up ahead, while its player is open.

yt-dlp stops working within weeks of YouTube changing something, so the copy in the image is
only the floor: a newer one is installed into the data folder when extraction starts
failing, and once a week overnight, and the service restarts onto it when no video is
playing (see `Updater`).
"""

from __future__ import annotations

import logging
import math
import os
import re
import subprocess
import sys
import sqlite3
import struct
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger("sonic.video")

# A pick made automatically is looked for again after this long; "no video" sooner, since
# a video can appear later. One chosen by hand is kept until it is changed.
AUTO_KEEP = 90 * 86400
NONE_KEEP = 7 * 86400
# The tallest H.264 stream offered. YouTube has nothing taller in H.264, and its VP9 and
# AV1 streams are not something every phone can decode.
MAX_HEIGHT = 1080


# ---------------------------------------------------------------------------- text


def norm(text: str | None) -> str:
    """Lower case, accents and scripts kept, punctuation gone: words for comparing."""
    text = unicodedata.normalize("NFKC", text or "").casefold().replace("&", " and ")
    text = re.sub(r"[\"'’‘`]", "", text)
    return " ".join(re.findall(r"\w+", text))


def core_title(title: str | None) -> str:
    """A title without what versions add to it: "(Remastered 2011)", "[Live]", " - Edit"."""
    title = title or ""
    bare = re.split(r"\s+[-–—]\s+", title)[0]
    bare = re.sub(r"\([^)]*\)|\[[^\]]*\]", "", bare).strip()
    return bare or title.strip()


def song_key(artist: str | None, title: str | None) -> str:
    """One key for a song in either library: its artist and its bare title."""
    return f"{norm(artist)}\x1f{norm(core_title(title))}"


# Words that mark a video as something other than the song's own. Each is ignored when the
# song's title has it too ("Live Forever" is not a live recording).
PENALTIES = {
    "live": 35, "concert": 35, "tour": 20, "performance": 30, "session": 25, "unplugged": 25,
    "cover": 45, "reaction": 60, "karaoke": 60, "instrumental": 40, "remix": 35, "slowed": 50,
    "sped up": 50, "nightcore": 60, "8d": 50, "tutorial": 60, "lesson": 60, "how to play": 60,
    "full album": 60, "hour": 40, "loop": 30, "extended": 20, "teaser": 40, "trailer": 40,
    "behind the scenes": 50, "making of": 50, "interview": 50, "fan made": 40, "fanmade": 40,
    "amv": 50, "shorts": 40, "lyrics": 18, "lyric": 18, "visualizer": 18, "visualiser": 18,
    "audio": 12, "remastered": 5, "remaster": 5, "piano": 25, "guitar": 25, "drum": 25, "acoustic": 20, "demo": 20,
}
OFFICIAL = re.compile(r"\bofficial (music )?video\b|\bofficial mv\b|\bmv\b")
MUSIC_VIDEO = re.compile(r"\bmusic video\b")
# Brackets in a video's title that say what kind of upload it is, not what the song is.
UPLOAD_NOTES = re.compile(
    r"\s*[\(\[【][^\)\]】]*\b(official|video|audio|lyrics?|visuali[sz]er|hd|hq|4k|"
    r"remaster(ed)?|mv|m/v|clip|explicit|uncensored)\b[^\)\]】]*[\)\]】]",
    re.IGNORECASE,
)


def _channel_words(channel: str) -> str:
    return re.sub(r"\b(vevo|official|topic|music|tv|channel)\b", " ", norm(channel)).replace(" ", "")


def score(item: dict, artist: str, title: str, duration: float | None) -> float:
    """How likely a search result is this song's official video. Above 15 is a pick."""
    name = norm(item.get("title"))
    words = set(name.split())
    want = norm(core_title(title)).split()
    if not want:
        return -math.inf
    song_words = set(norm(title).split())
    artist_words = norm(artist).split()
    total = 0.0

    covered = sum(word in words for word in want) / len(want)
    if covered < 1:
        total -= 40 * (1 - covered) + (25 if covered < 0.5 else 0)

    channel = norm(item.get("channel"))
    compact_artist = "".join(artist_words)
    own = bool(compact_artist) and _channel_words(channel) == compact_artist
    topic = channel.endswith(" topic")
    if own and not topic:
        total += 30
    elif artist_words and all(word in words for word in artist_words):
        total += 10
    elif own:
        total += 5
    else:
        total -= 30
    if item.get("verified"):
        total += 8
    if "vevo" in channel.replace(" ", ""):
        total += 8
    if OFFICIAL.search(name):
        total += 20
    elif MUSIC_VIDEO.search(name):
        total += 8                        # what a fan upload calls itself too
    if topic:
        total -= 10                       # a still picture over the album track
    for phrase, weight in PENALTIES.items():
        phrase_words = phrase.split()
        if all(word in words for word in phrase_words) and not all(word in song_words for word in phrase_words):
            total -= weight

    length = item.get("duration") or 0
    if length and (length < 60 or length > 1200):
        total -= 40
    if duration and length:
        off = abs(length - duration)
        total += 12 if off <= 10 else 6 if off <= 45 else 0 if off <= 120 else -20
    total += min(15.0, math.log10(max(item.get("views") or 1, 1)) * 2)
    return total


def guess_song(item: dict) -> tuple[str, str]:
    """The artist and song a video is of, for asking the library to get it."""
    title = UPLOAD_NOTES.sub("", item.get("title") or "").strip()
    channel = item.get("channel") or ""
    parts = re.split(r"\s+[-–—|]\s+", title, maxsplit=1)
    if len(parts) == 2 and parts[0].strip() and parts[1].strip():
        artist, song = parts[0].strip(), parts[1].strip()
    else:
        artist = re.sub(r"\s*-\s*topic$|vevo$|\s*official$", "", channel, flags=re.IGNORECASE).strip()
        song = title
    song = re.sub(r"\s*\|.*$", "", song).strip(" -–—") or song
    return artist, song


def _item(entry: dict) -> dict | None:
    """A search result as the apps see it."""
    video_id = entry.get("id")
    if not video_id or entry.get("live_status") in ("is_live", "is_upcoming"):
        return None
    if (entry.get("url") or "").find("/shorts/") >= 0:
        return None
    item = {
        "id": video_id,
        "title": entry.get("title") or "",
        "channel": entry.get("channel") or entry.get("uploader") or "",
        "duration": entry.get("duration"),
        "verified": bool(entry.get("channel_is_verified")),
        "views": entry.get("view_count"),
    }
    item["artist"], item["song"] = guess_song(item)
    return item


# ---------------------------------------------------------------------------- MP4 index


@dataclass
class Index:
    """Where a fragmented MP4's header ends and each of its fragments lies."""
    init_end: int                         # bytes [0, init_end) are ftyp + moov
    segments: list[tuple[int, int, float]]  # (offset, size, seconds)

    @property
    def duration(self) -> float:
        return sum(seconds for _, _, seconds in self.segments)

    @property
    def peak_bps(self) -> float:
        return max((size * 8 / seconds for _, size, seconds in self.segments if seconds > 0), default=0)


def parse_index(data: bytes) -> Index | None:
    """The `sidx` box of a fragmented MP4, from its first bytes. None if it is not there."""
    offset = 0
    while offset + 8 <= len(data):
        size, kind = struct.unpack(">I4s", data[offset:offset + 8])
        header = 8
        if size == 1:
            if offset + 16 > len(data):
                return None
            size = struct.unpack(">Q", data[offset + 8:offset + 16])[0]
            header = 16
        if size < header:
            return None
        if kind == b"sidx":
            if offset + size > len(data):
                return None
            body = data[offset + header:offset + size]
            version = body[0]
            timescale = struct.unpack(">I", body[8:12])[0]
            at = 12
            if version == 0:
                _, first = struct.unpack(">II", body[at:at + 8]); at += 8
            else:
                _, first = struct.unpack(">QQ", body[at:at + 16]); at += 16
            count = struct.unpack(">H", body[at + 2:at + 4])[0]; at += 4
            position = offset + size + first
            segments = []
            for _ in range(count):
                reference, length, _sap = struct.unpack(">III", body[at:at + 12]); at += 12
                referenced = reference & 0x7FFFFFFF
                segments.append((position, referenced, length / timescale if timescale else 0.0))
                position += referenced
            return Index(init_end=offset, segments=segments) if segments and timescale else None
        offset += size
    return None


def media_playlist(index: Index, uri: str) -> str:
    """An HLS media playlist whose every segment is a byte range of one file."""
    target = max(1, math.ceil(max(seconds for _, _, seconds in index.segments)))
    lines = [
        "#EXTM3U",
        "#EXT-X-VERSION:7",
        f"#EXT-X-TARGETDURATION:{target}",
        "#EXT-X-MEDIA-SEQUENCE:0",
        "#EXT-X-PLAYLIST-TYPE:VOD",
        "#EXT-X-INDEPENDENT-SEGMENTS",
        f'#EXT-X-MAP:URI="{uri}",BYTERANGE="{index.init_end}@0"',
    ]
    for offset, size, seconds in index.segments:
        lines += [f"#EXTINF:{seconds:.5f},", f"#EXT-X-BYTERANGE:{size}@{offset}", uri]
    lines.append("#EXT-X-ENDLIST")
    return "\n".join(lines) + "\n"


def master_playlist(videos: list[dict], audio: dict, suffix: str = "") -> str:
    """The playlist AVPlayer is given: every video height, with the one audio stream."""
    lines = [
        "#EXTM3U",
        "#EXT-X-VERSION:7",
        "#EXT-X-INDEPENDENT-SEGMENTS",
        f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,'
        f'CHANNELS="2",URI="{audio["itag"]}.m3u8{suffix}"',
    ]
    for video in videos:
        peak = int(video["peak"] + audio["peak"])
        average = int(video["average"] + audio["average"])
        lines.append(
            f'#EXT-X-STREAM-INF:BANDWIDTH={peak},AVERAGE-BANDWIDTH={average},'
            f'CODECS="{video["codec"]},{audio["codec"]}",RESOLUTION={video["width"]}x{video["height"]},'
            f'FRAME-RATE={video["fps"]:.3f},AUDIO="audio"'
        )
        lines.append(f'{video["itag"]}.m3u8{suffix}')
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------- picks


class Picks:
    """Which video each song gets: chosen by hand, found automatically, or none found."""

    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._lock = threading.Lock()
        with self._lock:
            self._db.execute(
                "create table if not exists picks (key text primary key, video_id text, title text,"
                " channel text, duration real, manual integer not null default 0,"
                " offset real not null default 0, at real not null)"
            )
            self._db.commit()

    def get(self, key: str) -> dict | None:
        with self._lock:
            row = self._db.execute(
                "select video_id, title, channel, duration, manual, offset, at from picks where key = ?", (key,)
            ).fetchone()
        if row is None:
            return None
        video_id, title, channel, duration, manual, offset, at = row
        video = {"id": video_id, "title": title, "channel": channel, "duration": duration} if video_id else None
        return {"video": video, "manual": bool(manual), "offset": offset, "at": at}

    def put(self, key: str, video: dict | None, manual: bool) -> None:
        with self._lock:
            self._db.execute(
                "insert or replace into picks (key, video_id, title, channel, duration, manual, offset, at)"
                " values (?, ?, ?, ?, ?, ?, 0, ?)",
                (key, (video or {}).get("id"), (video or {}).get("title"), (video or {}).get("channel"),
                 (video or {}).get("duration"), int(manual), time.time()),
            )
            self._db.commit()

    def delete(self, key: str) -> None:
        with self._lock:
            self._db.execute("delete from picks where key = ?", (key,))
            self._db.commit()


# ---------------------------------------------------------------------------- streams


@dataclass
class Stream:
    itag: str
    url: str
    headers: dict
    ext: str
    codec: str
    height: int = 0
    width: int = 0
    fps: float = 0
    tbr: float = 0                         # kbit/s, YouTube's average
    size: int | None = None
    index: Index | None = None


@dataclass
class Resolved:
    video_id: str
    title: str
    channel: str
    duration: float
    videos: list[Stream]                   # H.264, tallest first
    audio: Stream | None                   # AAC, for HLS
    best_audio: Stream | None              # Opus if there is one, for the desktop
    expires: float
    available_at: float = 0.0              # YouTube refuses the streams until then
    lock: threading.Lock = field(default_factory=threading.Lock)

    def wait_until_available(self) -> None:
        delay = self.available_at - time.time()
        if delay > 0:
            time.sleep(min(delay + 0.3, 15))

    def stream(self, itag: str) -> Stream | None:
        for stream in [*self.videos, self.audio, self.best_audio]:
            if stream is not None and stream.itag == itag:
                return stream
        return None


class Videos:
    def __init__(self, data_dir: Path):
        self.updater = Updater(data_dir / "pylib")
        self.picks = Picks(data_dir / "videos.db")
        self._resolved: dict[str, Resolved] = {}
        self._resolving: dict[str, threading.Lock] = {}
        self._guard = threading.Lock()
        self._extract = threading.Semaphore(3)
        self._background = ThreadPoolExecutor(max_workers=2, thread_name_prefix="video-warm")
        self._thumbs: dict[str, bytes] = {}

    # -- yt-dlp

    def _ydl(self, **extra):
        import yt_dlp

        # YouTube's stream addresses come out of a JavaScript challenge, which yt-dlp runs
        # in Deno (installed beside it).
        options = {
            "quiet": True, "no_warnings": True, "noprogress": True, "skip_download": True,
            "socket_timeout": 15,
        }
        options.update(extra)
        return yt_dlp.YoutubeDL(options)

    def search(self, query: str, limit: int = 12) -> list[dict]:
        query = (query or "").strip()
        if not query:
            return []
        try:
            with self._extract, self._ydl(extract_flat="in_playlist") as ydl:
                info = ydl.extract_info(f"ytsearch{max(1, min(limit + 4, 30))}:{query}", download=False)
        except Exception:
            self.updater.failed()
            raise
        items = [item for item in (_item(entry) for entry in info.get("entries") or []) if item]
        return items[:limit]

    # -- picks

    def match(self, artist: str, title: str, duration: float | None, warm: bool = False) -> dict:
        key = song_key(artist, title)
        kept = self.picks.get(key)
        fresh = kept is not None and (
            kept["manual"] or time.time() - kept["at"] < (AUTO_KEEP if kept["video"] else NONE_KEEP))
        if not fresh:
            video = self.auto_pick(artist, title, duration)
            self.picks.put(key, video, manual=False)
            kept = self.picks.get(key)
        answer = {"video": kept["video"], "manual": kept["manual"], "offset": kept["offset"]}
        if warm and answer["video"]:
            self._background.submit(self._warm, answer["video"]["id"])
        return answer

    def auto_pick(self, artist: str, title: str, duration: float | None) -> dict | None:
        items = self.search(f"{artist} {core_title(title)} official video", limit=10)
        # Ties go to the most watched: the official video, over the same channel's audio upload.
        scored = sorted(((score(item, artist, title, duration), item) for item in items),
                        key=lambda pair: (pair[0], pair[1].get("views") or 0), reverse=True)
        if scored and scored[0][0] >= 15:
            best = scored[0][1]
            log.info("video for %s: %s (%.0f)", song_key(artist, title).replace("\x1f", " / "), best["id"], scored[0][0])
            return {key: best[key] for key in ("id", "title", "channel", "duration")}
        return None

    def choose(self, artist: str, title: str, video: dict) -> dict:
        if not re.fullmatch(r"[A-Za-z0-9_-]{11}", str(video.get("id") or "")):
            raise ValueError("not a YouTube video id")
        self.picks.put(song_key(artist, title), video, manual=True)
        return self.match(artist, title, None)

    def reset(self, artist: str, title: str) -> None:
        self.picks.delete(song_key(artist, title))

    # -- streams

    def _warm(self, video_id: str) -> None:
        try:
            resolved = self.resolve(video_id)
            for stream in [*resolved.videos, resolved.audio]:
                if stream is not None:
                    self.index(resolved, stream)
        except Exception:  # noqa: BLE001 — warming is a favour; the real request says why
            log.info("could not warm %s", video_id, exc_info=True)

    def resolve(self, video_id: str, again: bool = False) -> Resolved:
        if not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
            raise ValueError("not a YouTube video id")
        with self._guard:
            lock = self._resolving.setdefault(video_id, threading.Lock())
        with lock:
            kept = self._resolved.get(video_id)
            if kept and not again and kept.expires > time.time():
                return kept
            try:
                with self._extract, self._ydl() as ydl:
                    info = ydl.extract_info(f"https://www.youtube.com/watch?v={video_id}", download=False)
            except Exception:
                self.updater.failed()
                raise
            resolved = _streams(info)
            with self._guard:
                self._resolved[video_id] = resolved
                if len(self._resolved) > 200:          # forget the oldest
                    for old in sorted(self._resolved, key=lambda k: self._resolved[k].expires)[:50]:
                        self._resolved.pop(old, None)
            return resolved

    def index(self, resolved: Resolved, stream: Stream) -> Index:
        with resolved.lock:
            if stream.index is not None:
                return stream.index
        length = 64 * 1024
        while True:
            data = self._fetch(stream, f"bytes=0-{length - 1}")
            index = parse_index(data)
            if index is not None or len(data) < length or length >= 4 * 1024 * 1024:
                break
            length *= 4
        if index is None:
            raise ValueError(f"no index in stream {stream.itag}")
        with resolved.lock:
            stream.index = index
        return index

    def _fetch(self, stream: Stream, byte_range: str) -> bytes:
        self._resolved_for(stream).wait_until_available()
        request = urllib.request.Request(stream.url, headers={**stream.headers, "Range": byte_range})
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.read()

    def _resolved_for(self, stream: Stream) -> Resolved:
        with self._guard:
            for resolved in self._resolved.values():
                if stream in (*resolved.videos, resolved.audio, resolved.best_audio):
                    return resolved
        return Resolved("", "", "", 0, [], None, None, 0)

    def master(self, video_id: str, suffix: str = "") -> str:
        resolved = self.resolve(video_id)
        if not resolved.videos or resolved.audio is None:
            raise LookupError("no stream this player can play")
        audio_index = self.index(resolved, resolved.audio)
        variants = []
        for stream in resolved.videos:
            try:
                index = self.index(resolved, stream)
            except Exception:  # noqa: BLE001 — one height missing leaves the others
                log.info("no index for %s/%s", video_id, stream.itag, exc_info=True)
                continue
            variants.append({
                "itag": stream.itag, "codec": stream.codec, "width": stream.width, "height": stream.height,
                "fps": stream.fps or 30, "peak": index.peak_bps,
                "average": (stream.tbr or 0) * 1000 or index.peak_bps,
            })
        if not variants:
            raise LookupError("no stream this player can play")
        audio = {"itag": resolved.audio.itag, "codec": resolved.audio.codec, "peak": audio_index.peak_bps,
                 "average": (resolved.audio.tbr or 0) * 1000 or audio_index.peak_bps}
        return master_playlist(variants, audio, suffix)

    def media(self, video_id: str, itag: str, suffix: str = "") -> str:
        resolved = self.resolve(video_id)
        stream = resolved.stream(itag)
        if stream is None or stream.ext not in ("mp4", "m4a"):
            raise LookupError("no such stream")
        return media_playlist(self.index(resolved, stream), f"{itag}.{stream.ext}{suffix}")

    def streams(self, video_id: str, suffix: str = "") -> dict:
        """The desktop's: the tallest video stream and the best audio, to open directly."""
        resolved = self.resolve(video_id)
        if not resolved.videos:
            raise LookupError("no video stream")
        video = resolved.videos[0]
        audio = resolved.best_audio or resolved.audio
        if audio is None:
            raise LookupError("no audio stream")
        return {
            "id": video_id, "title": resolved.title, "channel": resolved.channel, "duration": resolved.duration,
            "width": video.width, "height": video.height,
            "video": f"v1/video/{video_id}/{video.itag}.{video.ext}{suffix}",
            "audio": f"v1/video/{video_id}/{audio.itag}.{audio.ext}{suffix}",
            "audioCodec": audio.codec,
        }

    def open_stream(self, video_id: str, itag: str, byte_range: str | None):
        """The upstream response for a relayed request, asked again with fresh addresses
        when the old ones have expired."""
        for again in (False, True):
            resolved = self.resolve(video_id, again=again)
            stream = resolved.stream(itag)
            if stream is None:
                raise LookupError("no such stream")
            headers = dict(stream.headers)
            if byte_range:
                headers["Range"] = byte_range
            resolved.wait_until_available()
            self.updater.relaying(+1)
            try:
                upstream = urllib.request.urlopen(urllib.request.Request(stream.url, headers=headers), timeout=20)
            except urllib.error.HTTPError as error:
                self.updater.relaying(-1)
                if error.code == 416 or again or error.code not in (403, 404, 410):
                    raise
                log.info("stream %s/%s refused (%d): asking YouTube again", video_id, itag, error.code)
                continue
            except BaseException:
                self.updater.relaying(-1)
                raise
            return stream, _Counted(self.updater, upstream)
        raise LookupError("unreachable")

    def thumbnail(self, video_id: str) -> bytes | None:
        if not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
            return None
        kept = self._thumbs.get(video_id)
        if kept is not None:
            return kept
        try:
            with urllib.request.urlopen(f"https://i.ytimg.com/vi/{video_id}/mqdefault.jpg", timeout=10) as response:
                data = response.read()
        except (urllib.error.URLError, TimeoutError):
            return None
        if len(self._thumbs) > 1000:
            self._thumbs.clear()
        self._thumbs[video_id] = data
        return data


def _streams(info: dict) -> Resolved:
    """The streams worth offering out of what yt-dlp found."""
    videos: dict[int, Stream] = {}
    aac: Stream | None = None
    opus: Stream | None = None
    expires = time.time() + 4 * 3600
    available_at = 0.0
    for f in info.get("formats") or []:
        if f.get("protocol") != "https" or not f.get("url"):
            continue
        vcodec, acodec = f.get("vcodec") or "none", f.get("acodec") or "none"
        query = urllib.parse.parse_qs(urllib.parse.urlparse(f["url"]).query)
        if "expire" in query:
            try:
                expires = min(expires, float(query["expire"][0]) - 600)
            except ValueError:
                pass
        if f.get("available_at"):
            available_at = max(available_at, float(f["available_at"]))
        stream = Stream(
            itag=str(f.get("format_id")), url=f["url"], headers=dict(f.get("http_headers") or {}),
            ext=f.get("ext") or "", codec="", height=int(f.get("height") or 0), width=int(f.get("width") or 0),
            fps=float(f.get("fps") or 0), tbr=float(f.get("tbr") or 0), size=f.get("filesize"),
        )
        if acodec == "none" and vcodec.startswith("avc1") and stream.ext == "mp4" and 0 < stream.height <= MAX_HEIGHT:
            stream.codec = vcodec
            kept = videos.get(stream.height)
            if kept is None or stream.tbr > kept.tbr:
                videos[stream.height] = stream
        elif vcodec == "none" and acodec.startswith("mp4a") and stream.ext == "m4a":
            stream.codec = acodec
            if aac is None or stream.tbr > aac.tbr:
                aac = stream
        elif vcodec == "none" and acodec == "opus" and stream.ext == "webm":
            stream.codec = "opus"
            if opus is None or stream.tbr > opus.tbr:
                opus = stream
    return Resolved(
        video_id=info.get("id") or "", title=info.get("title") or "", channel=info.get("channel") or "",
        duration=float(info.get("duration") or 0),
        videos=[videos[height] for height in sorted(videos, reverse=True)],
        audio=aac, best_audio=opus or aac, expires=expires, available_at=available_at,
    )


class _Counted:
    """An upstream response that tells the updater when it is done with."""

    def __init__(self, updater: "Updater", response):
        self._updater, self._response = updater, response
        self.status, self.headers = response.status, response.headers

    def read(self, size: int = -1) -> bytes:
        return self._response.read(size)

    def __enter__(self):
        return self

    def __exit__(self, *exc) -> None:
        try:
            self._response.close()
        finally:
            self._updater.relaying(-1)


class Updater:
    """Keeps yt-dlp current without rebuilding the image.

    A newer yt-dlp goes into `target`, which is put at the front of `sys.path` at start-up.
    Asked for when extraction fails (at most every six hours) and once a week between 2 and
    5 in the morning, Pacific time -- the container's own clock is UTC; when it installs a newer version, the service exits once no video is
    being relayed, and Docker starts it again on the new one. The analysis picks up where it
    was.
    """

    def __init__(self, target: Path):
        self.target = target
        self._active = 0
        self._lock = threading.Lock()
        self._last_try = 0.0
        self._restart = False
        if target.is_dir() and str(target) not in sys.path:
            sys.path.insert(0, str(target))
        threading.Thread(target=self._weekly, name="yt-dlp-update", daemon=True).start()

    def relaying(self, change: int) -> None:
        with self._lock:
            self._active = max(0, self._active + change)
            idle = self._active == 0
        if idle and self._restart:
            self._exit()

    def failed(self) -> None:
        if time.time() - self._last_try > 6 * 3600:
            threading.Thread(target=self.update, name="yt-dlp-update", daemon=True).start()

    @staticmethod
    def _pacific_hour() -> int:
        try:
            from datetime import datetime
            from zoneinfo import ZoneInfo

            return datetime.now(ZoneInfo("America/Los_Angeles")).hour
        except Exception:  # noqa: BLE001 — no zone data: UTC less eight
            return (time.gmtime().tm_hour - 8) % 24

    def _weekly(self) -> None:
        stamp = self.target / ".checked"
        while True:
            time.sleep(1800)
            hour = self._pacific_hour()
            last = stamp.stat().st_mtime if stamp.exists() else 0
            if 2 <= hour < 5 and time.time() - last > 6.5 * 86400:
                self.update()

    def update(self) -> None:
        self._last_try = time.time()
        before = _installed_version()
        staging = self.target.with_name(self.target.name + ".new")
        try:
            subprocess.run([sys.executable, "-m", "pip", "install", "--quiet", "--no-cache-dir", "--upgrade",
                            "--target", str(staging), "yt-dlp[default]"],
                           check=True, capture_output=True, timeout=600)
        except (subprocess.SubprocessError, OSError) as error:
            log.warning("could not update yt-dlp: %s", error)
            return
        after = _version_in(staging)
        if not after or after == before:
            subprocess.run(["rm", "-rf", str(staging)], check=False)
            self.target.mkdir(parents=True, exist_ok=True)
            (self.target / ".checked").touch()
            return
        subprocess.run(["rm", "-rf", str(self.target)], check=False)
        staging.rename(self.target)
        (self.target / ".checked").touch()
        log.info("yt-dlp %s installed (was %s); restarting onto it when no video is playing", after, before)
        self._restart = True
        self.relaying(0)

    def _exit(self) -> None:
        log.info("restarting for the new yt-dlp")
        logging.shutdown()
        os._exit(3)


def _installed_version() -> str | None:
    try:
        import yt_dlp.version

        return yt_dlp.version.__version__
    except ImportError:
        return None


def _version_in(folder: Path) -> str | None:
    text = (folder / "yt_dlp" / "version.py")
    if not text.exists():
        return None
    match = re.search(r"__version__\s*=\s*'([^']+)'", text.read_text())
    return match[1] if match else None
