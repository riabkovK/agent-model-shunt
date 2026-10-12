"""A scripted local HTTP server for tests (stdlib only), replacing the fake curl.

Two ways to use it:

* In pytest: the `http_server` fixture (test/py/conftest.py) gives a started
  `ScriptedServer`. `server.script(path, status=..., body=..., delay=..., drop=...)`
  adds a route, `server.requests` records every request (method, path, lower-cased
  headers, body) so tests can assert on what was sent.
* From bats: `python3 httpserver.py --routes DIR --port-file FILE --log FILE`
  serves files from DIR (re-read on every request, so a test may add or remove
  routes while it runs). A request to /v1/models/m1 reads DIR/v1_models_m1, the
  optional DIR/v1_models_m1.code holds the status (default 200), .delay the seconds
  to wait before answering, .drop (present) closes the connection without any answer,
  .chunked (present) sends the body without a Content-Length. No file means 404.
  The port is written to FILE once the server listens, and each request is
  appended to the log as one JSON line.

The server binds 127.0.0.1 on a free port, answers on HTTP/1.1 and closes every
connection after the answer.
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable


@dataclass
class Route:
    status: int = 200
    body: bytes = b""
    headers: dict[str, str] = field(default_factory=dict)
    delay: float = 0.0  # seconds to wait before answering
    drop: bool = False  # close the connection without any answer
    chunked: bool = False  # no Content-Length, Transfer-Encoding: chunked
    drip: float = 0.0  # seconds between single body bytes (a slow body)


@dataclass
class Recorded:
    method: str
    path: str
    headers: dict[str, str]
    body: bytes

    def as_json(self) -> str:
        return json.dumps({"method": self.method, "path": self.path, "headers": self.headers,
                           "body": self.body.decode("utf-8", "replace")})


Resolver = Callable[[str, str], "Route | None"]


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args) -> None:  # keep test output quiet
        pass

    def _serve(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        headers = {k.lower(): v for k, v in self.headers.items()}
        self.server.record(Recorded(self.command, self.path, headers, body))  # type: ignore[attr-defined]
        route = self.server.resolve(self.command, self.path)  # type: ignore[attr-defined]
        self.close_connection = True
        try:
            if route is None:
                route = Route(status=404)
            if route.delay and self.server.stop_event.wait(route.delay):  # type: ignore[attr-defined]
                return
            if route.drop:
                return
            self._answer(route)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _answer(self, route: Route) -> None:
        self.send_response(route.status)
        for name, value in route.headers.items():
            self.send_header(name, value)
        self.send_header("Connection", "close")
        if route.chunked:
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", str(len(route.body)))
        self.end_headers()
        if route.drip:
            for i in range(len(route.body)):
                self.wfile.write(route.body[i:i + 1])
                self.wfile.flush()
                if self.server.stop_event.wait(route.drip):  # type: ignore[attr-defined]
                    return
        elif route.chunked:
            if route.body:
                self.wfile.write(b"%x\r\n%s\r\n" % (len(route.body), route.body))
            self.wfile.write(b"0\r\n\r\n")
        else:
            self.wfile.write(route.body)

    do_GET = do_POST = do_PUT = do_DELETE = _serve


class _Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, resolver: Resolver, on_request: Callable[[Recorded], None]):
        super().__init__(("127.0.0.1", 0), _Handler)
        self.resolve = resolver
        self.record = on_request
        self.stop_event = threading.Event()

    def handle_error(self, request, client_address) -> None:  # aborted clients are part of the tests
        pass


class ScriptedServer:
    """Serves scripted routes and records the requests."""

    def __init__(self) -> None:
        self._routes: dict[tuple[str | None, str], Route] = {}
        self._lock = threading.Lock()
        self.requests: list[Recorded] = []
        self._server = _Server(self._resolve, self._record)
        self._thread = threading.Thread(target=self._server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)

    @property
    def port(self) -> int:
        return self._server.server_address[1]

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def script(self, path: str, *, method: str | None = None, status: int = 200,
               body: bytes | str | dict | list = b"", headers: dict[str, str] | None = None,
               delay: float = 0.0, drop: bool = False, chunked: bool = False, drip: float = 0.0) -> None:
        """Answer `path` (any method unless given). A dict or list body is sent as JSON."""
        if isinstance(body, (dict, list)):
            body = json.dumps(body)
        if isinstance(body, str):
            body = body.encode("utf-8")
        route = Route(status, body, dict(headers or {}), delay, drop, chunked, drip)
        with self._lock:
            self._routes[(method, path)] = route

    def _resolve(self, method: str, path: str) -> Route | None:
        with self._lock:
            return self._routes.get((method, path)) or self._routes.get((None, path))

    def _record(self, item: Recorded) -> None:
        with self._lock:
            self.requests.append(item)

    def start(self) -> "ScriptedServer":
        self._thread.start()
        return self

    def stop(self) -> None:
        self._server.stop_event.set()
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=5)


class _FileRoutes:
    """The bats mode: routes are files in a directory, read on every request."""

    def __init__(self, directory: Path):
        self.directory = directory

    def resolve(self, _method: str, path: str) -> Route | None:
        name = path.split("?", 1)[0].lstrip("/").replace("/", "_")
        base = self.directory / name
        if not name or not base.is_file():
            return None
        return Route(status=int(_text(base, ".code") or 200), body=base.read_bytes(),
                     delay=float(_text(base, ".delay") or 0),
                     drop=_marker(base, ".drop"), chunked=_marker(base, ".chunked"))


def _marker(base: Path, suffix: str) -> bool:
    return base.with_name(base.name + suffix).exists()


def _text(base: Path, suffix: str) -> str:
    other = base.with_name(base.name + suffix)
    return other.read_text().strip() if other.is_file() else ""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--routes", required=True, type=Path)
    parser.add_argument("--port-file", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    args = parser.parse_args(argv)
    log_lock = threading.Lock()

    def on_request(item: Recorded) -> None:
        with log_lock, args.log.open("a") as handle:
            handle.write(item.as_json() + "\n")

    server = _Server(_FileRoutes(args.routes).resolve, on_request)
    tmp = args.port_file.with_name(args.port_file.name + ".tmp")
    tmp.write_text(str(server.server_address[1]))
    tmp.replace(args.port_file)  # the port file appears only once the socket listens
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.stop_event.set()
    return 0


if __name__ == "__main__":
    sys.exit(main())
