"""Optional pre-flight healthcheck of a provider (GET {base_url}/models) and its success cache.

A local server (LM Studio, ollama, llama.cpp on a laptop) may accept the TCP connection and still
never answer, for instance behind a Bonjour Sleep Proxy. With `"healthcheck": true` on the provider
the http transport asks `/models` first. Any HTTP answer below 500 is healthy (a 404 or 401 still
proves a server is there). A connection error, a timeout or a 5xx status is not.

Only successes are cached, per provider name and base_url, in a small JSON file of the cache dir.
The cache holds names, urls and timestamps and never a key. A corrupt, foreign or unreadable
cache is ignored, and a cache that cannot be written is skipped. Neither is ever fatal.
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

MAX_BODY_BYTES = 4096  # the body is never used, so a long answer is cut early
MAX_CACHE_BYTES = 1 << 16
MAX_CACHE_ENTRIES = 64
CACHE_VERSION = 1
NO_ANSWER = "no answer in time"


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


def _fresh(entries: list[dict[str, Any]], provider: str, base_url: str, now: int, ttl: float) -> bool:
    for entry in entries:
        if entry["provider"] == provider and entry["base_url"] == base_url:
            return 0 <= now - entry["at"] < ttl
    return False


def _store(path: Path, entries: list[dict[str, Any]], provider: str, base_url: str, now: int) -> None:
    kept = [e for e in entries if not (e["provider"] == provider and e["base_url"] == base_url)]
    kept = [e for e in kept if now - e["at"] >= 0][-(MAX_CACHE_ENTRIES - 1):]
    kept.append({"provider": provider, "base_url": base_url, "at": now})
    doc = {"version": CACHE_VERSION, "entries": [{k: e[k] for k in ("provider", "base_url", "at")} for e in kept]}
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


def _remember(path: Path, provider: str, base_url: str, now: int) -> None:
    try:
        _store(path, _load(path), provider, base_url, now)
    except (OSError, ValueError):
        return


def probe(url: str, headers: Mapping[str, str], timeout: float | None, connect_timeout: float) -> str | None:
    """One GET of `url`. None when healthy, else the reason (it never holds a header or a body)."""
    try:
        response = httpclient.get(url, headers=headers, timeout=timeout, max_bytes=MAX_BODY_BYTES,
                                  connect_timeout=connect_timeout)
        status = response.status
    except httpclient.HttpError as err:
        if err.kind != "too_large" or err.status is None:  # a too large body still came with a status
            return {"timeout": NO_ANSWER, "unreachable": "no connection in time"}.get(
                err.kind, f"{err.kind} error")
        status = err.status
    return f"HTTP {status}" if status >= 500 else None


def check(provider: str, base_url: str, headers: Mapping[str, str], timeout: float | None,
          environ: Mapping[str, str]) -> str | None:
    """None when the provider is healthy (asked now, or answered within the TTL), else the reason.
    Raises env.EnvError for an invalid SHUNT_HEALTHCHECK_TTL or SHUNT_CONNECT_TIMEOUT."""
    ttl = env.healthcheck_ttl(environ)
    connect_timeout = env.connect_timeout(environ)
    base = base_url[:-1] if base_url.endswith("/") else base_url
    path = env.healthcheck_cache_file(environ)
    now = breaker.now(environ)
    if ttl > 0 and _fresh(_load(path), provider, base, now, ttl):
        return None
    reason = probe(base + "/models", headers, timeout, connect_timeout)
    if reason is None and ttl > 0:
        _remember(path, provider, base, now)
    return reason
