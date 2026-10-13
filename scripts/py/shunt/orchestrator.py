"""The orchestrator rule: a short delegation text assembled from skill fragments.

Port of scripts/lib/orchestrator.sh. Fragments are skills/*/orchestrator.md plus the
user's own *.md files. Fragment text is only parsed, sanitized and listed: the one
substitution is the literal token {{MIN_LINES}} (digits only), nothing is evaluated.

Fragment format: an optional first line `role: <name>`, then 1 to 6 bullet lines that
each start with `- `. Blank lines are ignored, anything else invalidates the fragment.
"""

import argparse
import os
import re
import stat
import sys
from collections.abc import Mapping
from pathlib import Path

from . import breaker, env, models
from .jsonio import read_capped

MAX_FILE_BYTES = 4096
MAX_LINE_CHARS = 160
MAX_BODY_CHARS = 600
MAX_BULLETS = 6
DEFAULT_MIN_LINES = "350"
MAX_MIN_LINES_DIGITS = 9
ROLE_MAX_CHARS = 32
MAX_USER_FRAGMENTS = 16
MAX_USER_CANDIDATES = 64
MAX_ANCESTORS = 64
MAX_RENDER_CHARS = 3000
HEADER = "Shunt delegation (cheap models; Claude keeps judgment)."
NO_MODELS_ROW = "No delegate models configured; run /model-config to set them up."
HOOKS_OFF_ROW = "Reads are not hook-gated; delegate by judgment only."
HOOKS_OFF_VALUES = ("1", "true", "TRUE", "yes", "YES")
TOKEN = "{{MIN_LINES}}"
PLUGIN_ROOT = str(Path(__file__).resolve().parents[3])
_ROLE_RE = re.compile(r"[a-z0-9-]+")
_WRITABLE = 0o022  # group or world write
_STICKY = 0o1000

# Control bytes dropped first (ESC and BEL stay for the ANSI pass): 0-6, 8, 11-26, 28-31, DEL.
_CONTROL = bytes([*range(0, 7), 8, *range(11, 27), *range(28, 32), 127])
_OSC_BEL = re.compile(rb"\x1b\][^\x1b\x07\n]*\x07")
_OSC_ST = re.compile(rb"\x1b\][^\x1b\x07\n]*\x1b\\")
_CSI = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]")
_ESC_PAIR = re.compile(rb"\x1b[@-Z\\-_]")
# Invisible or terminal-active code points: C1 controls, zero-width and bidi marks,
# line/paragraph separators, word joiners, BOM and the Unicode tag block.
_INVISIBLE = re.compile(rb"\xc2[\x80-\x9f]|\xe2\x80[\x8b-\x8f]|\xe2\x80[\xa8-\xae]|\xe2\x81[\xa0-\xaf]"
                        rb"|\xef\xbb\xbf|\xf3\xa0[\x80-\x81][\x80-\xbf]")


class Fragment:
    """A parsed, sanitized fragment: role (may be empty) and the bullet lines."""

    def __init__(self, role: str, lines: list[str]) -> None:
        self.role = role
        self.lines = lines

    @property
    def body(self) -> str:
        return "\n".join(self.lines)[:MAX_BODY_CHARS]


def min_lines(value: str | None) -> str:
    """value when it is a plain positive integer of at most 9 digits, else 350."""
    text = value or ""
    if not text.isascii() or not text.isdigit():
        return DEFAULT_MIN_LINES
    text = text.lstrip("0") or "0"  # 0007 is 7, and 0 is rejected below
    if len(text) > MAX_MIN_LINES_DIGITS or text == "0":
        return DEFAULT_MIN_LINES
    return text


def sanitize(data: bytes) -> bytes:
    """Strip ANSI sequences, CR, control bytes and invisible code points; tabs become spaces."""
    data = data.replace(b"\t", b" ").replace(b"\r", b"").translate(None, _CONTROL)
    for pattern in (_OSC_BEL, _OSC_ST, _CSI, _ESC_PAIR):
        data = pattern.sub(b"", data)
    data = data.translate(None, b"\x1b\x07")
    previous = None
    while previous != data:  # loop so a split sequence cannot reassemble after a removal
        previous = data
        data = _INVISIBLE.sub(b"", data)
    return data


def _read_fragment_bytes(path: str) -> bytes | None:
    """The file's bytes when it is a regular file of at most MAX_FILE_BYTES, else None."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    except (OSError, ValueError):
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        data = read_capped(fd, MAX_FILE_BYTES + 1)
    except OSError:
        return None
    finally:
        os.close(fd)
    return data if len(data) <= MAX_FILE_BYTES else None


def _parse_role(line: str) -> str | None:
    role = line[len("role: "):]
    if not _ROLE_RE.fullmatch(role) or role.startswith("-") or role.endswith("-"):
        return None
    return role if len(role) <= ROLE_MAX_CHARS else None


def load(path: str, min_lines_value: str | None = None) -> Fragment | None:
    """Parse and sanitize one fragment, or None when the file is unusable or invalid."""
    raw = _read_fragment_bytes(path)
    if raw is None:
        return None
    limit = min_lines(min_lines_value)
    text = sanitize(raw).decode("utf-8", errors="replace")
    role = ""
    out: list[str] = []
    first = True
    for line in text.split("\n"):
        if not line.strip(" "):
            continue
        if first:
            first = False
            if line.startswith("role: "):
                parsed = _parse_role(line)
                if parsed is None:
                    return None
                role = parsed
                continue
        if not line.startswith("- "):
            return None
        if len(out) >= MAX_BULLETS:
            return None
        out.append(line.replace(TOKEN, limit)[:MAX_LINE_CHARS])
    return Fragment(role, out) if out else None


# ---------------------------------------------------------------- listing

def user_dir(environ: Mapping[str, str]) -> str:
    """SHUNT_ORCHESTRATOR_DIR, else <XDG_CONFIG_HOME or $HOME/.config>/agent-model-shunt/orchestrator.d."""
    explicit = environ.get("SHUNT_ORCHESTRATOR_DIR")
    if explicit:
        return explicit
    config = environ.get("XDG_CONFIG_HOME") or (environ.get("HOME", "") + "/.config")
    return config + "/agent-model-shunt/orchestrator.d"


def _is_loose(path: str, sticky_ok: bool = False) -> bool:
    """True when path (symlinks followed) is group or world writable. A sticky dir may be exempt."""
    try:
        mode = os.stat(path).st_mode
    except (OSError, ValueError):
        return False
    if not mode & _WRITABLE:
        return False
    return not (sticky_ok and mode & _STICKY)


def dir_trusted(directory: str) -> bool:
    """True for an absolute directory we own, not shared, under no shared non-sticky ancestor.

    Fragments are injected as trusted rules. Ancestors are walked textually and judged through
    "<ancestor>/." so a symlinked ancestor is judged by its target. A deeper walk is refused.
    """
    if not directory.startswith("/"):
        return False
    try:
        info = os.stat(directory)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or not os.access(directory, os.R_OK):
            return False
        if os.path.islink(directory[:-1] if directory.endswith("/") else directory):
            return False  # a symlink leaf would skip the walk of its target's real parents
    except (OSError, ValueError):
        return False
    if info.st_mode & _WRITABLE:
        return False
    current = directory
    for _ in range(MAX_ANCESTORS + 1):
        if current == "/":
            return True
        current = current.rpartition("/")[0] or "/"
        if _is_loose(current + "/.", sticky_ok=True):
            return False
    return False


def _user_fragments(environ: Mapping[str, str]) -> list[str]:
    directory = user_dir(environ)
    if not dir_trusted(directory):
        return []
    try:
        names = sorted(os.listdir(directory), key=os.fsencode)
    except OSError:
        return []
    kept: list[str] = []
    seen = 0
    for name in names:
        if not name.endswith(".md") or name.startswith(".") or "\n" in name:
            continue
        path = directory + "/" + name
        try:
            info = os.lstat(path)
        except OSError:
            continue
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & _WRITABLE:
            continue
        seen += 1
        if load(path) is not None:
            kept.append(path)
            if len(kept) >= MAX_USER_FRAGMENTS:
                break
        if seen >= MAX_USER_CANDIDATES:
            break
    return kept


def _builtin_fragments(root: str, overridden: set[str]) -> list[str]:
    try:
        skills = sorted(os.listdir(root + "/skills"), key=os.fsencode)
    except (OSError, ValueError):
        return []
    found = []
    for name in skills:
        path = f"{root}/skills/{name}/orchestrator.md"
        if name.startswith(".") or "\n" in path or (name + ".md") in overridden:
            continue
        if os.path.exists(path):
            found.append(path)
    return found


def list_fragments(environ: Mapping[str, str], root: str = PLUGIN_ROOT) -> list[str]:
    """Built-ins (sorted), then valid user fragments (sorted). A user <skill-dir>.md replaces a built-in."""
    users = _user_fragments(environ)
    overridden = {os.path.basename(u) for u in users}
    return (sorted(_builtin_fragments(root, overridden), key=os.fsencode)
            + sorted(users, key=os.fsencode))


# ---------------------------------------------------------------- rendering

def _role_state(environ: Mapping[str, str], role: str) -> str:
    """ready, unavailable or open. RegistryUnreadable propagates."""
    _unknown, ids = models.candidates(env.models_file_text(environ), role)
    if not ids:
        return "unavailable"
    return "ready" if breaker.any_closed(environ, ids) else "open"


def _state_row(role: str, state: str) -> str:
    if state == "unavailable":
        return f"{role}: unavailable, handle directly."
    return f"{role}: breaker open, handle directly until cooldown."


def _cap_rows(rows: list[str]) -> str:
    out: list[str] = []
    total = 0
    for row in rows:
        total += len(row) + 1
        if total > MAX_RENDER_CHARS:
            break
        out.append(row + "\n")
    return "".join(out)


def render(environ: Mapping[str, str], root: str = PLUGIN_ROOT) -> str | None:
    """The delegation rule as plain text, or None when the registry exists but cannot be read.

    Only fixed state strings and fragment text are printed, never a model id or name.
    """
    limit = min_lines(environ.get("SHUNT_MIN_LINES"))
    path = env.models_file_text(environ)
    rows = [HEADER]
    if not models.available(path):
        if os.path.exists(path):
            return None  # present but invalid is an error, a missing registry is a setup hint
        rows.append(NO_MODELS_ROW)
        return _cap_rows(rows)
    if environ.get("SHUNT_HOOKS_DISABLED") in HOOKS_OFF_VALUES:
        rows.append(HOOKS_OFF_ROW)
    states: dict[str, str] = {}
    stated: set[str] = set()
    for fragment_path in list_fragments(environ, root):
        fragment = load(fragment_path, limit)
        if fragment is None or (fragment.role and fragment.role not in models.ROLES):
            continue
        role = fragment.role
        if role and role not in states:
            try:
                states[role] = _role_state(environ, role)
            except models.RegistryUnreadable:
                return None
        state = states.get(role, "ready")
        if state == "ready":
            rows.extend(fragment.body.split("\n"))
        elif role not in stated:
            stated.add(role)
            rows.append(_state_row(role, state))
    return _cap_rows(rows)


# ---------------------------------------------------------------- command line

def _print_fragment(path: str, limit: str | None, what: str) -> int:
    fragment = load(path, limit)
    if fragment is None:
        return 1
    sys.stdout.write((fragment.role if what == "role" else fragment.body) + "\n")
    return 0


def run(args: argparse.Namespace) -> int:
    cmd = args.orchestrator_command
    if cmd == "min-lines":
        print(min_lines(args.value))
        return 0
    if cmd in ("role", "body"):
        return _print_fragment(args.file, args.min_lines, cmd)
    if cmd == "list":
        for path in list_fragments(os.environ, args.root or PLUGIN_ROOT):
            sys.stdout.write(path + "\n")
        return 0
    text = render(os.environ, args.root or PLUGIN_ROOT)
    if text is None:
        return 1
    sys.stdout.write(text)
    return 0


def register(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser("orchestrator", help="fragments of the session-start delegation rule")
    sub = parser.add_subparsers(dest="orchestrator_command", required=True)
    sub.add_parser("min-lines").add_argument("value", nargs="?", default="")
    for name in ("role", "body"):
        cmd = sub.add_parser(name)
        cmd.add_argument("file")
        cmd.add_argument("min_lines", nargs="?", default=None)
    for name in ("list", "render"):
        sub.add_parser(name).add_argument("root", nargs="?", default=None)
    parser.set_defaults(func=run)
