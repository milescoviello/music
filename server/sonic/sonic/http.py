"""The HTTP side: small, read-only, JSON. Standard library only, so the service has
nothing to install beyond Essentia and NumPy."""

from __future__ import annotations

import json
import logging
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

from .config import TAGS

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

        def _send(self, status: int, body: dict):
            data = json.dumps(body, separators=(",", ":")).encode()
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
