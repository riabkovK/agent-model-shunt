"""Read side of providers.json, the keyring backends and API key resolution.

Port of the read half of scripts/lib/providers.sh. Output text, stderr messages
and exit codes match the bash functions that now wrap these subcommands. The
writers of providers.json (shunt_providers_write, shunt_provider_plaintext_store)
and the lock helpers stay in bash until sub-phase 6. Nothing here takes the
providers lock: bash holds it around its read-modify-write and calls the getters
in between, so a lock here would deadlock against its own caller.

Secret rules: a key is printed only by `key-resolve` (callers capture it) and
`keyring-get`, or written into a 0600 header file. It is never put in an
exception message, a log line or stderr. The keyring CLIs get it on stdin. The
one exception is macOS `security add-generic-password`, which has no stdin mode
for the password (documented limitation, same as the bash).
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from collections.abc import Mapping, Sequence
from typing import Any

from . import env
from .jsonio import JsonReadError, read_json

TRANSPORTS: tuple[str, ...] = ("http", "opencode")  # keep in sync with SHUNT_PROVIDER_TRANSPORTS in providers.sh
KEY_TYPES: tuple[str, ...] = ("keyring", "env", "plaintext", "none")  # and SHUNT_PROVIDER_KEY_TYPES
KEYRING_SERVICE = "agent-model-shunt"
KWALLET_WALLET = "kdewallet"
BACKENDS: tuple[str, ...] = ("secret-tool", "security", "kwallet-query")
PROC_VERSION_DEFAULT = "/proc/version"

EXIT_CONFIG = 1  # a key or configuration problem
JQ_ERROR_EXIT = 5  # what jq returned for a runtime error

_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
_URL_CRED_RE = re.compile(r"^([A-Za-z][A-Za-z0-9+.-]*://)?[^/?#]*@")
_ENV_REF_VALIDATE_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")  # `$` also matches before a final newline, as in jq
_ENV_REF_STRICT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")  # bash [[ =~ ]] anchors strictly
_URL_FORBIDDEN = frozenset(" \t\n\v\f\r\x7f") | frozenset(chr(c) for c in range(32))
_BASH_Q_SAFE = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-.~=:+@%/#")

FIELD_DEFAULTS = {"transport": "opencode", "base-url": "", "key-type": "none", "key-ref": "", "healthcheck": "false"}


class ProviderError(Exception):
    """A user-facing failure: printed as `shunt: <message>` on stderr, exit code `code`."""

    def __init__(self, message: str, code: int = EXIT_CONFIG) -> None:
        super().__init__(message)
        self.code = code


class _Unvalidatable(Exception):
    """The shape made the jq program fail at runtime (`false.type`), not report a problem."""


# ---------------------------------------------------------------- jq-like helpers

def _alt(value: Any, default: Any) -> Any:
    """jq `value // default`: null and false fall back."""
    return default if value is None or value is False else value


def _tojson(value: str) -> str:
    """jq tojson of a string: compact, non-ASCII raw, DEL escaped like jq does."""
    return json.dumps(value, ensure_ascii=False).replace("\x7f", "\\u007f")


def _bash_quote(text: str) -> str:
    """Approximation of bash printf %q for the hints that name a provider."""
    if text == "":
        return "''"
    if any(ord(c) < 32 or ord(c) == 127 for c in text):
        escapes = {"\n": "\\n", "\t": "\\t", "\r": "\\r", "'": "\\'", "\\": "\\\\"}
        body = "".join(escapes.get(c) or (f"\\{ord(c):03o}" if ord(c) < 32 or ord(c) == 127 else c) for c in text)
        return f"$'{body}'"
    return "".join(c if c in _BASH_Q_SAFE or ord(c) > 127 else "\\" + c for c in text)


# ---------------------------------------------------------------- reading and validating

def entry_problem(name: str, value: Any) -> str | None:
    """Describe what is wrong with one providers entry, or None. Never includes a key ref."""
    if not _NAME_RE.fullmatch(name):
        return (f"provider {_tojson(name)}: provider name has characters other than letters, digits, dot, "
                "dash and underscore, or does not start with a letter or digit. "
                "Please edit providers.json to remove or rename that entry")
    label = f'provider "{name}"'
    if not isinstance(value, dict):
        return f"{label}: entry is not an object"
    transport = _alt(value.get("transport"), "opencode")
    if not isinstance(transport, str):
        return f"{label}: transport is not a string"
    if transport not in TRANSPORTS:
        return f'{label}: unknown transport "{transport}" (allowed: {" ".join(TRANSPORTS)})'
    base_url = _alt(value.get("base_url"), "")
    if not isinstance(base_url, str):
        return f"{label}: base_url is not a string"
    if _URL_CRED_RE.search(base_url):
        return f"{label}: base_url has credentials (user:password@) in it"
    if value.get("healthcheck") is not None and not isinstance(value.get("healthcheck"), bool):
        return f"{label}: healthcheck is not a boolean (true or false)"
    key = _alt(value.get("key"), {})
    if not isinstance(key, dict):
        return f'{label}: key is not an object (expected {{"type":"...","ref":"..."}})'
    if value.get("key") is False:
        raise _Unvalidatable  # jq indexes `false.type` here and dies
    key_type = _alt(key.get("type"), "none")
    if not isinstance(key_type, str):
        return f"{label}: key type is not a string"
    if key_type not in KEY_TYPES:
        return f'{label}: unknown key type "{key_type}" (allowed: {" ".join(KEY_TYPES)})'
    ref = _alt(key.get("ref"), "")
    if not isinstance(ref, str):
        return f"{label}: key ref is not a string"
    if key.get("type") == "env" and not _ENV_REF_VALIDATE_RE.search(ref):
        return f"{label}: env key ref is not a valid environment variable name"
    return None


def _providers(path: str) -> dict[str, Any] | None:
    """The providers object, or None when the file is not a regular file (absent means all defaults)."""
    if not os.path.isfile(path):
        return None
    try:
        doc = read_json(path)
    except JsonReadError:
        doc = None
    providers = doc.get("providers") if isinstance(doc, dict) else None
    if not isinstance(providers, dict):
        raise ProviderError(f'{path} is invalid JSON or has no "providers" object.')
    return providers


def validate(path: str) -> None:
    """Raise ProviderError unless the file is absent or valid."""
    providers = _providers(path)
    if providers is None:
        return
    try:
        for name, value in providers.items():
            problem = entry_problem(name, value)
            if problem is not None:
                raise ProviderError(f"{path}: {problem.split(chr(10), 1)[0]}")
    except _Unvalidatable:
        raise ProviderError(f"{path} could not be validated.") from None


def list_lines(path: str) -> list[str]:
    """One tab-separated line per provider. An invalid entry gets `invalid: <reason>`."""
    if not os.path.isfile(path):
        raise ProviderError(f"{path}: cannot open the providers file.", 2)
    try:
        providers = _providers(path)
    except ProviderError:
        raise ProviderError(f'{path} is invalid JSON or has no "providers" object.', JQ_ERROR_EXIT) from None
    lines: list[str] = []
    assert providers is not None
    for name, value in providers.items():
        try:
            problem = entry_problem(name, value)
        except _Unvalidatable:
            _flush(lines)
            raise ProviderError(f"{path} could not be validated.", JQ_ERROR_EXIT) from None
        if problem is not None:
            lines.append(f"{name}\tinvalid: {problem}")
            continue
        key = _alt(value.get("key"), {})
        key_type = key.get("type")
        key_col = f"env:{_alt(key.get('ref'), '')}" if key_type == "env" else _alt(key_type, "none")
        lines.append(f"{name}\t{_alt(value.get('transport'), 'opencode')}\t{_alt(value.get('base_url'), '-')}\t{key_col}")
    return lines


def _emit(text: str) -> None:
    """Write text plus a newline as raw bytes, so a non-UTF-8 key cannot raise."""
    sys.stdout.flush()
    sys.stdout.buffer.write(os.fsencode(text) + b"\n")
    sys.stdout.buffer.flush()


def _flush(lines: Sequence[str]) -> None:
    for line in lines:
        sys.stdout.write(line + "\n")


def base_url_check(url: str) -> int:
    """0 usable, 2 other scheme, 3 no scheme, 1 malformed (empty host, userinfo, whitespace, control)."""
    if url.startswith("https://"):
        rest = url[len("https://"):]
    elif url.startswith("http://"):
        rest = url[len("http://"):]
    elif "://" in url:
        return 2
    else:
        rest = url
    authority = re.split(r"[/?#]", rest, maxsplit=1)[0]
    if not authority or any(c in _URL_FORBIDDEN for c in url) or "@" in authority:
        return 1
    return 0 if rest != url else 3


def field(path: str, provider: str, name: str) -> str:
    """transport, base-url, key-type or key-ref of a provider, or the default when unset."""
    default = FIELD_DEFAULTS[name]
    validate(path)
    providers = _providers(path)
    if providers is None:
        return default
    entry = providers.get(provider)
    if not isinstance(entry, dict):
        return default
    if name == "transport":
        value = entry.get("transport")
    elif name == "base-url":
        value = entry.get("base_url")
    elif name == "healthcheck":
        return "true" if entry.get("healthcheck") is True else default
    else:
        key = entry.get("key")
        value = key.get("type" if name == "key-type" else "ref") if isinstance(key, dict) else None
    return _alt(value, default)


# ---------------------------------------------------------------- keyring

def is_wsl(version_file: str) -> bool:
    try:
        with open(version_file, "rb") as handle:
            return b"microsoft" in handle.read().lower()
    except OSError:
        return False


def keyring_backend(version_file: str) -> str:
    """The first usable backend, or "" (none installed, or running under WSL)."""
    if is_wsl(version_file):
        return ""
    for tool in BACKENDS:
        if shutil.which(tool):
            return tool
    return ""


def _store_argv(backend: str, provider: str, key: str) -> list[str]:
    if backend == "secret-tool":
        return ["secret-tool", "store", f"--label={KEYRING_SERVICE} {provider}",
                "service", KEYRING_SERVICE, "account", provider]
    if backend == "kwallet-query":
        return ["kwallet-query", "-f", KEYRING_SERVICE, "-w", provider, KWALLET_WALLET]
    # LIMITATION: `security add-generic-password` has no stdin mode for the password.
    return ["security", "add-generic-password", "-U", "-s", f"{KEYRING_SERVICE}/{provider}",
            "-a", KEYRING_SERVICE, "-w", key]


def keyring_store(provider: str, version_file: str, stdin: Any) -> None:
    """Store the key read from stdin. secret-tool and kwallet-query get it on stdin."""
    backend = keyring_backend(version_file)
    if not backend:
        raise ProviderError("no keyring backend available.")
    data = stdin.read()
    key = ""
    if backend == "security":
        key = data.split(b"\n", 1)[0].decode("utf-8", "surrogateescape")
    stdout = None if backend == "secret-tool" else subprocess.DEVNULL
    try:
        # No check= and no timeout: the CompletedProcess/CalledProcessError text would carry argv.
        stdin_kwargs = {"stdin": subprocess.DEVNULL} if backend == "security" else {"input": data}
        proc = subprocess.run(_store_argv(backend, provider, key), stdout=stdout, check=False, **stdin_kwargs)
        failed = proc.returncode != 0
    except (OSError, ValueError):  # ValueError: NUL in argv. Its text never carries the key.
        failed = True
    if failed:
        raise ProviderError(f"storing the key in {backend} failed.")


def _lookup_argv(backend: str, provider: str) -> list[str]:
    if backend == "secret-tool":
        return ["secret-tool", "lookup", "service", KEYRING_SERVICE, "account", provider]
    if backend == "security":
        return ["security", "find-generic-password", "-s", f"{KEYRING_SERVICE}/{provider}", "-w"]
    return ["kwallet-query", "-f", KEYRING_SERVICE, "-r", provider, KWALLET_WALLET]


def keyring_get(provider: str, version_file: str) -> str | None:
    """The stored key, or None when there is none. Trailing newlines are dropped like $(...)."""
    backend = keyring_backend(version_file)
    if not backend:
        return None
    try:
        proc = subprocess.run(_lookup_argv(backend, provider), stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    except OSError:
        return None
    key = proc.stdout.decode("utf-8", "surrogateescape").rstrip("\n")
    return key or None


# ---------------------------------------------------------------- key resolution

def key_resolve(path: str, provider: str, environ: Mapping[str, str], version_file: str) -> str | None:
    """The key (None for type none). Errors name the source, never a value."""
    key_type = field(path, provider, "key-type")
    if key_type == "none":
        return None
    hint = f"Run: shunt-models key set {_bash_quote(provider)}"
    if key_type == "env":
        ref = field(path, provider, "key-ref").rstrip("\n")  # bash read the ref through $(...)
        if not _ENV_REF_STRICT_RE.fullmatch(ref):
            raise ProviderError(f"provider '{provider}': key ref is not a valid environment variable name.")
        value = environ.get(ref, "")
        if not value:
            raise ProviderError(f"provider '{provider}': environment variable {ref} is unset or empty.")
        return value
    if key_type == "plaintext":
        ref = field(path, provider, "key-ref").rstrip("\n")
        if not ref:
            raise ProviderError(f"provider '{provider}': no plaintext key stored. {hint}")
        return ref
    key = keyring_get(provider, version_file)
    if key is None:
        raise ProviderError(f"provider '{provider}': no key found in the keyring. {hint}")
    return key


def bearer_key(path: str, provider: str, environ: Mapping[str, str], version_file: str) -> str | None:
    """The key ready for an `Authorization: Bearer` header, None when there is none.

    A key with a line break is refused so it cannot smuggle extra headers.
    """
    key = key_resolve(path, provider, environ, version_file)
    key = (key or "").rstrip("\n")  # bash captured the key with $(...)
    if not key:
        return None
    if "\n" in key or "\r" in key:
        raise ProviderError(f"provider '{provider}': the key contains a line break.")
    return key


# ---------------------------------------------------------------- command line

def _dispatch(args: argparse.Namespace, environ: Mapping[str, str]) -> int:
    path = env.providers_file_text(environ)
    version_file = env.proc_version_file_text(environ)
    cmd = args.providers_command
    if cmd == "validate":
        validate(path)
    elif cmd == "list-lines":
        _flush(list_lines(path))
    elif cmd == "base-url-check":
        return base_url_check(args.url)
    elif cmd == "field":
        sys.stdout.write(field(path, args.provider, args.name) + "\n")
    elif cmd == "keyring-backend":
        backend = keyring_backend(version_file)
        if backend:
            sys.stdout.write(backend + "\n")
    elif cmd == "keyring-store":
        keyring_store(args.provider, version_file, sys.stdin.buffer)
    elif cmd == "keyring-get":
        key = keyring_get(args.provider, version_file)
        if key is None:
            return 1
        _emit(key)
    elif cmd == "key-resolve":
        key = key_resolve(path, args.provider, environ, version_file)
        if key is not None:
            _emit(key)
    return 0


def run(args: argparse.Namespace) -> int:
    try:
        return _dispatch(args, os.environ)
    except ProviderError as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return exc.code
    except BrokenPipeError:
        raise
    except ValueError:  # e.g. a key that cannot be encoded: no exception text, it could echo the key
        sys.stderr.write("shunt: the key could not be processed (invalid characters).\n")
        return 1
    except OSError as exc:  # never a key in here: only paths and strerror text
        sys.stderr.write(f"shunt: {exc}\n")
        return 1


def register(subparsers: Any) -> None:
    """Add the `providers` command group to the top-level subparsers."""
    providers = subparsers.add_parser("providers", help="read providers.json and resolve API keys")
    providers.set_defaults(func=run)
    sub = providers.add_subparsers(dest="providers_command", required=True)
    sub.add_parser("validate")
    sub.add_parser("list-lines")
    sub.add_parser("keyring-backend")
    sub.add_parser("base-url-check").add_argument("url")
    one = sub.add_parser("field")
    one.add_argument("name", choices=sorted(FIELD_DEFAULTS))
    one.add_argument("provider")
    for name in ("keyring-store", "keyring-get", "key-resolve"):
        sub.add_parser(name).add_argument("provider")
