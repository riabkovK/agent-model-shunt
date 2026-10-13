"""Readers of the normalized response and the debug usage log.

Port of shunt_extract_text, shunt_extract_usage, shunt_extract_finish_reason, shunt_log_usage and
shunt_log_code_write of scripts/lib/opencode.sh. The log line format (key order included) is read by
scripts/usage-report. Logging is a debug aid and never fails the caller.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections.abc import Mapping, Sequence
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import env
from . import transport_reply as reply
from .jsonio import JsonReadError, read_json

_MODEL_LINE = re.compile(r"model:[ \t]*([^ \t].*)")
_TRAILING = re.compile(r"[ \t\r]+$")


def _alt(value: Any, default: Any) -> Any:
    return default if value is None or value is False else value


def _tostring(value: Any) -> str:
    """jq's tostring: integral floats lose the .0, strings are not quoted."""
    if isinstance(value, str):
        return value
    if isinstance(value, float) and value.is_integer() and abs(value) < 1e17:
        return str(int(value))
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _load(path: str) -> Any:
    try:
        return read_json(path)
    except (JsonReadError, OSError, ValueError):
        return None


def extract_text(path: str) -> str:
    """The answer text, without trailing newlines. Empty when there is none."""
    doc = _load(path)
    value = _alt(doc.get("text") if isinstance(doc, dict) else None, "")
    return _tostring(value).replace("\0", "").rstrip("\n")


def extract_usage(path: str) -> str:
    """"input=N output=N cost=N", or "" when the response reported no usage."""
    doc = _load(path)
    if not isinstance(doc, dict) or doc.get("usage") is None:
        return ""
    usage = doc["usage"]
    if not isinstance(usage, dict):
        return ""
    return (f"input={_tostring(_alt(usage.get('input'), 0))} output={_tostring(_alt(usage.get('output'), 0))}"
            f" cost={_tostring(_alt(doc.get('cost'), 0))}")


def extract_finish_reason(path: str) -> str:
    doc = _load(path)
    return _tostring(_alt(doc.get("finish_reason") if isinstance(doc, dict) else None, ""))


# ---------------------------------------------------------------- the usage log

def _files_entries(files: Sequence[str]) -> list[dict[str, Any]]:
    entries = []
    for path in files:
        try:
            with open(path, "rb") as handle:
                size = lines = 0
                while chunk := handle.read(1 << 16):
                    size, lines = size + len(chunk), lines + chunk.count(b"\n")
        except OSError:
            continue
        entries.append({"path": path, "lines": lines, "bytes": size})
    return entries


def log_model(agent: str, environ: Mapping[str, str]) -> str:
    """The model id of a logged call: an id with a "/" as it is, else the `model:` line of the
    agent's file (shunt-owned agents first, then the legacy OpenCode agents). "" when not found."""
    if "/" in agent:
        return agent
    agents = environ.get("SHUNT_AGENTS_DIR") or str(env.agents_dir(environ))
    config_home = environ.get("SHUNT_OPENCODE_CONFIG_HOME") or str(env.opencode_config_home(environ))
    for path in (Path(agents) / f"{agent}.md", Path(config_home) / "agents" / f"{agent}.md"):
        if not path.is_file():
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8", errors="surrogateescape").split("\n"), 1):
            if (number == 1 and line != "---") or (number > 1 and line == "---"):
                return ""
            match = _MODEL_LINE.match(line)
            if match:
                return _TRAILING.sub("", match.group(1))
        return ""
    return ""


def _response_usage(path: str) -> dict[str, Any]:
    doc = _load(path)
    usage = doc.get("usage") if isinstance(doc, dict) else None
    if not isinstance(doc, dict) or not isinstance(_alt(usage, {}), dict):
        return {"input": 0, "output": 0, "cost": 0}
    usage = _alt(usage, {})
    return {"input": _alt(usage.get("input"), 0), "output": _alt(usage.get("output"), 0),
            "cost": _alt(doc.get("cost"), 0)}


def _append(agent: str, resp: str, question: str, entries: list[dict[str, Any]], avoided: int,
            extra: dict[str, Any], environ: Mapping[str, str]) -> None:
    log_path = environ.get("SHUNT_DEBUG_LOG_PATH") or str(env.cache_dir(environ) / "usage.jsonl")
    try:
        model = log_model(agent, environ)
    except OSError:
        model = ""
    usage = _response_usage(resp)
    entry = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "agent": agent,
        "model": model or None,
        "files": entries,
        "question_chars": len(question),
        "delegate_input_tokens": usage["input"],
        "delegate_output_tokens": usage["output"],
        "delegate_cost_usd": usage["cost"],
        "avoided_tokens_estimate": avoided,
        **extra,
    }
    try:
        os.makedirs(os.path.dirname(log_path) or ".", exist_ok=True)
        fd = os.open(log_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o666)
        try:
            os.write(fd, reply.dump(entry).encode("utf-8"))
        finally:
            os.close(fd)
    except (OSError, ValueError):
        return


def log_usage(agent: str, resp: str, question: str, files: Sequence[str], environ: Mapping[str, str]) -> None:
    """A bulk-read call: its real usage and a chars/4 estimate of the tokens Claude did not read."""
    entries = _files_entries(files)
    avoided = sum((e["bytes"] + 3) // 4 for e in entries)
    _append(agent, resp, question, entries, avoided, {"tool": "bulk-read"}, environ)


def log_code_write(agent: str, resp: str, spec: str, generated_bytes: int, files: Sequence[str],
                   environ: Mapping[str, str]) -> None:
    """A code-write call: what delegating saves is Claude's output, a chars/4 estimate over the bytes."""
    extra = {"tool": "code-write", "generated_bytes": generated_bytes,
             "avoided_output_tokens_estimate": (generated_bytes + 3) // 4}
    _append(agent, resp, spec, _files_entries(files), 0, extra, environ)


# ---------------------------------------------------------------- command line

def _run(args: argparse.Namespace) -> int:
    cmd = args.usage_command
    if cmd == "text":
        text = extract_text(args.file)
        if not text:
            sys.stderr.write("shunt: could not extract assistant text from the delegate response "
                             f"(normalized response kept at {args.file} for inspection).\n")
            return 1
        sys.stdout.write(text + "\n")
    elif cmd == "summary":
        line = extract_usage(args.file)
        if line:
            sys.stdout.write(line + "\n")
    elif cmd == "finish-reason":
        reason = extract_finish_reason(args.file)
        if reason:
            sys.stdout.write(reason + "\n")
    elif cmd == "log-bulk":
        log_usage(args.agent, args.file, args.question, args.files, os.environ)
    elif cmd == "log-code-write":
        try:
            generated = int(args.generated_bytes)
        except ValueError:
            return 0
        log_code_write(args.agent, args.file, args.question, generated, args.files, os.environ)
    return 0


def register(subparsers: Any) -> None:
    """Add the `usage` command group."""
    group = subparsers.add_parser("usage", help="read a normalized response, append to the usage log")
    group.set_defaults(func=_run)
    sub = group.add_subparsers(dest="usage_command", required=True)
    for name in ("text", "summary", "finish-reason"):
        sub.add_parser(name).add_argument("file")
    bulk = sub.add_parser("log-bulk")
    code = sub.add_parser("log-code-write")
    for parser, middle in ((bulk, ()), (code, ("generated_bytes",))):
        for arg in ("agent", "file", "question", *middle):
            parser.add_argument(arg)
        parser.add_argument("files", nargs="*")
