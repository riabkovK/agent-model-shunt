"""shunt-breaker-config: show and change the circuit breaker config.

The write side of breaker-config.json (SHUNT_BREAKER_CONFIG_FILE). The launcher
scripts/shunt-breaker-config only starts this module. Output lines and exit codes
are documented in skills/model-config/reference.md: 0 on success, 1 on a usage
error or a failed write, with a `shunt:` line on stderr.
"""

import os
import re
import sys
from collections.abc import Mapping, Sequence

from . import breaker, env, models, probe
from .models import ShuntError

COMMAND = "shunt-breaker-config"
_DIGITS = re.compile(r"[0-9]+")
_CODE_WRITE = "code-write"


class CliError(Exception):
    """A refusal that prints one `shunt:` line and exits 1."""


def _say(text: str) -> None:
    sys.stdout.write(text + "\n")


def _model_ids(environ: Mapping[str, str]) -> list[str]:
    try:
        lines, _code = probe.ask(environ, "model-ids")
    except (ValueError, OSError):
        return []
    return [line for line in lines if line]


def _has_code_write(path: str, model_id: str) -> bool:
    try:
        return models.has_role(path, model_id, _CODE_WRITE)
    except (ShuntError, ValueError, OSError):
        return False


def cmd_show(environ: Mapping[str, str]) -> None:
    threshold, cooldown = breaker.limits(environ)
    _say(f"threshold={threshold} (default: {breaker.DEFAULT_THRESHOLD})")
    _say(f"cooldown_seconds={cooldown} (default: {breaker.DEFAULT_COOLDOWN})")
    if threshold >= breaker.DISABLED_THRESHOLD:
        _say("status: disabled (threshold effectively unreachable)")
    models_file = env.models_file_text(environ)
    if not models.available(models_file):
        _say(f"shunt: circuit breaker not applicable (no models registry at {models_file}; legacy single-agent mode).")
        return
    _say("---")
    for model_id in _model_ids(environ):
        _say(f"{model_id}: {breaker.status(environ, model_id)}")
        if _has_code_write(models_file, model_id):
            key = f"{model_id}#{_CODE_WRITE}"
            _say(f"{model_id} ({_CODE_WRITE}): {breaker.status(environ, key)}")


def cmd_set(environ: Mapping[str, str], args: Sequence[str]) -> None:
    field = args[0] if args else ""
    value = args[1] if len(args) > 1 else ""
    if field == "threshold":
        if not _DIGITS.fullmatch(value) or int(value) < 1:
            raise CliError("threshold must be a positive integer.")
        breaker.set_threshold(environ, value)
        _say(f"shunt: breaker threshold set to {value}.")
    elif field == "cooldown":
        if not _DIGITS.fullmatch(value):
            raise CliError("cooldown must be a non-negative integer.")
        breaker.set_cooldown(environ, value)
        _say(f"shunt: breaker cooldown set to {value}s.")
    else:
        raise CliError("usage: shunt-breaker-config set <threshold|cooldown> <value>")


def cmd_reset(environ: Mapping[str, str]) -> None:
    env.breaker_config_file(environ).unlink(missing_ok=True)
    _say("shunt: breaker config reset to hardcoded defaults.")


def _dispatch(environ: Mapping[str, str], argv: Sequence[str]) -> None:
    if not argv or not argv[0]:
        raise CliError("usage: shunt-breaker-config <show|set|disable|reset> [args...]")
    command, rest = argv[0], argv[1:]
    if command == "show":
        cmd_show(environ)
    elif command == "set":
        cmd_set(environ, rest)
    elif command == "disable":
        breaker.disable(environ)
        _say("shunt: circuit breaker disabled (threshold set to an unreachable value).")
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
