"""`codewrite` command group: the bash side of code-write calls these (scripts/lib/codewrite.sh).

Exit codes: 0 for a hit or an answer, 1 for a refusal, 10 for "no hit" of a yes/no
check (unsafe, sensitive, root-hit), 2 for an internal error. The bash wrappers
treat any other status of a yes/no check as a hit (fail closed). Text and paths come in as argv and
go out as the exact bytes, never re-encoded.
"""

import os
import sys
from typing import Any

from . import cw_parse, cw_publish, cw_target, cw_text

INTERNAL_ERROR = 2
NONE = 10  # "no hit" of a yes/no check; 1 is what a crashing interpreter may exit with
_FILE_CHECKS = {
    "check-text": cw_text.check_text,
    "check-controls": cw_text.check_code_controls,
    "check-invisible": cw_text.check_invisible,
    "check-tags": cw_text.check_protocol_tags,
}
_TEXT_ARGS = {  # sub command -> positional names
    "strip-invisible": ("text",), "unsafe": ("text",), "sensitive": ("path",), "canon-dir": ("path",),
    "root-hit": ("path",), "limit": ("value", "default"), "placement": ("root", "canon", "tail"),
    "resolve": ("root", "target"), "normalize": ("path",), "parse": ("response", "out_dir"),
    "check-code-file": ("code_file",), "stage-tmp": ("root", "directory", "final_name", "code_file", "tmp_name"),
    "link": ("directory", "tmp_name", "final_name"),
}
_STAGES = ("stage-tmp", "link")
_MAKE_DIRS = "make-dirs"  # ancestor, then one or more names


def _out(data: bytes) -> None:
    sys.stdout.flush()
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def _line(data: bytes | str) -> None:
    _out((data if isinstance(data, bytes) else data.encode(errors="surrogateescape")) + b"\n")


def _refusal(exc: cw_target.Refusal) -> int:
    _line(str(exc))
    return 1


def _resolve(args: list[bytes]) -> int:
    try:
        found = cw_target.resolve(args[0], args[1])
    except cw_target.Refusal as exc:
        return _refusal(exc)
    for item in (found.root, found.ancestor, found.resolved, *found.missing):
        _line(item)
    return 0


def _placement(args: list[bytes]) -> int:
    try:
        cw_target.check_placement(*args)
    except cw_target.Refusal as exc:
        return _refusal(exc)
    return 0


def _answer(value: bytes | None) -> int:
    if value is None:
        return NONE
    _line(value)
    return 0


def _canon_dir(args: list[bytes]) -> int:
    return _answer(cw_target.canon_dir(args[0]))


def _limit(args: list[bytes]) -> int:
    default = int(args[1].decode())
    _line(str(cw_text.limit(os.fsdecode(args[0]), default)))
    return 0


def _strip(args: list[bytes]) -> int:
    _out(cw_text.strip_invisible(args[0]))
    return 0


def _parse(args: list[bytes]) -> int:
    reason, status = cw_parse.parse(args[0], args[1])
    _line(reason)
    return status


def _check_code_file(args: list[bytes]) -> int:
    message = cw_publish.check_code_file(args[0])
    if message:
        _line(message)
    return 1 if message else 0


def _make_dirs(args: list[bytes]) -> int:
    final, created = cw_publish.make_dirs(args[0], args[1:])
    for item in (final, *created):
        _line(item)
    return 0


def _stage_tmp(args: list[bytes]) -> int:
    _line(cw_publish.stage_tmp(*args))
    return 0


def _link(args: list[bytes]) -> int:
    return 0 if cw_publish.link_no_clobber(*args) else 1


_HANDLERS = {
    "normalize": lambda args: _answer(cw_parse.normalize_path(args[0])),
    "parse": _parse,
    "check-code-file": _check_code_file,
    "stage-tmp": _stage_tmp,
    "link": _link,
    "strip-invisible": _strip,
    "unsafe": lambda args: 0 if cw_text.has_unsafe_chars(args[0]) else NONE,
    "sensitive": lambda args: _answer(cw_target.sensitive_component(args[0])),
    "root-hit": lambda args: _answer(cw_target.root_denied_hit(args[0])),
    "canon-dir": _canon_dir,
    "limit": _limit,
    "placement": _placement,
    "resolve": _resolve,
}


def _run(args: Any) -> int:
    name = args.codewrite_command
    try:
        if name == _MAKE_DIRS:
            cw_publish.rollback_on_signals()
            return _make_dirs([os.fsencode(args.ancestor), *map(os.fsencode, args.names)])
        if name in _STAGES:
            cw_publish.rollback_on_signals()
        if name in _FILE_CHECKS:
            reason = _FILE_CHECKS[name](args.file)
            if reason:
                _line(reason)
            return 1 if reason else 0
        values = [os.fsencode(getattr(args, field)) for field in _TEXT_ARGS[name]]
        return _HANDLERS[name](values)
    except cw_publish.PublishError as exc:
        _line(str(exc))
        return 1
    except Exception as exc:  # noqa: BLE001  no traceback: any crash is an internal error, never a "clean" answer
        sys.stderr.write(f"shunt: codewrite {name}: {exc}\n")
        return INTERNAL_ERROR


def register(subparsers: Any) -> None:
    """Add the `codewrite` command group."""
    group = subparsers.add_parser("codewrite", help="text and target checks of code-write")
    group.set_defaults(func=_run)
    sub = group.add_subparsers(dest="codewrite_command", required=True)
    for name in _FILE_CHECKS:
        sub.add_parser(name).add_argument("file")
    dirs = sub.add_parser(_MAKE_DIRS)
    dirs.add_argument("ancestor")
    dirs.add_argument("names", nargs="+")
    for name, fields in _TEXT_ARGS.items():
        parser = sub.add_parser(name)
        for field in fields:
            parser.add_argument(field)
