"""Optional pre-flight healthcheck of a provider and its model, and its success cache.

A local server (LM Studio, ollama, llama.cpp on a laptop) may accept the TCP connection and still
never answer, for instance behind a Bonjour Sleep Proxy, or may have the model unloaded. With
`"healthcheck": true` on the provider the http transport runs two steps. First GET {base_url}/models:
a connection error, a timeout or a 5xx status is unhealthy, and a readable list without the model is
unhealthy. A 4xx or an unreadable list passes the step. Then a one token POST {base_url}/chat/completions
for the model: 2xx, 400 and 422 are healthy, 404, 5xx, a timeout or no connection are not.

Only successes are cached, per provider name, base_url and model id, in a small JSON file of the cache
dir. The cache holds names, urls and timestamps and never a key. An old entry without a model never
matches. A corrupt, foreign or unreadable cache is ignored, and a cache that cannot be written is
skipped. Neither is ever fatal.
"""

from __future__ import annotations

import json
import os
import stat
import tempfile
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from . import breaker, env, httpclient

MAX_BODY_BYTES = 4096  # the completion body is never used, so a long answer is cut early
MAX_CACHE_BYTES = 1 << 16
MAX_CACHE_ENTRIES = 64
CACHE_VERSION = 1
MAX_LIST_BYTES = 1 << 20  # a /models list of a big gateway is long
NO_ANSWER = "no answer in time"
MODEL_NO_ANSWER = "model gave no answer in time"
NOT_LISTED = "model not listed"
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


def _fresh(entries: list[dict[str, Any]], provider: str, base_url: str, model: str, now: int, ttl: float) -> bool:
    for entry in entries:
        if _same(entry, provider, base_url, model):
            return 0 <= now - entry["at"] < ttl
    return False


def _store(path: Path, entries: list[dict[str, Any]], provider: str, base_url: str, model: str, now: int) -> None:
    kept = [e for e in entries if not _same(e, provider, base_url, model)]
    kept = [e for e in kept if now - e["at"] >= 0][-(MAX_CACHE_ENTRIES - 1):]
    kept.append({"provider": provider, "base_url": base_url, "model": model, "at": now})
    doc = {"version": CACHE_VERSION,
           "entries": [{k: e[k] for k in ("provider", "base_url", "model", "at") if k in e} for e in kept]}
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    folder = os.stat(path.parent)
    if folder.st_uid != os.getuid() or folder.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
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


def _remember(path: Path, provider: str, base_url: str, model: str, now: int) -> None:
    try:
        _store(path, _load(path), provider, base_url, model, now)
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


def probe(url: str, headers: Mapping[str, str], timeout: float | None, connect_timeout: float,
          model: str | None = None) -> str | None:
    """Step 1: one GET of `url` (the /models list). None when healthy, else the reason (it never holds
    a header or a body). With a `model`, a parsable list that lacks it is unhealthy. A 4xx or a list
    that cannot be read says nothing about the model, so the step passes."""
    try:
        response = httpclient.get(url, headers=headers, timeout=timeout, max_bytes=MAX_LIST_BYTES,
                                  connect_timeout=connect_timeout)
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
        response = httpclient.post_json(url, PROBE_BODY | {"model": model}, headers=headers, timeout=timeout,
                                        max_bytes=MAX_BODY_BYTES, connect_timeout=connect_timeout)
        status = response.status
    except httpclient.HttpError as err:
        reason = _transport_reason(err, MODEL_NO_ANSWER, "model ")
        if reason is not None:
            return reason
        status = err.status or 0
    return f"model HTTP {status}" if status >= 500 or status == 404 else None


def check(provider: str, base_url: str, model: str, headers: Mapping[str, str], timeout: float | None,
          model_timeout: float | None, environ: Mapping[str, str]) -> str | None:
    """None when the provider and its `model` are healthy (asked now, or answered within the TTL), else
    the reason. `model_timeout` 0 skips the completion step. Raises env.EnvError for an invalid
    SHUNT_HEALTHCHECK_TTL or SHUNT_CONNECT_TIMEOUT."""
    ttl = env.healthcheck_ttl(environ)
    connect_timeout = env.connect_timeout(environ)
    base = base_url[:-1] if base_url.endswith("/") else base_url
    path = env.healthcheck_cache_file(environ)
    now = breaker.now(environ)
    if ttl > 0 and _fresh(_load(path), provider, base, model, now, ttl):
        return None
    reason = probe(base + "/models", headers, timeout, connect_timeout, model)
    if reason is None and model_timeout != 0:
        reason = probe_model(base + "/chat/completions", model, headers, model_timeout, connect_timeout)
    if reason is None and ttl > 0:
        _remember(path, provider, base, model, now)
    return reason
