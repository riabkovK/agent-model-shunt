"""scripts/bulk-read in one process: arguments, the failover call, the answer, the usage line, the log.

The bash script spawned a process for each of the preflight, the failover loop, the text, the usage
summary and the log line. Here they are function calls. Usage:

    shunt_main.py bulk-read -- --question "..." --paths FILE [FILE ...]

Output and exit codes are those of the script: the answer on stdout, `shunt: bulk-read usage: ...` on
stderr, a `shunt:` line and exit 1 for a usage error or a failed call. Only the OpenCode binary is
checked up front (`jq` and `timeout` are not used any more).
"""

from __future__ import annotations

import os
import shutil
import sys
from collections.abc import Mapping, Sequence
from typing import NoReturn

from . import failover, usage_log

COMMAND = "bulk-read"
DEFAULT_OPENCODE_BIN = "opencode"
DEFAULT_LEGACY_AGENT = "bulk-reader"
_DEBUG_TRUE = ("1", "true", "TRUE", "yes", "YES")


class UsageError(Exception):
    """A `shunt:` line and exit status 1 before anything is delegated."""


def _fail(message: str) -> NoReturn:
    raise UsageError(message)


def parse_args(argv: Sequence[str]) -> tuple[str, list[str]]:
    """--question VALUE and --paths FILE... (up to the next word starting with `--`), like the script."""
    question = ""
    paths: list[str] = []
    rest = list(argv)
    while rest:
        arg = rest.pop(0)
        if arg == "--question":
            if not rest:
                _fail("--question requires a value.")
            question = rest.pop(0)
        elif arg == "--paths":
            while rest and not rest[0].startswith("--"):
                paths.append(rest.pop(0))
        else:
            _fail(f"unknown argument: {arg}")
    if not question:
        _fail("--question is required.")
    if not paths:
        _fail("--paths requires at least one file.")
    for path in paths:
        if not os.path.isfile(path):
            _fail(f"file not found: {path}")
        if not os.access(path, os.R_OK):
            _fail(f"file not readable: {path}")
    return question, paths


def preflight(environ: Mapping[str, str]) -> None:
    binary = environ.get("SHUNT_OPENCODE_BIN") or DEFAULT_OPENCODE_BIN
    if shutil.which(binary) is None:
        _fail(f"'{binary}' not found in PATH. Install OpenCode (https://opencode.ai) or set SHUNT_OPENCODE_BIN.")


def debug_log_enabled(environ: Mapping[str, str]) -> bool:
    return environ.get("SHUNT_DEBUG_LOG", "") in _DEBUG_TRUE


def _unlink(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def run(argv: Sequence[str], environ: Mapping[str, str]) -> int:
    try:
        question, paths = parse_args(argv)
        preflight(environ)
    except UsageError as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return 1
    legacy = environ.get("SHUNT_BULK_READER_AGENT") or DEFAULT_LEGACY_AGENT
    chosen: list[str] = []

    def call() -> int:
        chosen.extend(failover.select_bulk(legacy, question, paths, environ))
        return 0

    status = failover.guarded(call)
    if status:
        return status
    out_file, used_agent = chosen
    text = usage_log.extract_text(out_file)
    if not text:
        sys.stderr.write("shunt: could not extract assistant text from the delegate response "
                         f"(normalized response kept at {out_file} for inspection).\n")
        return 1
    usage = usage_log.extract_usage(out_file)
    try:
        sys.stdout.write(text + "\n")
        sys.stdout.flush()
        if usage:
            sys.stderr.write(f"shunt: bulk-read usage: {usage}\n")
        if debug_log_enabled(environ):
            usage_log.log_usage(used_agent, out_file, question, paths, environ)
    finally:
        _unlink(out_file)
    return 0


def main(argv: Sequence[str]) -> int:
    """Entry for `bulk-read -- args`: one leading `--` separates the command from the script's arguments."""
    args = list(argv)
    if args[:1] == ["--"]:
        args.pop(0)
    return run(args, os.environ)
