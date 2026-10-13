"""Optional healthcheck of a provider and its model, and its status cache.

A local server (LM Studio, ollama, llama.cpp on a laptop) may accept the TCP connection and still
never answer, for instance behind a Bonjour Sleep Proxy, or may have the model unloaded. With
`"healthcheck": true` on the provider a probe runs two steps. First GET {base_url}/models:
a connection error, a timeout or a 5xx status is unhealthy, and a readable list without the model is
unhealthy. A 4xx or an unreadable list passes the step. Then a one token POST {base_url}/chat/completions
for the model: 2xx, 400 and 422 are healthy, 404, 5xx, a timeout or no connection are not.
A request that could not make a connection is tried PROBE_CONNECT_RETRIES more times at once (a tunnel
such as Tailscale may need a few seconds to come up). There is no pause between tries, so it helps when
the connect times out, not when it is refused at once. No other failure is tried again.

The probe never runs on the path of a request (see healthcheck_bg.py). What the request path reads is
the status cache: per provider name, base_url and model id, {status: healthy|unhealthy, at}, in a small
JSON file of the cache dir. The cache holds names, urls and timestamps and never a key. An old entry
without a status counts as healthy. A corrupt, foreign or unreadable cache is ignored, and a cache that
cannot be written is skipped. Neither is ever fatal.
"""

from __future__ import annotations

import json
import os
import stat
import tempfile
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

from . import httpclient

MAX_BODY_BYTES = 4096  # the completion body is never used, so a long answer is cut early
MAX_CACHE_BYTES = 1 << 16
MAX_CACHE_ENTRIES = 64
CACHE_VERSION = 1
HEALTHY = "healthy"
UNHEALTHY = "unhealthy"
MAX_LIST_BYTES = 1 << 20  # a /models list of a big gateway is long
NO_ANSWER = "no answer in time"
MODEL_NO_ANSWER = "model gave no answer in time"
NOT_LISTED = "model not listed"
PROBE_CONNECT_RETRIES = 2  # extra tries of a probe request that could not connect (3 attempts in all)
CONNECT_KINDS = ("unreachable", "connect", "dns")  # no connection was made
PROBE_BODY = {"messages": [{"role": "user", "content": "ping"}], "max_tokens": 1, "stream": False}


def _own_regular(info: os.stat_result) -> bool:
    return stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()


def _load(path: Path) -> list[dict[str, Any]]:
    """The cached entries, or [] for anything but a clean file of ours."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    except OSError:
        return []
    try:
        if not _own_regular(os.fstat(fd)):
            return []
        with os.fdopen(fd, "rb", closefd=False) as handle:
            data = handle.read(MAX_CACHE_BYTES + 1)
        if len(data) > MAX_CACHE_BYTES:
            return []
        doc = json.loads(data.decode("utf-8"))
    except (OSError, ValueError, RecursionError):
        return []
    finally:
        os.close(fd)
    entries = doc.get("entries") if isinstance(doc, dict) else None
    if not isinstance(entries, list):
        return []
    return [e for e in entries if isinstance(e, dict) and isinstance(e.get("provider"), str)
            and isinstance(e.get("base_url"), str) and isinstance(e.get("at"), int)
            and not isinstance(e.get("at"), bool)]


def _same(entry: dict[str, Any], provider: str, base_url: str, model: str) -> bool:
    return entry["provider"] == provider and entry["base_url"] == base_url and entry.get("model") == model


def lookup(path: Path, provider: str, base_url: str, model: str, now: int) -> tuple[str, int] | None:
    """(status, age in seconds) of the cached entry, or None when there is none. A negative age
    (the clock went back) is reported as -1 and counts as stale."""
    for entry in _load(path):
        if _same(entry, provider, base_url, model):
            age = now - entry["at"]
            return (UNHEALTHY if entry.get("status") == UNHEALTHY else HEALTHY), (age if age >= 0 else -1)
    return None


def normalize_base(base_url: str) -> str:
    return base_url[:-1] if base_url.endswith("/") else base_url


def verdict(found: tuple[str, int] | None, ttl: float, retry: float) -> tuple[bool, bool]:
    """(fail over now, start a background probe) for a cached status. A fresh unhealthy status fails
    over at once. Everything else goes on with the real call, and a missing or stale status also
    starts a probe. An unhealthy status older than `retry` is not blocking: the call is the recheck."""
    if found is None:
        return False, True
    status, age = found
    if status == UNHEALTHY:
        fresh = 0 <= age < retry
        return fresh, not fresh
    return False, not 0 <= age < ttl


def trusted_folder(folder: Path) -> bool:
    """Make the folder if needed. False when others can write to it or it is not ours."""
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = os.stat(folder)
    return info.st_uid == os.getuid() and not info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)


def _store(path: Path, entries: list[dict[str, Any]], key: tuple[str, str, str], now: int, status: str) -> None:
    provider, base_url, model = key
    kept = [e for e in entries if not _same(e, provider, base_url, model)]
    kept = [e for e in kept if now - e["at"] >= 0][-(MAX_CACHE_ENTRIES - 1):]
    kept.append({"provider": provider, "base_url": base_url, "model": model, "status": status, "at": now})
    doc = {"version": CACHE_VERSION,
           "entries": [{k: e[k] for k in ("provider", "base_url", "model", "status", "at") if k in e} for e in kept]}
    if not trusted_folder(path.parent):
        return  # a folder others can write to is not trusted with the cache
    if path.is_symlink():
        return  # never write through or over a link someone planted
    fd, tmp = tempfile.mkstemp(prefix=".healthcheck-", dir=str(path.parent))  # mkstemp gives mode 0600
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(doc, handle, separators=(",", ":"))
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def remember(path: Path, provider: str, base_url: str, model: str, now: int, healthy: bool) -> None:
    """Store the status of a model with the time of the check. Never raises for a file problem."""
    try:
        _store(path, _load(path), (provider, normalize_base(base_url), model), now, HEALTHY if healthy else UNHEALTHY)
    except (OSError, ValueError):
        return


def _transport_reason(err: httpclient.HttpError, no_answer: str, prefix: str) -> str | None:
    """The reason of a transport failure, or None for a too large answer that still came with a status."""
    if err.kind == "too_large" and err.status is not None:
        return None
    return {"timeout": no_answer, "unreachable": "no connection in time"}.get(err.kind, f"{prefix}{err.kind} error")


def _listed(body: bytes) -> list[str] | None:
    """The model ids of an OpenAI style /models body, or None when the body is not such a list."""
    try:
        doc = json.loads(body.decode("utf-8"))
    except (ValueError, RecursionError):
        return None
    data = doc.get("data") if isinstance(doc, dict) else None
    if not isinstance(data, list) or not all(isinstance(m, dict) for m in data):
        return None
    return [m["id"] for m in data if isinstance(m.get("id"), str)]


def _retry_connect(send: Callable[[], httpclient.Response]) -> httpclient.Response:
    """`send()`, tried again at once when no connection could be made (a tunnel that needs a few seconds
    to come up). Any other failure, and the last connect failure, is raised."""
    for _ in range(PROBE_CONNECT_RETRIES):
        try:
            return send()
        except httpclient.HttpError as err:
            if err.kind not in CONNECT_KINDS:
                raise
    return send()


def probe(url: str, headers: Mapping[str, str], timeout: float | None, connect_timeout: float,
          model: str | None = None) -> str | None:
    """Step 1: one GET of `url` (the /models list). None when healthy, else the reason (it never holds
    a header or a body). With a `model`, a parsable list that lacks it is unhealthy. A 4xx or a list
    that cannot be read says nothing about the model, so the step passes."""
    try:
        response = _retry_connect(lambda: httpclient.get(
            url, headers=headers, timeout=timeout, max_bytes=MAX_LIST_BYTES, connect_timeout=connect_timeout))
    except httpclient.HttpError as err:
        reason = _transport_reason(err, NO_ANSWER, "")
        if reason is not None:
            return reason
        status, body = err.status or 0, b""
    else:
        status, body = response.status, response.body
    if status >= 500:
        return f"HTTP {status}"
    if status == 200 and model is not None:
        ids = _listed(body)
        if ids is not None and model not in ids:
            return NOT_LISTED
    return None


def probe_model(url: str, model: str, headers: Mapping[str, str], timeout: float | None,
                connect_timeout: float) -> str | None:
    """Step 2: one tiny completion for `model`. None when the model route answered, else the reason.
    2xx, 400 and 422 (e.g. a reasoning model that rejects max_tokens) and other 4xx but 404 are healthy,
    a 401 or 403 is left to the real call to report."""
    try:
        response = _retry_connect(lambda: httpclient.post_json(
            url, PROBE_BODY | {"model": model}, headers=headers, timeout=timeout, max_bytes=MAX_BODY_BYTES,
            connect_timeout=connect_timeout))
        status = response.status
    except httpclient.HttpError as err:
        reason = _transport_reason(err, MODEL_NO_ANSWER, "model ")
        if reason is not None:
            return reason
        status = err.status or 0
    return f"model HTTP {status}" if status >= 500 or status == 404 else None


def run_probes(base_url: str, model: str, headers: Mapping[str, str], timeout: float | None,
               model_timeout: float | None, connect_timeout: float) -> str | None:
    """None when the provider and its `model` answer, else the reason. `model_timeout` 0 skips the
    completion step."""
    base = normalize_base(base_url)
    reason = probe(base + "/models", headers, timeout, connect_timeout, model)
    if reason is None and model_timeout != 0:
        reason = probe_model(base + "/chat/completions", model, headers, model_timeout, connect_timeout)
    return reason
