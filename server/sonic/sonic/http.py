"""The HTTP side: small, JSON, and read-only apart from the logs the app sends for
fixing a bug, the plays and skips it shares between devices, which music video a song
gets, lyrics fixed by hand, which go back into the file they came from (`lyricsfile`), and
lyrics found on LRCLIB for a song with none (`lrclib`). Standard library only, so the service has nothing to install beyond Essentia, NumPy
and, for the videos, yt-dlp."""

from __future__ import annotations

import json
import logging
import re
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlparse

from .config import TAGS
from .links import history_links
from .logs import LIMIT, LogBox
from .lyricsfile import Refused

log = logging.getLogger("sonic.http")


def _int(query: dict, name: str, default: int, low: int = 0, high: int = 1000) -> int:
    try:
        return max(low, min(high, int(query.get(name, [default])[0])))
    except (TypeError, ValueError):
        return default


def _flag(query: dict, name: str) -> bool:
    return query.get(name, ["0"])[0] in ("1", "true", "yes")


def _list(query: dict, name: str) -> list[str]:
    return [item for item in query.get(name, [""])[0].split(",") if item]


def _items(hits) -> dict | None:
    return None if hits is None else {"items": [hit.json() for hit in hits]}


def _text(query: dict, name: str) -> str:
    return query.get(name, [""])[0]


def _seconds(query: dict, name: str) -> float | None:
    try:
        value = float(query.get(name, [""])[0])
    except ValueError:
        return None
    return value if value > 0 else None


VIDEO_RAW = re.compile(
    r"^/v1/video/([A-Za-z0-9_-]{11})/"
    r"(master\.m3u8|thumb|(\d+)\.(m3u8|mp4|m4a|webm)|h(\d+)\.m3u8|h(\d+)/(\d+)\.(ts|mp4|m4s|aac))$"
)


def make_handler(service):
    def _token_suffix(query: dict) -> str:
        """Carried on to the addresses a playlist names, when that is how the token came."""
        token = query.get("token", [""])[0]
        return f"?token={quote(token)}" if token else ""

    logs = LogBox(service.config.data_dir / "logs")
    routes = [
        (re.compile(r"^/v1/status$"), lambda match, q: service.status()),
        (re.compile(r"^/v1/tracks/([^/]+)/levels$"),
         lambda match, q: service.levels(match[1], _int(q, "points", 128, 0, 100_000))),
        (re.compile(r"^/v1/tracks/([^/]+)/rhythm$"), lambda match, q: service.rhythm(match[1])),
        (re.compile(r"^/v1/tracks/([^/]+)/similar$"),
         lambda match, q: _items(service.index.similar(
             match[1], _int(q, "limit", 50, 1, 500), _flag(q, "exclude_artist"),
             float(q["max_distance"][0]) if "max_distance" in q else None))),
        (re.compile(r"^/v1/tracks/([^/]+)/distant$"),
         lambda match, q: _items(service.index.distant(match[1], _int(q, "limit", 50, 1, 500)))),
        (re.compile(r"^/v1/tracks/([^/]+)/tags$"),
         lambda match, q: (lambda tags: None if tags is None else {"id": match[1], "tags": tags})(
             service.index.tags(match[1], _int(q, "limit", 8, 1, len(TAGS))))),
        (re.compile(r"^/v1/albums/([^/]+)/similar$"),
         lambda match, q: _items(service.index.similar_albums(
             match[1], _int(q, "limit", 20, 1, 200), not q.get("exclude_artist", ["1"])[0] == "0"))),
        (re.compile(r"^/v1/artists/([^/]+)/similar$"),
         lambda match, q: _items(service.index.similar_artists(match[1], _int(q, "limit", 20, 1, 200)))),
        (re.compile(r"^/v1/path$"),
         lambda match, q: _items(service.index.path(
             q.get("from", [""])[0], q.get("to", [""])[0], _int(q, "steps", 10, 1, 50)))),
        (re.compile(r"^/v1/radio$"),
         lambda match, q: _items(service.index.radio(_list(q, "seed"), _list(q, "exclude"), _int(q, "limit", 25, 1, 500)))),
        (re.compile(r"^/v1/tags$"), lambda match, q: {"tags": TAGS}),
        (re.compile(r"^/v1/tags/([^/]+)/tracks$"),
         lambda match, q: _items(service.index.tagged(match[1], _int(q, "limit", 50, 1, 500)))),
        (re.compile(r"^/v1/lyrics/search$"),
         lambda match, q: _items(service.lyrics.search(q.get("q", [""])[0], _int(q, "limit", 20, 1, 100)))),
        (re.compile(r"^/v1/taste$"),
         lambda match, q: service.taste.since(_int(q, "since", 0, 0, 2**62), q.get("device", [""])[0],
                                              _int(q, "limit", 5000, 1, 5000))),
        (re.compile(r"^/v1/radar$"), lambda match, q: service.radar.answer()),
        (re.compile(r"^/v1/shows$"), lambda match, q: service.shows.answer()),
        (re.compile(r"^/v1/library/duplicates$"), lambda match, q: service.duplicate_albums()),
        (re.compile(r"^/v1/lyrics/([^/]+)/words$"), lambda match, q: service.words(match[1])),
        (re.compile(r"^/v1/video/search$"),
         lambda match, q: {"items": service.videos.search(_text(q, "q"), _int(q, "limit", 12, 1, 30))}),
        (re.compile(r"^/v1/video/match$"),
         lambda match, q: service.videos.match(_text(q, "artist"), _text(q, "title"), _seconds(q, "duration"),
                                               _flag(q, "warm"))),
        (re.compile(r"^/v1/video/([A-Za-z0-9_-]{11})/streams$"),
         lambda match, q: service.videos.streams(match[1], _token_suffix(q), _int(q, "height", 0, 0, 4320) or None)),
        (re.compile(r"^/v1/history/links$"),
         lambda match, q: {"links": history_links(service.config.data_dir / "history-links.json")}),
        (re.compile(r"^/healthz$"), lambda match, q: {"ok": True}),
    ]

    class Handler(BaseHTTPRequestHandler):
        server_version = "sonic/1"

        def _allowed(self, url) -> bool:
            """The token as a header, or -- for the video streams, which a player fetches
            without our headers -- as `?token=` on the address."""
            token = service.config.token
            if not token or url.path == "/healthz" or self.headers.get("X-Sonic-Token") == token:
                return True
            return url.path.startswith("/v1/video/") and parse_qs(url.query).get("token", [""])[0] == token

        def do_GET(self):  # noqa: N802 — the standard library's name
            url = urlparse(self.path)
            if not self._allowed(url):
                return self._send(401, {"error": "token required"})
            query = parse_qs(url.query)
            path = unquote(url.path)
            raw = VIDEO_RAW.match(path)
            if raw:
                return self._video(raw, query)
            cover = re.match(r"^/v1/radar/([^/]+)/cover$", path)
            if cover:
                data = service.radar.cover(cover[1])
                if data is None:
                    return self._send(404, {"error": "no cover"})
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "max-age=604800")
                self.end_headers()
                self.wfile.write(data)
                return
            for pattern, answer in routes:
                match = pattern.match(path)
                if match:
                    try:
                        body = answer(match, query)
                    except Exception as error:  # noqa: BLE001
                        log.exception("request failed: %s", self.path)
                        return self._send(500, {"error": str(error)})
                    # Unknown or not yet analysed: 404, which the app reads as "fall back".
                    return self._send(404, {"error": "not analysed"}) if body is None else self._send(200, body)
            return self._send(404, {"error": "no such endpoint"})

        def _video(self, raw, query):
            """Playlists, thumbnails and the stream relay: not JSON."""
            video_id, name, itag, kind = raw[1], raw[2], raw[3], raw[4]
            suffix = _token_suffix(query)
            hls_playlist, hls_itag, hls_number, hls_ext = raw[5], raw[6], raw[7], raw[8]
            try:
                if name == "thumb":
                    data = service.videos.thumbnail(video_id)
                    if data is None:
                        return self._send(404, {"error": "no thumbnail"})
                    return self._bytes(200, data, "image/jpeg", "max-age=604800")
                if name == "master.m3u8":
                    text = service.videos.master(video_id, suffix, _int(query, "height", 0, 0, 4320) or None)
                elif hls_playlist:
                    text = service.videos.hls_playlist(video_id, hls_playlist, suffix)
                elif hls_itag:
                    return self._relay_hls(video_id, hls_itag, int(hls_number), hls_ext)
                elif kind == "m3u8":
                    text = service.videos.media(video_id, itag, suffix)
                else:
                    return self._relay(video_id, itag)
            except LookupError as error:
                return self._send(404, {"error": str(error)})
            except ValueError as error:
                return self._send(400, {"error": str(error)})
            except Exception as error:  # noqa: BLE001 — YouTube refusing, mostly
                log.exception("video request failed: %s", self.path)
                return self._send(502, {"error": str(error)})
            return self._bytes(200, text.encode(), "application/vnd.apple.mpegurl", "no-store")

        def _relay(self, video_id: str, itag: str):
            """YouTube's bytes for a byte range, passed straight through."""
            try:
                stream, upstream = service.videos.open_stream(video_id, itag, self.headers.get("Range"))
            except urllib.error.HTTPError as error:
                return self._send(error.code if error.code in (404, 416) else 502, {"error": f"YouTube said {error.code}"})
            with upstream:
                self.send_response(upstream.status)
                self.send_header("Content-Type",
                                 {"mp4": "video/mp4", "m4a": "audio/mp4", "webm": "audio/webm"}.get(stream.ext,
                                                                                                    "application/octet-stream"))
                for name in ("Content-Length", "Content-Range"):
                    if upstream.headers.get(name):
                        self.send_header(name, upstream.headers[name])
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                try:
                    while True:
                        chunk = upstream.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError, TimeoutError):
                    pass          # the player moved on, or seeked

        def _relay_hls(self, video_id: str, itag: str, number: int, ext: str):
            """One of YouTube's HLS segments, passed straight through."""
            try:
                upstream = service.videos.open_hls_segment(video_id, itag, number, self.headers.get("Range"))
            except urllib.error.HTTPError as error:
                return self._send(error.code if error.code in (404, 416) else 502, {"error": f"YouTube said {error.code}"})
            with upstream:
                self.send_response(upstream.status)
                self.send_header("Content-Type", {"ts": "video/mp2t", "aac": "audio/aac"}.get(ext, "video/mp4"))
                for header in ("Content-Length", "Content-Range", "Accept-Ranges"):
                    if upstream.headers.get(header):
                        self.send_header(header, upstream.headers[header])
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                try:
                    while True:
                        chunk = upstream.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError, TimeoutError):
                    pass          # the player moved on, or seeked

        def _bytes(self, status: int, data: bytes, content_type: str, cache: str):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", cache)
            self.end_headers()
            self.wfile.write(data)

        def _body(self, limit: int = 64 * 1024) -> dict:
            length = int(self.headers.get("Content-Length", "") or 0)
            if not 0 < length <= limit:
                raise ValueError(f"between 1 byte and {limit} bytes")
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError("a JSON object")
            return body

        def do_PUT(self):  # noqa: N802 — the standard library's name
            """`PUT /v1/video/match {"artist", "title", "video": {"id", "title", "channel", "duration"}}`:
            the video this song gets from now on, chosen by hand."""
            url = urlparse(self.path)
            if not self._allowed(url):
                return self._send(401, {"error": "token required"})
            if unquote(url.path) != "/v1/video/match":
                return self._send(404, {"error": "no such endpoint"})
            try:
                body = self._body()
                video = body.get("video")
                if not isinstance(video, dict):
                    raise ValueError("video must be an object")
                answer = service.videos.choose(str(body.get("artist") or ""), str(body.get("title") or ""), video)
            except ValueError as error:
                return self._send(400, {"error": str(error)})
            return self._send(200, answer)

        def do_DELETE(self):  # noqa: N802 — the standard library's name
            """`DELETE /v1/video/match?artist=&title=`: back to the automatic pick."""
            url = urlparse(self.path)
            if not self._allowed(url):
                return self._send(401, {"error": "token required"})
            if unquote(url.path) != "/v1/video/match":
                return self._send(404, {"error": "no such endpoint"})
            query = parse_qs(url.query)
            service.videos.reset(_text(query, "artist"), _text(query, "title"))
            return self._send(200, {"ok": True})

        def do_POST(self):  # noqa: N802 — the standard library's name
            if service.config.token and self.headers.get("X-Sonic-Token") != service.config.token:
                return self._send(401, {"error": "token required"})
            path = unquote(urlparse(self.path).path)
            if path == "/v1/taste":
                return self._taste()
            if path in ("/v1/lyrics/readings", "/v1/lyrics/translate"):
                return self._words(path)
            if path == "/v1/lyrics/save":
                return self._save_lyrics()
            if path == "/v1/lyrics/find":
                return self._find_lyrics()
            if path != "/v1/logs":
                return self._send(404, {"error": "no such endpoint"})
            try:
                length = int(self.headers.get("Content-Length", ""))
            except ValueError:
                return self._send(411, {"error": "length required"})
            if length <= 0:
                return self._send(400, {"error": "empty"})
            if length > LIMIT:
                # Read and dropped a piece at a time, never held: answering before the
                # body is read breaks the sender's pipe, and it never sees the 413. One
                # far too big is not worth reading, and only gets the connection closed.
                if length <= 8 * LIMIT:
                    while length > 0:
                        chunk = self.rfile.read(min(length, 65536))
                        if not chunk:
                            break
                        length -= len(chunk)
                return self._send(413, {"error": f"at most {LIMIT} bytes"})
            text = self.rfile.read(length).decode("utf-8", errors="replace")
            try:
                name = logs.save(text, self.headers.get("X-Log-Source"))
            except OSError as error:
                log.exception("could not keep the logs")
                return self._send(500, {"error": str(error)})
            log.info("logs received: %s, %d bytes", name, length)
            return self._send(201, {"name": name})

        def _taste(self):
            """A device's new plays and skips: `{"device": id, "events": [...]}`."""
            try:
                length = int(self.headers.get("Content-Length", ""))
            except ValueError:
                return self._send(411, {"error": "length required"})
            if not 0 < length <= 4 * 1024 * 1024:
                return self._send(413 if length > 0 else 400, {"error": "between 1 byte and 4 MB"})
            try:
                body = json.loads(self.rfile.read(length))
                result = service.taste.add(body.get("device"), body.get("events"))
            except (ValueError, AttributeError) as error:
                return self._send(400, {"error": str(error)})
            return self._send(200, result)

        def _words(self, path: str):
            """`{"lines": [...]}` (and `"language"` to translate): see `words`."""
            try:
                length = int(self.headers.get("Content-Length", ""))
            except ValueError:
                return self._send(411, {"error": "length required"})
            if not 0 < length <= 256 * 1024:
                return self._send(413 if length > 0 else 400, {"error": "between 1 byte and 256 KB"})
            try:
                body = json.loads(self.rfile.read(length))
                lines = body.get("lines")
                if not isinstance(lines, list) or not all(isinstance(line, str) for line in lines):
                    raise ValueError("lines must be a list of strings")
            except (ValueError, AttributeError) as error:
                return self._send(400, {"error": str(error)})
            try:
                if path == "/v1/lyrics/readings":
                    return self._send(200, service.readings.tokens(lines))
                status, answer = service.translations.answer(str(body.get("language") or ""), lines)
                return self._send(status, answer)
            except Exception as error:  # noqa: BLE001
                log.exception("request failed: %s", self.path)
                return self._send(500, {"error": str(error)})

        def _save_lyrics(self):
            """Lyrics fixed in the app, written into the song's file: see `lyricsfile`."""
            try:
                body = self._body(limit=1024 * 1024)
            except ValueError as error:
                return self._send(400, {"error": str(error)})
            try:
                return self._send(200, service.save_lyrics(body))
            except Refused as refused:
                return self._send(refused.status, {"error": refused.message})
            except Exception as error:  # noqa: BLE001
                log.exception("could not save lyrics")
                return self._send(500, {"error": f"Couldn't save the lyrics: {error}"})

        def _find_lyrics(self):
            """LRCLIB's lyrics for a song with none, beside it as a `.lrc`: see `lrclib`."""
            try:
                body = self._body()
            except ValueError as error:
                return self._send(400, {"error": str(error)})
            try:
                return self._send(200, service.find_lyrics(body))
            except Refused as refused:
                return self._send(refused.status, {"error": refused.message})
            except Exception as error:  # noqa: BLE001
                log.exception("could not find lyrics")
                return self._send(500, {"error": f"Couldn't find lyrics: {error}"})

        def _send(self, status: int, body: dict):
            try:
                data = json.dumps(body, separators=(",", ":"), allow_nan=False).encode()
            except ValueError:
                # NaN or an infinity somewhere. Python writes them as bare words, which
                # are not JSON, and the app cannot read a word of a reply that has one —
                # so it is a server error, said in JSON, and logged here where it is seen.
                log.error("answer for %s had a value that is not a number", self.path)
                status, data = 500, b'{"error":"a value was not a number"}'
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, format, *args):  # noqa: A002 — quiet; errors are logged above
            pass

    return Handler


def serve(service) -> None:
    server = ThreadingHTTPServer((service.config.host, service.config.port), make_handler(service))
    log.info("listening on %s:%d", service.config.host, service.config.port)
    server.serve_forever()
