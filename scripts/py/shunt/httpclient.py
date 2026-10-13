"""Small stdlib HTTP client: GET and POST JSON with a timeout and a size cap.

It replaces the curl calls of the bash core, one call at a time. What the old
`curl -q -sS --max-time N --proto =http,https --max-filesize M` did is kept:

* total time is bounded by `timeout` (connect plus headers use it as a socket
  timeout, and the body read re-checks a deadline and shrinks the socket timeout
  to what is left),
* the connect (TCP, plus the TLS handshake) may be given a shorter `connect_timeout`.
  When it runs out the failure is "unreachable", not "timeout", so a host that never
  answers (a sleeping laptop) is told apart from a model that is merely slow. It
  applies only when it is shorter than the total `timeout`. DNS resolution is bounded
  by the total timeout only,
* only http:// and https:// are spoken,
* redirects are NOT followed (curl without -L reports the 3xx as the status),
* a body larger than `max_bytes` is refused (curl exit 63), checked against
  Content-Length first and then while reading,
* no ~/.netrc and no ~/.curlrc,
* proxies: curl honours `http_proxy`, `https_proxy`, `ALL_PROXY` and `no_proxy`
  implicitly. urllib honours `http_proxy`, `https_proxy` and `no_proxy` (and their
  upper-case spellings) the same way, so the behavior is kept on purpose.
  `ALL_PROXY` is the one difference.

Secrets: header values come from the caller and may carry a key. Nothing here
puts a header value into an exception or a message. Errors carry a fixed text per
category plus the curl exit code that the bash path would have seen, so the
transport can map them to the same results later.
"""

from __future__ import annotations

import errno
import http.client
import json
import re
import socket
import ssl
import threading
import time
import urllib.error
import urllib.request
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit

DEFAULT_MAX_RESPONSE_BYTES = 16777216  # SHUNT_HTTP_MAX_RESPONSE_BYTES_DEFAULT
_MAX_BYTES_RE = re.compile(r"[1-9][0-9]{0,14}")
_CHUNK = 65536
_MAX_JOIN = threading.TIMEOUT_MAX  # join() overflows on absurd values
_ALLOWED_SCHEMES = ("http", "https")
_USER_AGENT = "agent-model-shunt"

# kind -> (curl exit status, fixed message). No exception text is ever appended:
# it could echo a URL part or a header value.
ERROR_KINDS: dict[str, tuple[int, str]] = {
    "scheme": (1, "unsupported protocol (only http and https)"),
    "invalid": (3, "the request could not be built (malformed URL or header)"),
    "dns": (6, "could not resolve the host"),
    "connect": (7, "could not connect to the host"),
    "timeout": (28, "the request timed out"),
    "unreachable": (28, "no connection within the connect timeout"),
    "tls": (35, "TLS handshake failed"),
    "empty_reply": (52, "the server closed the connection without an answer"),
    "recv": (56, "the connection broke while receiving the answer"),
    "tls_cert": (60, "the TLS certificate could not be verified"),
    "too_large": (63, "the answer is larger than the allowed size"),
}


class HttpError(Exception):
    """A transport level failure. An HTTP status other than 2xx is NOT an error here."""

    def __init__(self, kind: str, status: int | None = None):
        self.kind = kind
        self.status = status  # the HTTP status already seen, e.g. of a too large answer
        self.curl_exit, message = ERROR_KINDS[kind]
        super().__init__(message)


@dataclass(frozen=True)
class Response:
    status: int
    headers: Mapping[str, str]  # response headers, lower-cased names
    body: bytes

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300


def max_response_bytes(environ: Mapping[str, str]) -> int:
    """SHUNT_HTTP_MAX_RESPONSE_BYTES when it is a positive integer, else the default."""
    raw = environ.get("SHUNT_HTTP_MAX_RESPONSE_BYTES", "")
    return int(raw) if _MAX_BYTES_RE.fullmatch(raw) else DEFAULT_MAX_RESPONSE_BYTES


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None  # the 3xx answer is reported as it is, like curl without -L


_UNREACHABLE_ERRNOS = frozenset(
    {errno.ENETUNREACH, errno.EHOSTUNREACH, errno.EHOSTDOWN, errno.ENETDOWN})


class _ConnectTimeout(OSError):
    """The connect failed as unreachable: no finish within the connect timeout, or no route."""


class _Tracker:
    """Remembers the connections of one request so the caller can abort them."""

    def __init__(self, connect_timeout: float | None = None) -> None:
        self.connect_timeout = connect_timeout  # None: the total timeout governs the connect too
        self.cancelled = False
        self.conns: list[Any] = []

    def wrap(self, cls: Any) -> Any:
        tracker = self

        class _Conn(cls):  # type: ignore[misc, valid-type]
            def connect(self) -> None:
                overall = self.timeout
                limit = tracker.connect_timeout
                if limit is not None:
                    self.timeout = limit  # create_connection and the TLS handshake both use it
                try:
                    super().connect()
                except TimeoutError:
                    if limit is None:
                        raise
                    self.close()
                    raise _ConnectTimeout("connect timed out") from None
                except OSError as exc:
                    if exc.errno in _UNREACHABLE_ERRNOS:  # no route, only counted while connecting
                        raise _ConnectTimeout("no route to the host") from None
                    raise
                finally:
                    self.timeout = overall
                if limit is not None:
                    self.sock.settimeout(overall)
                if tracker.cancelled:
                    self.close()
                    raise OSError("cancelled")

        def factory(*args: Any, **kwargs: Any) -> Any:
            conn = _Conn(*args, **kwargs)
            tracker.conns.append(conn)
            return conn

        return factory

    def abort(self) -> None:
        self.cancelled = True
        for conn in list(self.conns):
            sock = getattr(conn, "sock", None)
            try:
                if sock is not None:
                    sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                conn.close()
            except Exception:  # noqa: BLE001 - best effort
                pass


def _opener(tracker: _Tracker | None = None) -> urllib.request.OpenerDirector:
    tracker = tracker or _Tracker()

    class _Http(urllib.request.HTTPHandler):
        def http_open(self, req: Any) -> Any:
            return self.do_open(tracker.wrap(http.client.HTTPConnection), req)

    class _Https(urllib.request.HTTPSHandler):
        def https_open(self, req: Any) -> Any:
            return self.do_open(tracker.wrap(http.client.HTTPSConnection), req, context=self._context)

    return urllib.request.build_opener(_NoRedirect(), _Http(), _Https())


def _wire(value: str) -> str:
    """Make http.client send the UTF-8 bytes of `value` (it encodes str as latin-1)."""
    return value.encode("utf-8", "surrogateescape").decode("latin-1")


def _classify(exc: BaseException) -> str:
    if isinstance(exc, urllib.error.URLError) and not isinstance(exc, urllib.error.HTTPError):
        reason = exc.reason
        if isinstance(reason, BaseException):
            return _classify(reason)
        return "connect"
    if isinstance(exc, _ConnectTimeout):
        return "unreachable"
    if isinstance(exc, TimeoutError):  # socket.timeout is an alias since 3.10
        return "timeout"
    if isinstance(exc, socket.gaierror):
        return "dns"
    if isinstance(exc, ssl.SSLCertVerificationError):
        return "tls_cert"
    if isinstance(exc, ssl.SSLError):
        return "tls"
    if isinstance(exc, http.client.InvalidURL):
        return "invalid"
    if isinstance(exc, http.client.RemoteDisconnected):
        return "empty_reply"
    if isinstance(exc, (http.client.HTTPException, ConnectionResetError, BrokenPipeError)):
        return "recv"
    if isinstance(exc, ValueError):
        return "invalid"
    if isinstance(exc, OSError):
        return "connect"  # refused, unreachable, tunnel failed
    return "recv"


def _socket_of(resp: Any) -> Any:
    fp = getattr(resp, "fp", None)
    for _ in range(3):  # HTTPError wraps the HTTPResponse, whose fp wraps a SocketIO
        sock = getattr(getattr(fp, "raw", None), "_sock", None)
        if sock is not None:
            return sock
        fp = getattr(fp, "fp", None)
    return None


def _limit_socket(sock: Any, seconds: float) -> None:
    """Best effort: one stalled read may not outlive the total deadline."""
    if sock is None:
        return
    try:
        sock.settimeout(seconds)
    except (OSError, OverflowError):  # already closed after the last byte, or an absurd timeout
        pass


def _read_body(resp: Any, max_bytes: int, deadline: float | None, expect_body: bool = True) -> bytes:
    declared = resp.headers.get("Content-Length", "")
    status = getattr(resp, "status", None) or getattr(resp, "code", None)
    if declared.isascii() and declared.isdigit() and int(declared) > max_bytes:
        raise HttpError("too_large", status)
    sock = _socket_of(resp)
    read = getattr(resp, "read1", None) or resp.read
    chunks: list[bytes] = []
    total = 0
    while True:
        if deadline is not None:
            left = deadline - time.monotonic()
            if left <= 0:
                raise HttpError("timeout")
            _limit_socket(sock, left)
        chunk = read(min(_CHUNK, max_bytes + 1 - total))
        if not chunk:
            # curl exit 18 (partial file): fewer bytes than a Content-Length without Transfer-Encoding.
            if (expect_body and declared.isascii() and declared.isdigit() and total < int(declared)
                    and not resp.headers.get("Transfer-Encoding")):
                raise HttpError("recv")
            return b"".join(chunks)
        total += len(chunk)
        if total > max_bytes:
            raise HttpError("too_large", status)
        chunks.append(chunk)


def _build(method: str, url: str, headers: Mapping[str, str], data: bytes | None) -> urllib.request.Request:
    if urlsplit(url).scheme.lower() not in _ALLOWED_SCHEMES:
        raise HttpError("scheme")
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "*/*")
    req.add_header("User-Agent", _USER_AGENT)
    for name, value in headers.items():
        req.add_header(name, _wire(value))
    return req


def _exchange(req: urllib.request.Request, timeout: float | None, max_bytes: int,
              deadline: float | None, tracker: _Tracker) -> Response | HttpError:
    try:
        try:
            resp = _opener(tracker).open(req, timeout=timeout if timeout else None)
        except urllib.error.HTTPError as err:  # non-2xx: still an answer
            resp = err
        try:
            has_body = req.get_method() != "HEAD" and resp.status not in (204, 304) if hasattr(resp, "status") else True
            body = _read_body(resp, max_bytes, deadline, has_body)
            headers = {k.lower(): v for k, v in resp.headers.items()}
            return Response(resp.status if hasattr(resp, "status") else resp.code, headers, body)
        finally:
            resp.close()
    except HttpError as err:
        return err
    except Exception as exc:  # noqa: BLE001 - mapped to a category, the text is dropped
        return HttpError("timeout" if tracker.cancelled else _classify(exc))


def _perform(req: urllib.request.Request, timeout: float | None, max_bytes: int,
             connect_timeout: float | None = None) -> Response | HttpError:
    """Do the exchange under ONE hard deadline (DNS, connect, TLS, headers, body).

    The exchange runs in a daemon worker thread and the caller waits for it with
    join(remaining). On expiry the connections are shut down and the result is
    "timeout" (curl exit 28). Failures are RETURNED, so no exception is chained.
    A timeout of None or 0 means no limit.
    """
    limit = timeout if timeout and timeout > 0 else None
    deadline = None if limit is None else time.monotonic() + limit
    own_connect = connect_timeout if connect_timeout and connect_timeout > 0 else None
    if own_connect is not None and limit is not None and own_connect >= limit:
        own_connect = None  # the total timeout is not longer: a stuck connect is a plain "timeout"
    tracker = _Tracker(own_connect)
    box: list[Response | HttpError] = []
    worker = threading.Thread(
        target=lambda: box.append(_exchange(req, limit, max_bytes, deadline, tracker)), daemon=True)
    worker.start()
    try:
        worker.join(None if limit is None else min(limit, _MAX_JOIN))
    except BaseException:
        tracker.abort()
        raise
    if box:
        return box[0]
    tracker.abort()
    return HttpError("timeout")


def request(
    method: str,
    url: str,
    *,
    headers: Mapping[str, str] | None = None,
    body: bytes | None = None,
    timeout: float | None = None,
    max_bytes: int = DEFAULT_MAX_RESPONSE_BYTES,
    connect_timeout: float | None = None,
) -> Response:
    """One request. `timeout` seconds in total (None: no limit, like curl --max-time 0).
    `connect_timeout` bounds the connect on its own (None or 0: only `timeout` applies)."""
    try:
        req = _build(method, url, headers or {}, body)
    except HttpError as err:
        raise err from None
    except Exception:  # noqa: BLE001 - e.g. a header value with a lone surrogate
        failure = HttpError("invalid")
    else:
        outcome = _perform(req, timeout, max_bytes, connect_timeout)
        if isinstance(outcome, Response):
            return outcome
        failure = outcome
    raise failure


def get(url: str, *, headers: Mapping[str, str] | None = None, timeout: float | None = None,
        max_bytes: int = DEFAULT_MAX_RESPONSE_BYTES, connect_timeout: float | None = None) -> Response:
    return request("GET", url, headers=headers, timeout=timeout, max_bytes=max_bytes,
                   connect_timeout=connect_timeout)


def post_json(url: str, payload: Any, *, headers: Mapping[str, str] | None = None,
              timeout: float | None = None, max_bytes: int = DEFAULT_MAX_RESPONSE_BYTES,
              connect_timeout: float | None = None) -> Response:
    merged = {"Content-Type": "application/json", **(headers or {})}
    data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return request("POST", url, headers=merged, body=data, timeout=timeout, max_bytes=max_bytes,
                   connect_timeout=connect_timeout)
