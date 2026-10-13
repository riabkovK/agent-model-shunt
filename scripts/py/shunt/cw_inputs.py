"""The project root and the input files of code-write: what may be attached and what may be written under.

Port of shunt_cw_project_root (the git lookup stays an external `git rev-parse`, as before),
cw_check_project_root, cw_check_input_file and the rest of cw_validate_args.
"""

from __future__ import annotations

import os
import re
import subprocess
from collections.abc import Mapping

from . import cw_target, cw_text
from .cw_args import Args, TEST_RULES_FILE
from .cw_io import Stop, clean, fail, quote

DEFAULT_MAX_ATTACH_BYTES = 2097152
_VIRTUAL_FS = ("/proc/", "/sys/", "/dev/")
_GIT_SECONDS = 30
_GIT_ENV_NAMES = frozenset(("PATH", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "PWD", "XDG_CONFIG_HOME"))
_DIGITS = re.compile(r"[0-9]+")


def _git_env(environ: Mapping[str, str]) -> dict[str, str]:
    """What git needs and nothing else, so a key the operator exported never reaches the child."""
    return {name: value for name, value in environ.items()
            if name in _GIT_ENV_NAMES or name.startswith(("LC_",))}


def _git_top_level(environ: Mapping[str, str]) -> str:
    try:
        done = subprocess.run(["git", "rev-parse", "--show-toplevel"], stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=_git_env(environ),
                              timeout=_GIT_SECONDS, check=False)
    except (OSError, subprocess.SubprocessError):
        return ""
    if done.returncode != 0:
        return ""
    return os.fsdecode(done.stdout).rstrip("\n")


def project_root(environ: Mapping[str, str]) -> str:
    """The canonical root: CLAUDE_PROJECT_DIR when it is a directory, else the git top level, else
    the current directory. A root that is the cwd fallback is refused when a component of its path
    is on the short root list or is a sensitive name (the target rule only looks below the root)."""
    chosen = environ.get("CLAUDE_PROJECT_DIR", "")
    from_cwd = False
    if not (chosen and os.path.isdir(chosen)):
        chosen = _git_top_level(environ)
        if not chosen or not os.path.isdir(chosen):
            chosen, from_cwd = os.getcwd(), True
    canon = cw_target.canon_dir(os.fsencode(chosen))
    if canon is None:
        raise Stop(f"shunt: cannot resolve the project root '{chosen}'.")
    if from_cwd:
        hit = cw_target.root_denied_hit(canon)
        if hit is not None:
            shown_root = quote(cw_text.strip_invisible(canon))
            shown_hit = quote(cw_text.strip_invisible(hit))
            raise Stop("shunt: refusing to write: there is no git work tree here, so the project root would be "
                       f"the current directory {shown_root}, and its path has the component {_in_quotes(shown_hit)} "
                       "(git, CI, tool config or credential directories are off limits). Run code-write inside "
                       "a git work tree or export CLAUDE_PROJECT_DIR=<your project directory>.")
    return os.fsdecode(canon)


def _in_quotes(shown: str) -> str:
    return f"'{shown}'"


def check_project_root(root: str, environ: Mapping[str, str]) -> None:
    """Refuses a root that would make too much writable: / , the home directory or an ancestor of it."""
    home = environ.get("HOME", "")
    canon = cw_target.canon_dir(os.fsencode(home)) if home else None
    home_dir = os.fsdecode(canon) if canon is not None else ""
    if root == "/":
        raise fail("refusing to write: the project root would be / . Run code-write from inside a "
                   "project, a git repository.")
    if (home_dir + "/").startswith(root + "/"):
        raise fail(f"refusing to write: the project root would be {clean(root)}, the home directory or an "
                   "ancestor of it. Run code-write from inside a project, a git repository.")


def _resolve(path: str) -> str:
    try:
        return os.fsdecode(os.path.realpath(os.fsencode(path)))
    except (OSError, ValueError):
        return ""


def _relative_to_root(path: str, root: str) -> str:
    prefix = root + "/"
    return path[len(prefix):] if path.startswith(prefix) else path


def _sensitive(path: str, root: str) -> str | None:
    hit = cw_target.sensitive_component(os.fsencode(_relative_to_root(path, root)))
    return None if hit is None else os.fsdecode(hit)


def check_input_file(path: str, root: str, builtin: str, allow_outside: bool) -> None:
    """Refuses a path that is not a readable regular file, cannot be resolved, lives in a virtual
    filesystem, names a credential or key store (as given or resolved) or resolves outside the
    root without --allow-outside. The built-in test rules file is exempt from the last two."""
    if cw_text.has_unsafe_chars(os.fsencode(path)):
        raise fail("an input file path contains a control character or an invisible Unicode character.")
    if not os.path.isfile(path):
        raise fail(f"file not found: {path}")
    if not os.access(path, os.R_OK):
        raise fail(f"file not readable: {path}")
    resolved = _resolve(path)
    if not resolved:
        raise fail(f"refusing input file {path}: cannot resolve its symlinks, so it cannot be checked.")
    if resolved.startswith(_VIRTUAL_FS):
        raise fail(f"refusing input file {path}: it resolves into a virtual filesystem ({clean(resolved)}).")
    if builtin and resolved == builtin:
        return
    hit = _sensitive(path, root) or _sensitive(resolved, root)
    if hit is not None:
        raise fail(f"refusing input file {path}: '{clean(hit)}' looks like a sensitive file (credentials, keys, "
                   ".env, history, tool config), and input files are sent to the delegate model's provider.")
    if not allow_outside and not resolved.startswith(root + "/"):
        raise fail(f"refusing input file {path}: it resolves to {clean(resolved)}, outside the project root "
                   f"({clean(root)}). Pass --allow-outside to attach files from outside the project.")


def max_attach_bytes(environ: Mapping[str, str]) -> int:
    value = environ.get("SHUNT_CW_MAX_ATTACH_BYTES", "")
    return int(value) if _DIGITS.fullmatch(value) else DEFAULT_MAX_ATTACH_BYTES


def check_inputs(args: Args, root: str, environ: Mapping[str, str]) -> None:
    """Every input file, then the total size."""
    builtin = _resolve(TEST_RULES_FILE) if os.path.exists(TEST_RULES_FILE) else ""
    total = 0
    for path in args.inputs:
        check_input_file(path, root, builtin, args.allow_outside)
        total += os.stat(path).st_size
    cap = max_attach_bytes(environ)
    if total > cap:
        raise fail(f"the attached files are too large ({total} bytes, the cap is {cap}). "
                   "Attach fewer or smaller files.")
