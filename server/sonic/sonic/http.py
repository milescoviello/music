"""The HTTP side: small, JSON, and read-only apart from the logs the app sends for
fixing a bug and the plays and skips it shares between devices. Standard library only, so the service has nothing to install beyond
Essentia and NumPy."""

from __future__ import annotations

import json
import logging
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

from .config import TAGS
from .logs import LIMIT, LogBox

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


def make_handler(service):
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
        (re.compile(r"^/healthz$"), lambda match, q: {"ok": True}),
    ]

    class Handler(BaseHTTPRequestHandler):
        server_version = "sonic/1"

        def do_GET(self):  # noqa: N802 — the standard library's name
            url = urlparse(self.path)
            if service.config.token and self.headers.get("X-Sonic-Token") != service.config.token \
                    and url.path != "/healthz":
                return self._send(401, {"error": "token required"})
            query = parse_qs(url.query)
            path = unquote(url.path)
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

        def do_POST(self):  # noqa: N802 — the standard library's name
            if service.config.token and self.headers.get("X-Sonic-Token") != service.config.token:
                return self._send(401, {"error": "token required"})
            path = unquote(urlparse(self.path).path)
            if path == "/v1/taste":
                return self._taste()
            if path in ("/v1/lyrics/readings", "/v1/lyrics/translate"):
                return self._words(path)
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
