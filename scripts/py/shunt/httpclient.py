"""Small stdlib HTTP client: GET and POST JSON with a timeout and a size cap.

It replaces the curl calls of the bash core, one call at a time. What the old
`curl -q -sS --max-time N --proto =http,https --max-filesize M` did is kept:

* total time is bounded by `timeout` (connect plus headers use it as a socket
  timeout, and the body read re-checks a deadline and shrinks the socket timeout
  to what is left),
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

import http.client
import json
import re
import socket
import ssl
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
    "tls": (35, "TLS handshake failed"),
    "empty_reply": (52, "the server closed the connection without an answer"),
    "recv": (56, "the connection broke while receiving the answer"),
    "tls_cert": (60, "the TLS certificate could not be verified"),
    "too_large": (63, "the answer is larger than the allowed size"),
}


class HttpError(Exception):
    """A transport level failure. An HTTP status other than 2xx is NOT an error here."""

    def __init__(self, kind: str):
        self.kind = kind
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


def _opener() -> urllib.request.OpenerDirector:
    return urllib.request.build_opener(_NoRedirect())


def _wire(value: str) -> str:
    """Make http.client send the UTF-8 bytes of `value` (it encodes str as latin-1)."""
    return value.encode("utf-8", "surrogateescape").decode("latin-1")


def _classify(exc: BaseException) -> str:
    if isinstance(exc, urllib.error.URLError) and not isinstance(exc, urllib.error.HTTPError):
        reason = exc.reason
        if isinstance(reason, BaseException):
            return _classify(reason)
        return "connect"
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


def _read_body(resp: Any, max_bytes: int, deadline: float | None) -> bytes:
    declared = resp.headers.get("Content-Length", "")
    if declared.isascii() and declared.isdigit() and int(declared) > max_bytes:
        raise HttpError("too_large")
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
            return b"".join(chunks)
        total += len(chunk)
        if total > max_bytes:
            raise HttpError("too_large")
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


def _perform(req: urllib.request.Request, timeout: float | None, max_bytes: int) -> Response | HttpError:
    """Do the exchange. Failures are RETURNED, so no exception is chained to a later raise."""
    deadline = None if timeout is None else time.monotonic() + timeout
    try:
        try:
            resp = _opener().open(req, timeout=timeout)
        except urllib.error.HTTPError as err:  # non-2xx: still an answer
            resp = err
        try:
            body = _read_body(resp, max_bytes, deadline)
            headers = {k.lower(): v for k, v in resp.headers.items()}
            return Response(resp.status if hasattr(resp, "status") else resp.code, headers, body)
        finally:
            resp.close()
    except HttpError as err:
        return err
    except Exception as exc:  # noqa: BLE001 - mapped to a category, the text is dropped
        return HttpError(_classify(exc))


def request(
    method: str,
    url: str,
    *,
    headers: Mapping[str, str] | None = None,
    body: bytes | None = None,
    timeout: float | None = None,
    max_bytes: int = DEFAULT_MAX_RESPONSE_BYTES,
) -> Response:
    """One request. `timeout` seconds in total (None: no limit, like curl --max-time 0)."""
    try:
        req = _build(method, url, headers or {}, body)
    except HttpError as err:
        raise err from None
    except Exception:  # noqa: BLE001 - e.g. a header value with a lone surrogate
        failure = HttpError("invalid")
    else:
        outcome = _perform(req, timeout, max_bytes)
        if isinstance(outcome, Response):
            return outcome
        failure = outcome
    raise failure


def get(url: str, *, headers: Mapping[str, str] | None = None, timeout: float | None = None,
        max_bytes: int = DEFAULT_MAX_RESPONSE_BYTES) -> Response:
    return request("GET", url, headers=headers, timeout=timeout, max_bytes=max_bytes)


def post_json(url: str, payload: Any, *, headers: Mapping[str, str] | None = None,
              timeout: float | None = None, max_bytes: int = DEFAULT_MAX_RESPONSE_BYTES) -> Response:
    merged = {"Content-Type": "application/json", **(headers or {})}
    data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return request("POST", url, headers=merged, body=data, timeout=timeout, max_bytes=max_bytes)
