"""Plan side of `shunt-models --migrate-from-opencode`: read opencode.json, build and print the plan.

Port of the first half of scripts/lib/migrate.sh. The plan is one dict:
  {"providers": [{name, base_url, state, storage, env_ref, reason, entry, key_source, key_path}],
   "models": [{id, request_body, context: {tokens, source} | None, deferred}]}
state: new | pending | done | skip. storage: none env keyring plaintext stored skip ask.

Secret rules: a key that is copied (a literal, a file or an auth.json key) is never printed,
logged or put in the plan. read_key hands it to the caller, who passes it on stdin of the
storage only. Context detection runs in this process: the one stored plaintext key it needs
is placed in a copy of the environment dict, never in the real environment, a file or argv.
"""

import contextlib
import io
import json
import os
import re
import stat
import sys
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any

from . import context_detect, env, providers
from .jsonio import JsonReadError, read_capped, read_json
from .providers import ProviderError

STORAGE_CHOICES = ("keyring", "env", "plaintext", "skip")
DETECT_KEY_VAR = "SHUNT_MIGRATE_DETECT_KEY"
MAX_CONTEXT_DIGITS = 12
MAX_KEY_FILE_BYTES = 4096
_FORBIDDEN_KEY_DIRS = ("/proc/", "/sys/")

_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
_ENV_KEY_RE = re.compile(r"^\{env:([A-Za-z_][A-Za-z0-9_]*)\}$")  # `$` also matches before a final newline, as in jq
_FILE_KEY_RE = re.compile(r"^\{file:(.+)\}$")
_SPACE = " \t\n\v\f\r"  # bash [:space:]
_NO_SCHEME_MSG = "base_url scheme must be http:// or https://"


@dataclass
class Ctx:
    environ: Mapping[str, str]
    apply: bool = False
    flag: str = ""
    hint_cmd: str = ""
    used_refs: set[str] = field(default_factory=set)

    @property
    def models_path(self) -> str:
        return env.models_file_text(self.environ)

    @property
    def providers_path(self) -> str:
        return env.providers_file_text(self.environ)

    @property
    def opencode_json(self) -> str:
        return str(env.opencode_config_home(self.environ) / "opencode.json")

    @property
    def version_file(self) -> str:
        return env.proc_version_file_text(self.environ)


def load(path: str) -> Any:
    """The parsed JSON file, None when it is absent or unreadable (jq errors were ignored)."""
    try:
        return read_json(path)
    except (JsonReadError, OSError, RecursionError):
        return None


def as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def tojson(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _text(value: Any) -> str:
    """jq -r: a string as is, anything else as JSON text (null and false count as empty, jq `//`)."""
    if value is None or value is False:
        return ""
    return value if isinstance(value, str) else tojson(value)


def is_unset(value: Any) -> bool:
    """jq `(.x // null) == null`: missing, null and false all count as unset."""
    return value is None or value is False


def _trim(text: str) -> str:
    return text.strip(_SPACE)


def _key_usable(key: str) -> bool:
    return key != "" and "\n" not in key and "\r" not in key


# ---------------------------------------------------------------- opencode.json

def _opencode_providers(ctx: Ctx) -> dict[str, Any]:
    return as_dict(as_dict(load(ctx.opencode_json)).get("provider"))


def collect_providers(ctx: Ctx) -> list[dict[str, Any]]:
    """One entry per opencode provider used by the registry, the key classified as none | env | file | literal."""
    models_doc = as_dict(load(ctx.models_path))
    entries = models_doc.get("models") if isinstance(models_doc.get("models"), list) else []
    used = {m["id"].split("/")[0] for m in entries if isinstance(m, dict) and isinstance(m.get("id"), str)}
    found = []
    for name, value in _opencode_providers(ctx).items():
        if name not in used:
            continue
        options = as_dict(as_dict(value).get("options"))
        raw = options.get("apiKey")
        raw = "" if raw is None or raw is False else raw
        key = raw if isinstance(raw, str) else ""
        env_match, file_match = _ENV_KEY_RE.search(key), _FILE_KEY_RE.search(key)
        kind = "none" if key == "" else "env" if env_match else "file" if file_match else "literal"
        found.append({
            "name": name, "bad_name": _NAME_RE.fullmatch(name) is None, "base_url": _text(options.get("baseURL")),
            "bad_key": not isinstance(raw, str) and raw != "", "key_kind": kind,
            "env_ref": env_match.group(1) if env_match else "", "key_path": file_match.group(1) if file_match else "",
        })
    return found


def initial_used_refs(ctx: Ctx) -> set[str]:
    """Env refs already taken: every {env:NAME} of any opencode provider and those in providers.json."""
    refs = set()
    for value in _opencode_providers(ctx).values():
        key = as_dict(as_dict(value).get("options")).get("apiKey")
        match = _ENV_KEY_RE.search(key) if isinstance(key, str) else None
        if match:
            refs.add(match.group(1))
    table = as_dict(as_dict(load(ctx.providers_path)).get("providers"))
    for value in table.values():
        key = as_dict(as_dict(value).get("key"))
        if key.get("type") == "env" and isinstance(key.get("ref"), str):
            refs.add(key["ref"])
    return refs


# ---------------------------------------------------------------- key sources

def _expand_path(ctx: Ctx, path: str) -> str:
    home = str(env.home(ctx.environ))
    if path == "~":
        return home
    if path.startswith("~/"):
        return f"{home}/{path[2:]}"
    if path.startswith("/"):
        return path
    return f"{env.opencode_config_home(ctx.environ)}/{path}"


def _read_file_key(ctx: Ctx, path: str) -> str | None:
    """The trimmed content of a key file, None when it is absent, unreadable or not a usable key."""
    full = os.path.normpath(_expand_path(ctx, path))
    if full.startswith(_FORBIDDEN_KEY_DIRS):
        return None
    try:
        fd = os.open(full, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):  # no FIFO, device or directory
            return None
        data = read_capped(fd, MAX_KEY_FILE_BYTES + 1)
    except OSError:
        return None
    finally:
        os.close(fd)
    if len(data) > MAX_KEY_FILE_BYTES or b"\0" in data:
        return None
    key = _trim(data.decode("utf-8", "surrogateescape"))
    return key if _key_usable(key) else None


def _auth_json_key(ctx: Ctx, provider: str) -> str | None:
    entry = as_dict(load(str(env.opencode_auth_json(ctx.environ)))).get(provider)
    if not isinstance(entry, dict) or entry.get("type") != "api" or not isinstance(entry.get("key"), str):
        return None
    return entry["key"] if entry["key"].strip() else None


def read_key(ctx: Ctx, entry: Mapping[str, Any]) -> str | None:
    """The key the plan copies for a provider, from its source. None when it is unusable."""
    source, name = entry["key_source"], entry["name"]
    if source == "literal":
        raw = as_dict(as_dict(_opencode_providers(ctx).get(name)).get("options")).get("apiKey")
        return raw.rstrip("\n") if isinstance(raw, str) else None
    if source == "file":
        return _read_file_key(ctx, entry["key_path"])
    if source == "auth.json":
        raw = _auth_json_key(ctx, name)
        key = _trim(raw) if raw is not None else ""
        return key if _key_usable(key) else None
    return None


def _key_source(ctx: Ctx, name: str, kind: str, path: str) -> tuple[str, str]:
    """(source, error): source is literal, file, auth.json or empty. A non-empty error makes the provider skip."""
    if kind == "literal":
        return "literal", ""
    if kind == "file":
        if _read_file_key(ctx, path) is None:
            return "", f"the apiKey file {path} is not readable or is empty, so the key cannot be copied"
        return "file", ""
    if kind == "none" and _auth_json_key(ctx, name) is not None:
        return "auth.json", ""
    return "", ""


# ---------------------------------------------------------------- provider plan

def base_env_ref(name: str) -> str:
    return "SHUNT_" + re.sub(r"[^A-Z0-9]", "_", name.upper()) + "_KEY"


def default_env_ref(ctx: Ctx, name: str) -> str:
    """SHUNT_<NAME>_KEY, with a _2, _3, ... suffix while that ref is used by another provider."""
    base = ref = base_env_ref(name)
    count = 1
    while ref in ctx.used_refs:
        count += 1
        ref = f"{base}_{count}"
    return ref


def _has_tty() -> bool:
    return sys.stdin is not None and sys.stdin.isatty()


def _ask_storage(ctx: Ctx, name: str) -> str:
    default = "keyring" if providers.keyring_backend(ctx.version_file) else "env"
    sys.stderr.write(f"Key storage for '{name}' ({' '.join(STORAGE_CHOICES)}, default {default}): ")
    sys.stderr.flush()
    choice = sys.stdin.readline().strip(" \t\n") or default
    if choice in STORAGE_CHOICES:
        return choice
    sys.stderr.write(f"shunt: '{choice}' is not a storage choice, skipping the key of '{name}'.\n")
    return "skip"


def _already_stored(ctx: Ctx, name: str) -> bool:
    try:
        if providers.field(ctx.providers_path, name, "key-type") not in ("keyring", "plaintext"):
            return False
        providers.key_resolve(ctx.providers_path, name, ctx.environ, ctx.version_file)
    except ProviderError:
        return False
    return True


def resolve_storage(ctx: Ctx, name: str, kind: str) -> str:
    if kind in ("none", "env"):
        return kind
    if _already_stored(ctx, name):
        return "stored"
    if ctx.flag:
        storage = ctx.flag
    elif _has_tty() and ctx.apply:
        storage = _ask_storage(ctx, name)
    elif _has_tty():
        return "ask"
    else:
        sys.stderr.write(f"shunt: provider '{name}' has a key to copy, no tty and no --key-storage: treating it as skip.\n")
        storage = "skip"
    if storage == "keyring" and not providers.keyring_backend(ctx.version_file):
        sys.stderr.write(f"shunt: no keyring backend found, treating the key of '{name}' as skip.\n")
        storage = "skip"
    return storage


def make_entry(storage: str, base: str, ref: str) -> dict[str, Any]:
    """The providers.json fields the migration sets for a provider."""
    if storage in ("skip", "ask"):
        return {"transport": "opencode", "base_url": base, "key": {"type": "keyring"}}
    entry: dict[str, Any] = {"transport": "http", "base_url": base}
    if storage == "none":
        entry["key"] = {"type": "none"}
    elif storage == "env":
        entry["key"] = {"type": "env", "ref": ref}
    elif storage in ("keyring", "plaintext"):
        entry["key"] = {"type": storage}
    return entry


def _base_url_problem(name: str, raw: str) -> tuple[str, str]:
    """(base url to use, reason). A non-empty reason means the url is unusable."""
    code = providers.base_url_check(raw)
    if code == 0:
        return raw, ""
    if code == 3:
        return "https://" + raw, ""
    if code == 2:
        return "", f"provider '{name}': {_NO_SCHEME_MSG} (config problem, no request sent)."
    return "", f"provider '{name}': base_url is malformed or has credentials in it (config problem, no request sent)."


def _transport(ctx: Ctx, name: str) -> str:
    try:
        return providers.field(ctx.providers_path, name, "transport")
    except ProviderError:
        return ""


def _with_note(reason: str, note: str) -> str:
    if not reason:
        return note
    return f"{reason} {note}" if reason[-1] in ".!?" else f"{reason}. {note}"


def plan_provider(ctx: Ctx, found: Mapping[str, Any]) -> dict[str, Any]:
    name, kind, ref, path = found["name"], found["key_kind"], found["env_ref"], found["key_path"]
    state, storage, reason, base, entry, source = "new", "none", "", "", None, ""
    if found["bad_name"]:
        state, reason = "skip", ("the provider name has characters other than letters, digits, dot, dash and "
                                 "underscore, so it stays on opencode")
    elif _transport(ctx, name) == "http":
        state, reason = "done", "already on the http transport"
    else:
        url, problem = _base_url_problem(name, found["base_url"])
        source, key_error = ("", "") if problem else _key_source(ctx, name, kind, path)
        if problem:
            state, reason = "skip", problem
        elif key_error:
            state, reason = "skip", f"{key_error}, the provider stays on opencode"
        else:
            kind = "literal" if source else kind
            base = url
            storage = resolve_storage(ctx, name, kind)
            if storage == "env" and kind != "env":
                ref = default_env_ref(ctx, name)
                if ref != base_env_ref(name):
                    reason = f"the default env ref is taken by another provider, so this one gets {ref}"
            state = "pending" if storage in ("skip", "ask") else state
            entry = make_entry(storage, base, ref)
    if found["bad_key"] and state != "done":
        reason = _with_note(reason, "the apiKey in opencode.json is not a string, so it is not imported as a key")
    return {"name": name, "base_url": base, "state": state, "storage": storage, "env_ref": ref, "reason": reason,
            "entry": entry, "key_source": source, "key_path": path}


# ---------------------------------------------------------------- model plan

def _effort(ctx: Ctx, model: Mapping[str, Any]) -> str:
    """The reasoning effort: the registry thinking_options first, then the model's options in opencode.json."""
    model_id = model["id"]
    provider, _, rest = model_id.partition("/")
    local = rest if "/" in model_id else model_id
    own = as_dict(model.get("thinking_options")).get("reasoningEffort")
    if not isinstance(own, str):
        entry = as_dict(as_dict(as_dict(_opencode_providers(ctx).get(provider)).get("models")).get(local))
        own = as_dict(entry.get("options")).get("reasoningEffort")
    return own if isinstance(own, str) else ""


def _opencode_limit(ctx: Ctx, model_id: str) -> int | None:
    provider, _, rest = model_id.partition("/")
    local = rest if "/" in model_id else model_id
    entry = as_dict(as_dict(as_dict(_opencode_providers(ctx).get(provider)).get("models")).get(local))
    value = as_dict(entry.get("limit")).get("context")
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0 or value != int(value):
        return None
    return int(value) if len(str(int(value))) <= MAX_CONTEXT_DIGITS else None


def _detect_environ(ctx: Ctx, pfile: str, provider: str) -> dict[str, str]:
    """Copy of the environment for detection: when the sanitized copy is used, it holds the stored plaintext key."""
    environ = {k: v for k, v in ctx.environ.items() if k != DETECT_KEY_VAR}
    environ["SHUNT_PROVIDERS_FILE"] = pfile
    if pfile != ctx.providers_path:
        key = as_dict(as_dict(as_dict(load(ctx.providers_path)).get("providers")).get(provider)).get("key")
        ref = as_dict(key).get("ref")
        if as_dict(key).get("type") == "plaintext" and isinstance(ref, str) and ref:
            environ[DETECT_KEY_VAR] = ref
    return environ


def _detect(ctx: Ctx, model_id: str, pfile: str) -> int | None:
    environ = _detect_environ(ctx, pfile, model_id.split("/")[0])
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            value, status = context_detect.detect(model_id, environ)
        except BrokenPipeError:
            raise
        except (OSError, ValueError, ProviderError):
            return None
    return value if status == 0 else None


def _context(ctx: Ctx, model_id: str, detect: bool, pfile: str) -> dict[str, Any] | None:
    if detect:
        tokens = _detect(ctx, model_id, pfile)
        if tokens is not None:
            return {"tokens": tokens, "source": "detected from the provider"}
    limit = _opencode_limit(ctx, model_id)
    return None if limit is None else {"tokens": limit, "source": "from opencode.json, not verified"}


def _defers_detection(owner: Mapping[str, Any]) -> bool:
    """A key from opencode.json (or copied from it) must not travel to its baseURL before the user confirmed --apply."""
    return owner["state"] == "new" and owner["storage"] != "none"


def plan_models(ctx: Ctx, plan: Mapping[str, Any], detect_all: bool, pfile: str) -> list[dict[str, Any]]:
    states = {p["name"]: p for p in plan["providers"]}
    out = []
    for model in as_dict(load(ctx.models_path)).get("models", []):
        model_id = model["id"]
        owner = states.get(model_id.split("/")[0])
        if owner is None or owner["state"] not in ("new", "done"):
            continue
        deferred = _defers_detection(owner) and not detect_all
        request_body = None
        if is_unset(model.get("request_body")):
            effort = _effort(ctx, model)
            request_body = {"reasoning_effort": effort} if effort else None
        context = None
        if is_unset(model.get("context_tokens")):
            context = _context(ctx, model_id, not deferred, pfile)
        out.append({"id": model_id, "request_body": request_body, "context": context, "deferred": deferred})
    return out
