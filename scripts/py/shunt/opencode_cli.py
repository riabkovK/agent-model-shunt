"""The OpenCode CLI transport: `opencode run --agent <agent> <question> -f <file>... --format json`
against an isolated config, normalized into the response format of transport.py.

Port of the opencode half of scripts/lib/transport.sh and of shunt_prepare_isolated_config in
scripts/lib/opencode.sh. The child is started from an explicit argv list (no shell), its stdin is
/dev/null, its stdout goes to a private temp file and its stderr is dropped. It gets the environment
of this process plus XDG_CONFIG_HOME, nothing else. The wrapper only adds paths and limits, no
secret, and an API key an operator exported reaches the child exactly as it reached the bash one.
"""

from __future__ import annotations

import argparse
import codecs
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
from collections.abc import Mapping, Sequence
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from . import env
from . import transport_reply as reply
from .jsonio import JsonReadError, read_json, write_bytes_atomic
from .transport_reply import CONFIG, EMPTY, ERROR, OVERSIZE, TIMEOUT

# What `opencode run -f <file>` keeps of an attached file (opencode 1.18.18 read tool).
MAX_FILE_LINES = 2000
MAX_FILE_BYTES = 51200
MAX_LINE_CHARS = 2000
OUT_PREFIX = "shunt-opencode."
DEFAULT_TIMEOUT = "300"
TERM_GRACE_SECONDS = 5.0
MAX_TRANSCRIPT_BYTES = 64 * 1024 * 1024
READ_CHUNK = 64 * 1024
BYTES_PER_TOKEN = 3
CONTEXT_BUDGET_PERCENT = 60
MAX_CONTEXT_DIGITS = 12
_CONTEXT_RE = re.compile(r"[1-9][0-9]*")
_TIMEOUT_RE = re.compile(r"([0-9]+(?:\.[0-9]*)?|\.[0-9]+)([smhd]?)", re.ASCII)
MAX_TIMEOUT = 10.0**9  # seconds, past this there is no practical limit
_WS = re.compile(r"[ \t\r\n]*")
_UNITS = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}
# Environment names the bash wrapper sets only for this process. Empty, they are not passed on.
_WRAPPER_ONLY = ("TMPDIR", "SHUNT_TRANSPORT")
_FALLBACK = {"text": "", "finish_reason": ""}


class _Bad(Exception):
    """The transcript is not something the jq program accepted."""


def _num(value: Any) -> int | float:
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


def _obj(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _alt(value: Any, default: Any) -> Any:
    return default if value is None or value is False else value


def _clean(value: int | float) -> int | float:
    return int(value) if isinstance(value, float) and value.is_integer() and abs(value) < 1e17 else value


def _events(text: str) -> list[Any]:
    decoder = json.JSONDecoder()
    events: list[Any] = []
    pos, end = 0, len(text)
    while True:
        pos = _WS.match(text, pos).end()  # type: ignore[union-attr]
        if pos >= end:
            return events
        value, pos = decoder.raw_decode(text, pos)
        events.append(value)


def _field(event: Any, name: str) -> Any:
    """jq's `.name` on a value: null and objects only, anything else is an error."""
    if event is None:
        return None
    if isinstance(event, dict):
        return event.get(name)
    raise _Bad


def normalize_text(text: str) -> dict[str, Any]:
    """The normalized response of an `opencode run --format json` transcript: the last text event,
    the reason of the last step_finish, tokens and cost summed over every step_finish. Cached prompt
    tokens count as input and reasoning as output. Output that is not JSON gives the empty answer."""
    try:
        events = _events(text)
        texts = [e for e in events if _field(e, "type") == "text"]
        steps = [_obj(_field(e, "part")) for e in events if _field(e, "type") == "step_finish"]
        answer = _alt(_field(_field(texts[-1], "part"), "text"), "") if texts else ""
    except (ValueError, _Bad, RecursionError):
        return dict(_FALLBACK)
    result: dict[str, Any] = {"text": answer, "finish_reason": _alt((steps[-1] if steps else {}).get("reason"), "")}
    if steps:
        tokens = [_obj(step.get("tokens")) for step in steps]
        result["usage"] = {
            "input": _clean(sum(_num(t.get("input")) + _num(_obj(t.get("cache")).get("read"))
                                + _num(_obj(t.get("cache")).get("write")) for t in tokens)),
            "output": _clean(sum(_num(t.get("output")) + _num(t.get("reasoning")) for t in tokens)),
        }
    costs = [s["cost"] for s in steps if isinstance(s.get("cost"), (int, float)) and not isinstance(s["cost"], bool)]
    if costs:
        result["cost"] = _clean(sum(costs))
    return result


def normalize_file(path: str) -> dict[str, Any]:
    try:
        with open(path, "rb") as handle:
            data = handle.read(MAX_TRANSCRIPT_BYTES + 1)
    except OSError:
        return dict(_FALLBACK)
    if len(data) > MAX_TRANSCRIPT_BYTES:
        return dict(_FALLBACK)
    return normalize_text(data.decode("utf-8", "replace"))


# ---------------------------------------------------------------- size guard

def file_too_big(path: str) -> str | None:
    """Why opencode would truncate the attached file, or None when it fits (or cannot be read)."""
    if not os.path.isfile(path) or not os.access(path, os.R_OK):
        return None
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    size = newlines = longest = current = 0
    try:
        with open(path, "rb") as handle:
            while True:
                chunk = handle.read(READ_CHUNK)
                text = decoder.decode(chunk, final=not chunk)
                size += len(chunk)
                parts = text.split("\n")
                current += len(parts[0])
                for part in parts[1:]:
                    longest, newlines, current = max(longest, current), newlines + 1, len(part)
                if not chunk:
                    break
    except OSError:
        return None
    longest = max(longest, current)
    lines = newlines + (1 if current else 0)
    if lines > MAX_FILE_LINES:
        return f"{lines} lines, opencode keeps {MAX_FILE_LINES}"
    if size > MAX_FILE_BYTES:
        return f"{size} bytes, opencode keeps {MAX_FILE_BYTES}"
    if longest > MAX_LINE_CHARS:
        return f"a line of {longest} characters, opencode keeps {MAX_LINE_CHARS}"
    return None


def guard_size(agent: str, question: str, files: Sequence[str], model_id: str, context_tokens: str) -> None:
    """Refuse (OVERSIZE, one stderr line) an input opencode would truncate or that exceeds the
    context budget of a model with a known context_tokens. CONFIG for an unusable context_tokens."""
    name = model_id or agent
    for path in files:
        why = file_too_big(path)
        if why:
            sys.stderr.write(f"shunt: model {name}: '{path}' is too large for the opencode transport "
                             f"({why}), no request sent.\n")
            raise reply.Abort(OVERSIZE)
    if not context_tokens:
        return
    if not (_CONTEXT_RE.fullmatch(context_tokens) and len(context_tokens) <= MAX_CONTEXT_DIGITS):
        sys.stderr.write(f"shunt: model {name} has an invalid context_tokens in models.json (config problem, "
                         f"no request sent). Run: shunt-models set-context {name} <tokens>.\n")
        raise reply.Abort(CONFIG)
    size = len(question.encode("utf-8", "surrogateescape"))
    for path in files:
        if os.path.isfile(path) and os.access(path, os.R_OK):
            size += os.path.getsize(path)
    tokens = -(-size // BYTES_PER_TOKEN)
    budget = int(context_tokens) * CONTEXT_BUDGET_PERCENT // 100
    if tokens > budget:
        sys.stderr.write(f"shunt: model {name}: input is too large for the model (about {tokens} tokens, "
                         f"budget {budget}), no request sent.\n")
        raise reply.Abort(OVERSIZE)


# ---------------------------------------------------------------- isolated config

class ConfigError(Exception):
    """A fatal `shunt: <message>` of the isolated config."""


def _raw(environ: Mapping[str, str], name: str, default: Path) -> str:
    return environ.get(name) or str(default)


def provider_of(agent_text: str) -> str:
    """The provider of the first `model:` line (awk -F'[/: ]+' '/^model:/{print $2; exit}')."""
    for line in agent_text.split("\n"):
        if line.startswith("model:"):
            fields = re.split(r"[/: ]+", line)
            return fields[1] if len(fields) > 1 else ""
    return ""


def prepare_isolated_config(agent: str, environ: Mapping[str, str]) -> str:
    """Build the owner-only config root holding just the agent and the one provider its `model:`
    names, and return it. A copy of the user's provider block holds credentials, hence 0700/0600."""
    agents = _raw(environ, "SHUNT_AGENTS_DIR", env.agents_dir(environ))
    config_home = _raw(environ, "SHUNT_OPENCODE_CONFIG_HOME", env.opencode_config_home(environ))
    agent_file = Path(agents) / f"{agent}.md"
    if not agent_file.is_file():
        agent_file = Path(config_home) / "agents" / f"{agent}.md"
    if not agent_file.is_file():
        raise ConfigError(f"OpenCode agent '{agent}' not found in {agents} or {config_home}/agents. "
                          "See README's Setup section.")
    iso_root = Path(_raw(environ, "SHUNT_ISOLATED_CONFIG_DIR", env.isolated_config_dir(environ))) / agent
    iso_opencode = iso_root / "opencode"
    old_umask = os.umask(0o077)
    try:
        (iso_opencode / "agents").mkdir(parents=True, exist_ok=True)
        for directory in (iso_root, iso_opencode, iso_opencode / "agents"):
            os.chmod(directory, 0o700)
        data = agent_file.read_bytes()
        write_bytes_atomic(iso_opencode / "agents" / f"{agent}.md", data, 0o600)
        write_bytes_atomic(iso_opencode / "opencode.json",
                           _provider_json(provider_of(data.decode("utf-8", "surrogateescape")), config_home), 0o600)
    finally:
        os.umask(old_umask)
    return str(iso_root)


def _provider_json(provider: str, config_home: str) -> bytes:
    source = Path(config_home) / "opencode.json"
    if not provider or not source.is_file():
        return b"{}\n"
    try:
        doc = read_json(source)
        block = _field(doc, "provider")
        picked = None if block is None else block.get(provider) if isinstance(block, dict) else _fail_index()
    except (JsonReadError, _Bad, OSError):
        raise ConfigError(f"failed to build isolated OpenCode config from {config_home}/opencode.json.") from None
    return (json.dumps({"provider": {provider: picked}}, indent=2, ensure_ascii=False) + "\n").encode("utf-8", "replace")


def _fail_index() -> Any:
    raise _Bad


# ---------------------------------------------------------------- running the CLI

def parse_timeout(raw: str) -> float | None:
    """Seconds as GNU `timeout` reads them (a number and an optional s, m, h or d), None for no
    limit (0). Raises ValueError for anything `timeout` would refuse."""
    match = _TIMEOUT_RE.fullmatch(raw)
    if not match:
        raise ValueError(raw)
    seconds = float(match.group(1)) * _UNITS[match.group(2)]
    return min(seconds, MAX_TIMEOUT) if seconds > 0 else None


def _child_env(environ: Mapping[str, str], config_root: str) -> dict[str, str]:
    child = {k: v for k, v in environ.items() if v or k not in _WRAPPER_ONLY}
    child.pop("SHUNT_TRANSPORT", None)
    child["XDG_CONFIG_HOME"] = config_root
    return child


def _kill_group(proc: subprocess.Popen[bytes]) -> None:
    for sig, wait in ((signal.SIGTERM, TERM_GRACE_SECONDS), (signal.SIGKILL, None)):
        try:
            os.killpg(proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            proc.wait(timeout=wait or TERM_GRACE_SECONDS)  # bounded, a child in D state cannot hang us
        except subprocess.TimeoutExpired:
            continue
    try:
        os.killpg(proc.pid, signal.SIGKILL)  # whatever of the group outlived its leader
    except (ProcessLookupError, PermissionError):
        pass


@contextmanager
def _dies_with_us() -> Any:
    """SIGTERM and SIGHUP to this process end it through SystemExit, so the child is killed."""
    def handler(signum: int, _frame: Any) -> None:
        raise SystemExit(128 + signum)
    saved = {sig: signal.signal(sig, handler) for sig in (signal.SIGTERM, signal.SIGHUP)}
    try:
        yield
    finally:
        for sig, old in saved.items():
            signal.signal(sig, old)


def run_with_timeout(argv: list[str], environ: Mapping[str, str], stdout_fd: int, seconds: float | None) -> int:
    """Run argv with stdin and stderr on /dev/null and stdout on stdout_fd. 124 when the time ran out
    (the whole process group gets SIGTERM, then SIGKILL after a grace period), else its exit status."""
    proc = None
    try:
        with _dies_with_us():  # installed before the start, so no signal can orphan the child
            try:
                proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=stdout_fd, stderr=subprocess.DEVNULL,
                                        env=dict(environ), start_new_session=True, close_fds=True)
            except (OSError, ValueError):
                return 127
            try:
                code = proc.wait(timeout=seconds)
            except subprocess.TimeoutExpired:
                _kill_group(proc)
                return TIMEOUT
    finally:
        if proc is not None and proc.poll() is None:
            _kill_group(proc)
    return code if code >= 0 else 128 - code


def invoke(agent: str, question: str, files: Sequence[str], model_id: str, context_tokens: str,
           environ: Mapping[str, str]) -> str:
    """One call through the OpenCode CLI. Returns the normalized reply file, or raises Abort(status)
    with the reason already on stderr (TIMEOUT, ERROR, EMPTY, OVERSIZE, CONFIG)."""
    file_args: list[str] = []
    for path in files:
        file_args += ["-f", "./" + path if path.startswith("-") else path]  # not an option
    guard_size(agent, question, files, model_id, context_tokens)
    try:
        root = prepare_isolated_config(agent, environ)
    except ConfigError as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        raise reply.Abort(CONFIG) from None
    except OSError as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        raise reply.Abort(CONFIG) from None
    try:
        seconds = parse_timeout(environ.get("SHUNT_TIMEOUT_SECONDS") or DEFAULT_TIMEOUT)
    except ValueError:
        raise reply.Abort(ERROR) from None  # GNU timeout refused the value, the call never ran
    binary = environ.get("SHUNT_OPENCODE_BIN") or "opencode"
    argv = [binary, "run", "--agent", agent, question, *file_args, "--format", "json"]
    tmp = str(env.tmp_dir(environ))
    try:
        raw_fd, raw = tempfile.mkstemp(prefix=OUT_PREFIX, dir=tmp)
    except OSError:
        sys.stderr.write("shunt: cannot create a temp file for the opencode output.\n")
        raise reply.Abort(ERROR) from None
    try:
        try:
            status = run_with_timeout(argv, _child_env(environ, root), raw_fd, seconds)
        finally:
            os.close(raw_fd)
        if status == TIMEOUT:
            raise reply.Abort(TIMEOUT)
        if status != 0:
            raise reply.Abort(ERROR)
        if os.path.getsize(raw) == 0:
            raise reply.Abort(EMPTY)
        normalized = normalize_file(raw)
    finally:
        _unlink(raw)
    return _write_reply(tmp, normalized)


def _write_reply(directory: str, normalized: dict[str, Any]) -> str:
    """Write the normalized reply to a new 0600 file and return its path. On any failure the
    descriptor is closed and the file removed, and the call ends as ERROR."""
    out = ""
    fd = -1
    try:
        fd, out = tempfile.mkstemp(prefix=OUT_PREFIX, dir=directory)
        handle = os.fdopen(fd, "w", encoding="utf-8")
        fd = -1  # the file object owns it now
        with handle:
            handle.write(reply.dump(normalized))
    except OSError:
        if fd >= 0:
            os.close(fd)
        if out:
            _unlink(out)
        sys.stderr.write("shunt: cannot create a temp file for the opencode reply.\n")
        raise reply.Abort(ERROR) from None
    return out


def _unlink(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def register(subparsers: Any) -> None:
    """Add the `opencode` command group (prepare-config)."""
    group = subparsers.add_parser("opencode", help="the OpenCode CLI transport helpers")
    group.set_defaults(func=run)
    sub = group.add_subparsers(dest="opencode_command", required=True)
    sub.add_parser("prepare-config").add_argument("agent")


def run(args: argparse.Namespace) -> int:
    try:
        sys.stdout.write(prepare_isolated_config(args.agent, os.environ) + "\n")
    except ConfigError as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return 1
    except OSError as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return 1
    return 0
