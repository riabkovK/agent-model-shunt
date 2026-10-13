"""`scripts/usage-report`: summarizes the debug usage log (usage.jsonl) as JSON.

Port of the jq program the script used. The output text is the same: the same
keys in the same order, 2-space indent, groups sorted by key like jq group_by.
Numbers are added left to right as jq does (a float sum is not compensated).
"""

import json
import os
import sys
from collections.abc import Mapping, Sequence
from typing import Any

from . import env

COMMAND = "usage-report"
INVALID_LOG_EXIT = 2
TYPE_ERROR_EXIT = 5
DEFAULT_TOOL = "bulk-read"
NOTES = (
    "shunt: avoided_tokens_estimate is a chars/4 estimate of context Claude did not spend reading these files directly.",
    "shunt: avoided_output_tokens_estimate is a chars/4 estimate of the output Claude did not spend writing files that code-write generated.",
    "shunt: this does not include Claude's own actual token/dollar spend for the session - check that with Claude Code's own /cost.",
)


class ReportError(Exception):
    def __init__(self, message: str, code: int) -> None:
        super().__init__(message)
        self.code = code


def _alt(value: Any, default: Any) -> Any:
    """jq `value // default`: null and false fall back."""
    return default if value is None or value is False else value


def _slurp(text: str) -> list[Any]:
    """Every whitespace separated JSON value in the text, like `jq -s`."""
    decoder, values, pos = json.JSONDecoder(), [], 0
    while True:
        while pos < len(text) and text[pos] in " \t\r\n":
            pos += 1
        if pos >= len(text):
            return values
        try:
            value, pos = decoder.raw_decode(text, pos)
        except (ValueError, RecursionError) as exc:
            raise ReportError(f"shunt: the usage log is not valid JSON: {exc}", INVALID_LOG_EXIT) from None
        values.append(value)


def _add(values: Sequence[Any]) -> Any:
    """jq `add`: null is skipped, numbers are summed in order, other types are an error."""
    total: Any = None
    for value in values:
        if value is None:
            continue
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ReportError("shunt: the usage log has a field that is not a number.", TYPE_ERROR_EXIT)
        total = value if total is None else total + value
    if isinstance(total, float) and total.is_integer() and abs(total) < 1e17:
        return int(total)
    return total


def _field(entry: Any, name: str) -> Any:
    if not isinstance(entry, dict):
        raise ReportError("shunt: the usage log has an entry that is not an object.", TYPE_ERROR_EXIT)
    return entry.get(name)


def _tool(entry: Any) -> Any:
    return _alt(_field(entry, "tool"), DEFAULT_TOOL)


def model_label(entry: Any) -> Any:
    """The model id. A legacy entry has only the OpenCode agent name, which is not a model."""
    model = _alt(_field(entry, "model"), "")
    if model != "":
        return model
    agent = _alt(_field(entry, "agent"), "")
    if isinstance(agent, str) and "/" in agent:
        return agent
    return f"unknown (legacy OpenCode agent {_tojson_text(_alt(_field(entry, 'agent'), '?'))})"


def _tojson_text(value: Any) -> str:
    return value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _sort_key(value: Any) -> tuple[int, Any]:
    """jq ordering for the values a key can hold: null, false, true, numbers, strings."""
    if value is None:
        return (0, 0)
    if isinstance(value, bool):
        return (1 + int(value), 0)
    if isinstance(value, (int, float)):
        return (3, value)
    return (4, str(value))


def _groups(entries: Sequence[Any], key: Any) -> list[list[Any]]:
    keyed = sorted(((tuple(_sort_key(k) for k in key(e)), e) for e in entries), key=lambda pair: pair[0])
    groups: list[list[Any]] = []
    last: Any = object()
    for group_key, entry in keyed:
        if not groups or group_key != last:
            groups.append([])
            last = group_key
        groups[-1].append(entry)
    return groups


def _sums(rows: Sequence[Any], with_bytes: bool = False) -> dict[str, Any]:
    out = {
        "delegate_cost_usd": _add([_field(r, "delegate_cost_usd") for r in rows]),
        "avoided_tokens_estimate": _add([_field(r, "avoided_tokens_estimate") for r in rows]),
        "avoided_output_tokens_estimate": _add([_alt(_field(r, "avoided_output_tokens_estimate"), 0) for r in rows]),
    }
    if with_bytes:
        out["generated_bytes"] = _add([_alt(_field(r, "generated_bytes"), 0) for r in rows])
    return out


def summarize(entries: Sequence[Any]) -> dict[str, Any]:
    by_tool = [{"tool": _tool(g[0]), "calls": len(g), **_sums(g, True)}
               for g in _groups(entries, lambda e: [_tool(e)])]
    by_model = [{"model": model_label(g[0]), "tool": _tool(g[0]), "calls": len(g), **_sums(g)}
                for g in _groups(entries, lambda e: [_tool(e), model_label(e)])]
    return {
        "calls": len(entries),
        "delegate_input_tokens": _add([_field(e, "delegate_input_tokens") for e in entries]),
        "delegate_output_tokens": _add([_field(e, "delegate_output_tokens") for e in entries]),
        "delegate_cost_usd": _add([_field(e, "delegate_cost_usd") for e in entries]),
        "avoided_tokens_estimate": _add([_field(e, "avoided_tokens_estimate") for e in entries]),
        "avoided_output_tokens_estimate": _add([_alt(_field(e, "avoided_output_tokens_estimate"), 0) for e in entries]),
        "by_tool": by_tool,
        "by_model": by_model,
    }


def _log_path(argv: Sequence[str], environ: Mapping[str, str]) -> str:
    if argv and argv[0]:
        return argv[0]
    return environ.get("SHUNT_DEBUG_LOG_PATH") or str(env.cache_dir(environ) / "usage.jsonl")


def main(argv: Sequence[str], environ: Mapping[str, str] | None = None) -> int:
    environ = os.environ if environ is None else environ
    path = _log_path(argv, environ)
    try:
        empty = os.stat(path).st_size == 0
    except OSError:
        empty = True
    if empty:
        sys.stderr.write(f"shunt: no usage log at {path} (enable with SHUNT_DEBUG_LOG=1, see /usage-report skill).\n")
        return 1
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            report = summarize(_slurp(handle.read()))
    except ReportError as exc:
        sys.stderr.write(f"{exc}\n")
        return exc.code
    except OSError as exc:
        sys.stderr.write(f"shunt: cannot read the usage log {path}: {exc.strerror}\n")
        return 1
    sys.stdout.write(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    sys.stdout.flush()
    sys.stderr.write("\n" + "\n".join(NOTES) + "\n")
    return 0
