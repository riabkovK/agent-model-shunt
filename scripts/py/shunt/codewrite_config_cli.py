"""shunt-codewrite-config: show and change the code-write self-fix retry count.

The write side of code-write-self-fix-config.json (SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE).
The launcher scripts/shunt-codewrite-config only starts this module. Output lines and
exit codes are documented in skills/code-writer/SKILL.md: 0 on success, 1 on a usage
error or a failed write, with a `shunt:` line on stderr.
"""

import os
import re
import sys
from collections.abc import Mapping, Sequence

from . import env, selffix
from .models import ShuntError

COMMAND = "shunt-codewrite-config"
_COUNT = re.compile(r"[0-9]{1,15}")  # same cap as selffix: the value reaches bash arithmetic


class CliError(Exception):
    """A refusal that prints one `shunt:` line and exits 1."""


def _say(text: str) -> None:
    sys.stdout.write(text + "\n")


def cmd_show(environ: Mapping[str, str]) -> None:
    retries = selffix.resolve_retries(str(env.self_fix_config_file(environ)), environ.get("SHUNT_CODE_WRITE_SELF_FIX_RETRIES", ""))
    _say(f"self_fix_retries={retries} (default: {selffix.DEFAULT_RETRIES})")


def cmd_set(environ: Mapping[str, str], args: Sequence[str]) -> None:
    field = args[0] if args else ""
    value = args[1] if len(args) > 1 else ""
    if field != "self-fix-retries":
        raise CliError("usage: shunt-codewrite-config set self-fix-retries <value>")
    if not _COUNT.fullmatch(value):
        raise CliError("self-fix-retries must be a non-negative integer.")
    selffix.set_retries(str(env.self_fix_config_file(environ)), int(value))
    _say(f"shunt: self-fix retry count set to {value}.")


def cmd_reset(environ: Mapping[str, str]) -> None:
    env.self_fix_config_file(environ).unlink(missing_ok=True)
    _say("shunt: self-fix config reset to hardcoded defaults.")


def _dispatch(environ: Mapping[str, str], argv: Sequence[str]) -> None:
    if not argv or not argv[0]:
        raise CliError("usage: shunt-codewrite-config <show|set|reset> [args...]")
    command, rest = argv[0], argv[1:]
    if command == "show":
        cmd_show(environ)
    elif command == "set":
        cmd_set(environ, rest)
    elif command == "reset":
        cmd_reset(environ)
    else:
        raise CliError(f"unknown subcommand: {command}")


def main(argv: Sequence[str]) -> int:
    try:
        _dispatch(os.environ, argv)
    except BrokenPipeError:
        raise
    except (CliError, ShuntError, OSError, UnicodeError, ValueError) as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return 1
    return 0
