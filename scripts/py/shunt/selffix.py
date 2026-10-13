"""Retry count of the code-write self-fix loop (replaces lib/selffix.sh).

Precedence: built-in default, then the config file's `self_fix_retries` (when present and
valid), then the SHUNT_CODE_WRITE_SELF_FIX_RETRIES value, which stays the emergency and
test override. A value counts only as a plain decimal of 1 to 15 digits (0 included), because
the number reaches bash arithmetic in the orchestration loop.
"""

import argparse
import json
import re
from typing import Any

DEFAULT_RETRIES = 1
_UINT = re.compile(r"[0-9]{1,15}")  # str.isdigit would accept non-ASCII digits


def _uint_or(value: object, fallback: int) -> int:
    """value as a count when it is a non-negative int or a digit string, else the fallback."""
    if isinstance(value, bool):
        return fallback
    text = str(value) if isinstance(value, int) else value
    if isinstance(text, str) and _UINT.fullmatch(text):
        return int(text)
    return fallback


def _config_value(config_file: str) -> object:
    try:
        with open(config_file, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    return data.get("self_fix_retries") if isinstance(data, dict) else None


def resolve_retries(config_file: str, env_value: str) -> int:
    """The retry count after the default, the config file and the env override."""
    from_config = _uint_or(_config_value(config_file), DEFAULT_RETRIES)
    return _uint_or(env_value, from_config)


def _run(args: argparse.Namespace) -> int:
    print(resolve_retries(args.config_file, args.env_value))
    return 0


def register(subparsers: Any) -> None:
    """Add the `selffix retries <config-file> <env-value>` command."""
    group = subparsers.add_parser("selffix", help="self-fix retry count of code-write")
    sub = group.add_subparsers(dest="selffix_command", required=True)
    parser = sub.add_parser("retries")
    parser.set_defaults(func=_run)
    parser.add_argument("config_file")
    parser.add_argument("env_value")
