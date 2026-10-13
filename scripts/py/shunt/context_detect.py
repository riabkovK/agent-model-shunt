"""Context window auto-detection for models of an HTTP-transport provider.

Port of the former scripts/lib/context-detect.sh (removed). Only what the provider itself reports is
used, a number is never guessed from built-in knowledge. Sources, in order:

1. GET <base_url>/models/<model>
2. GET <base_url>/models, the entry whose id is <model>
3. Ollama: POST <base_url without /v1>/api/show. The runtime window is `num_ctx`
   in the `parameters` text, preferred because it is what the server really
   allows. A model_info key ending in .context_length is only the architecture
   maximum, used when num_ctx is not set.

Every failure (network, non-2xx, bad JSON) just means "not found", except a 401
or 403 answer: that is reported apart (exit status 3), because the fix is a new
key, not a hand-typed number. The key lives only in the memory of this process.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from collections.abc import Mapping
from typing import Any

from . import env, httpclient, probe, providers

EXIT_NOT_FOUND = 1
EXIT_AUTH_FAILED = 3
DEFAULT_TIMEOUT_SECONDS = "15"
# Fields of a /models entry that carry the context window, first present wins.
FIELDS = ("context_length", "max_model_len", "context_window", "max_context_length", "max_input_tokens")
# Model names outside this alphabet are not put into a URL.
_MODEL_RE = re.compile(r"[A-Za-z0-9._:@+/-]+")
_TIMEOUT_RE = re.compile(r"[0-9]+(?:\.[0-9]+)?")
_NUM_CTX_RE = re.compile(r"(?:^|\n)num_ctx[ \t]+([0-9]+)")
# bash [ -ge ] flags: 1 = a 403 (may be a gateway route miss, the remaining probes
# still run), 2 = a 401 (the key is rejected, nothing more is tried).
_AUTH_NONE, _AUTH_403, _AUTH_401 = 0, 1, 2


def _positive_int(value: Any) -> int | None:
    """The value when it is a positive whole JSON number (not a bool), else None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value > 0 else None
    if isinstance(value, float) and value > 0 and value.is_integer():
        return int(value)
    return None


def _from_fields(doc: Any) -> int | None:
    if not isinstance(doc, dict):
        return None
    for name in FIELDS:
        found = _positive_int(doc.get(name))
        if found is not None:
            return found
    return None


def _jq_alt(value: Any) -> bool:
    """jq `//` takes a value only when it is neither null nor false."""
    return value is not None and value is not False


def _list_entry(doc: Any, model: str) -> Any:
    """First object of `(.data // .models // .)[]?` whose id is the model."""
    container = doc
    if isinstance(doc, dict):
        container = next((doc[k] for k in ("data", "models") if _jq_alt(doc.get(k))), doc)
    if isinstance(container, dict):
        items = list(container.values())
    elif isinstance(container, list):
        items = container
    else:
        return None
    return next((i for i in items if isinstance(i, dict) and i.get("id") == model), None)


def _from_show(doc: Any) -> int | None:
    if not isinstance(doc, dict):
        return None
    params = doc.get("parameters")
    if isinstance(params, str):
        for match in _NUM_CTX_RE.finditer(params):
            found = _positive_int(_digits(match.group(1)))
            if found is not None:
                return found
    info = doc.get("model_info")
    if isinstance(info, dict):
        for key, value in info.items():
            if key.endswith(".context_length"):
                found = _positive_int(value)
                if found is not None:
                    return found
    return None


def _digits(text: str) -> int:
    try:
        return int(text)
    except ValueError:  # beyond the int digit limit: not a usable number
        return 0


def _parse(body: bytes) -> Any:
    try:
        return json.loads(body)
    except (ValueError, RecursionError):
        return None


class _Detector:
    def __init__(self, environ: Mapping[str, str], base: str, headers: Mapping[str, str]):
        self.base = base
        self.headers = headers
        self.timeout = _timeout(environ)
        self.max_bytes = httpclient.max_response_bytes(environ)
        self.auth_seen = _AUTH_NONE

    def _fetch(self, url: str, payload: Any = None) -> Any:
        """The parsed JSON of a 2xx answer, else None. Notes 401/403 and oversize answers."""
        try:
            if payload is None:
                resp = httpclient.get(url, headers=self.headers, timeout=self.timeout, max_bytes=self.max_bytes)
            else:
                resp = httpclient.post_json(url, payload, headers=self.headers,
                                            timeout=self.timeout, max_bytes=self.max_bytes)
        except httpclient.HttpError as err:
            if err.kind == "too_large":
                sys.stderr.write(f"shunt: a context lookup answer was larger than {self.max_bytes} bytes, ignored.\n")
            return None
        if resp.ok:
            return _parse(resp.body)
        if resp.status == 401:
            self.auth_seen = _AUTH_401
        elif resp.status == 403:
            self.auth_seen = max(self.auth_seen, _AUTH_403)
        return None

    def run(self, model: str) -> int | None:
        found = _from_fields(self._fetch(f"{self.base}/models/{model}"))
        if found is not None or self.auth_seen == _AUTH_401:
            return found
        found = _from_fields(_list_entry(self._fetch(f"{self.base}/models"), model))
        if found is not None or self.auth_seen == _AUTH_401:
            return found
        api_base = self.base[:-3] if self.base.endswith("/v1") else self.base
        return _from_show(self._fetch(f"{api_base}/api/show", {"model": model}))


def _timeout(environ: Mapping[str, str]) -> float | None:
    """SHUNT_DETECT_TIMEOUT_SECONDS as curl --max-time reads it (0 means no limit)."""
    raw = environ.get("SHUNT_DETECT_TIMEOUT_SECONDS") or DEFAULT_TIMEOUT_SECONDS
    if not _TIMEOUT_RE.fullmatch(raw):
        raise ValueError(raw)
    seconds = float(raw)  # ValueError for garbage: the caller treats it as "not found"
    if not math.isfinite(seconds) or seconds > 1e6:
        raise ValueError(raw)
    return seconds or None


def _usable_model(model: str) -> bool:
    if not _MODEL_RE.fullmatch(model):
        return False
    # No dot segments or empty path parts: they would be normalized into another path.
    return not any(part in ("", ".", "..") for part in model.split("/"))


def _checked_base(provider: str, url: str) -> str | None:
    """The base URL to use (https:// assumed when there is no scheme), None after a message."""
    code = providers.base_url_check(url)
    if code == 3:
        url = "https://" + url
    elif code == 2:
        sys.stderr.write(f"shunt: provider '{provider}': base_url scheme must be http:// or https:// "
                         "(config problem, no request sent).\n")
        return None
    elif code != 0:
        sys.stderr.write(f"shunt: provider '{provider}': base_url is malformed or has credentials in it "
                         "(config problem, no request sent).\n")
        return None
    return url[:-1] if url.endswith("/") else url


def detect(model_id: str, environ: Mapping[str, str]) -> tuple[int | None, int]:
    """(context window or None, exit status). Status 3 means the provider rejected the key."""
    provider, sep, rest = model_id.partition("/")
    model = rest if sep else model_id  # bash ${1#*/} keeps the whole id when there is no slash
    if not _usable_model(model):
        return None, EXIT_NOT_FOUND
    try:
        path = env.providers_file_text(environ)
        base = _checked_base(provider, providers.field(path, provider, "base-url"))
        if base is None:
            return None, EXIT_NOT_FOUND
        key = providers.bearer_key(path, provider, environ, env.proc_version_file_text(environ))
        headers = {"Authorization": f"Bearer {key}"} if key else {}
        detector = _Detector(environ, base, headers)
    except providers.ProviderError as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return None, EXIT_NOT_FOUND
    except BrokenPipeError:
        raise
    except OSError as exc:  # only paths and strerror text, never a key
        sys.stderr.write(f"shunt: {exc}\n")
        return None, EXIT_NOT_FOUND
    except ValueError:  # a bad timeout (no text kept)
        return None, EXIT_NOT_FOUND
    value = detector.run(model)
    if value is None and detector.auth_seen != _AUTH_NONE:
        return None, EXIT_AUTH_FAILED
    return value, 0 if value is not None else EXIT_NOT_FOUND


def run(args: argparse.Namespace) -> int:
    # Registered models only, checked before the key is resolved or anything is sent (migrate calls detect() directly).
    if probe.ask(os.environ, "has-model", args.model_id)[1] != 0:
        sys.stderr.write(f"shunt: model '{args.model_id}' is not in the registry (no request sent).\n")
        return EXIT_NOT_FOUND
    value, status = detect(args.model_id, os.environ)
    if value is not None:
        sys.stdout.write(f"{value}\n")
    return status


def register(subparsers: Any) -> None:
    """Add the `context` command group to the top-level subparsers."""
    context = subparsers.add_parser("context", help="detect a model's context window from its provider")
    context.set_defaults(func=run)
    sub = context.add_subparsers(dest="context_command", required=True)
    sub.add_parser("detect").add_argument("model_id")
