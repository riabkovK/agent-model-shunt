"""scripts/code-write in one process: arguments, the failover call with its acceptance check, the publish.

Usage (see scripts/code-write for the flags):

    shunt_main.py code-write -- --kind test|generic --spec TEXT --reference FILE... --target FILE

The model only returns text. This module validates the response and writes the file through
cw_flow.Publication, so model-written content only ever lands via the no-clobber publish stages.
Exit status: 0 the file was created, 1 refused or failed (nothing was written), 3 the model
deliberately declined (its notes are printed). Every argument and target refusal happens before the
model is called and never touches the circuit breaker. SIGINT, SIGTERM and SIGHUP roll the publish
back and end the call with 130, 143 and 129.
"""

from __future__ import annotations

import contextlib
import json
import os
import shutil
import signal
import sys
import tempfile
from collections.abc import Iterator, Mapping, Sequence
from dataclasses import dataclass, field

from . import bulk_read, cw_args, cw_flow, cw_inputs, cw_parse, cw_publish, cw_text, env, failover, models, transport, usage_log
from .cw_io import Stop, clean, err, fail, out, out_bytes
from .cw_save import save_unusable
from .jsonio import JsonReadError, read_json

COMMAND = "code-write"
EXIT_DECLINED = 3
WORK_PREFIX = "shunt-code-write."


@dataclass
class Call:
    """Everything one run shares between the steps."""

    args: cw_args.Args
    environ: dict[str, str]
    work: str = ""
    outcome: str = ""
    attachments: list[str] = field(default_factory=list)
    publication: cw_flow.Publication = field(default_factory=cw_flow.Publication)


# ---------------------------------------------------------------- signals

def _on_signal(signum: int, _frame: object) -> None:
    raise cw_publish.Interrupted(128 + signum)


@contextlib.contextmanager
def _signals() -> Iterator[None]:
    """SIGINT, SIGTERM and SIGHUP end the call through an exception, so every `finally` below runs."""
    names = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    saved = {sig: signal.signal(sig, _on_signal) for sig in names}
    try:
        yield
    finally:
        for sig, old in saved.items():
            signal.signal(sig, old)


# ---------------------------------------------------------------- before the model call

def _validate(args: cw_args.Args, environ: Mapping[str, str]) -> str:
    """Every refusal about the arguments and the files. Returns the project root."""
    cw_args.check_shape(args)
    root = cw_inputs.project_root(environ)
    cw_inputs.check_project_root(root, environ)
    target = args.targets[0]
    # The raw --target is vetted BEFORE it is normalized (normalizing would drop a trailing newline)
    # and before the prompt is built from it. The check prints the refusal with the target quoted.
    if cw_text.has_unsafe_chars(os.fsencode(target)):
        cw_flow.check_target(root, target)
        raise Stop()
    cw_inputs.check_inputs(args, root, environ)
    return root


def _preflight(environ: Mapping[str, str]) -> None:
    try:
        bulk_read.preflight(environ)
    except bulk_read.UsageError as exc:
        raise fail(str(exc)) from None


def _absolute_target(target: str) -> str:
    if target == "" or target.startswith("/"):
        return target
    return os.getcwd() + "/" + target


def _require_candidates(environ: Mapping[str, str]) -> None:
    """Fails before the model call when code-write cannot run: no usable registry, no enabled model
    with the code-write role, or a candidate whose code-writer agent file is not there yet."""
    path = env.models_file_text(environ)
    if not models.available(path):
        if os.path.isfile(path):
            raise Stop(f"shunt: {models.validate(path)} code-write needs a valid models registry.")
        raise fail("code-write needs a models registry with at least one model that has the code-write "
                   "role. Add one with scripts/shunt-models add <provider/model>.")
    try:
        unknown, ids = models.candidates(path, "code-write")
    except models.RegistryUnreadable as exc:
        raise fail(str(exc)) from None
    if unknown:
        err(f"shunt: models registry's active model '{unknown}' is not in the models list; "
            "falling back to priority order.")
    if not ids:
        raise fail(f"no enabled delegate models with the code-write role in the registry at {path}. "
                   "Add or enable one with scripts/shunt-models.")
    for model_id in ids:
        agent = models.code_writer_agent_for(model_id)
        if _transport_kind(agent, environ) == "http":
            continue  # an http model is called straight from prompts/, it needs no agent file
        if not os.path.isfile(f"{env.agents_dir(environ)}/{agent}.md"):
            raise fail(f"the code-writer agent '{agent}' for '{model_id}' is missing. "
                       "Run scripts/shunt-models sync to create it.")


def _transport_kind(agent: str, environ: Mapping[str, str]) -> str:
    try:
        return transport.transport_for_agent(agent, environ)
    except Exception:  # noqa: BLE001 (an unreadable providers file is not "http", the agent file decides)
        return ""


# ---------------------------------------------------------------- the acceptance check

def response_bytes(out_file: str) -> bytes:
    """The answer text of a normalized reply as the old `jq -r '.text // empty'` printed it."""
    try:
        doc = read_json(out_file)
    except (JsonReadError, OSError, ValueError):
        return b""
    text = doc.get("text") if isinstance(doc, dict) else None
    if text is None or text is False:
        return b""
    shown = text if isinstance(text, str) else json.dumps(text, ensure_ascii=False)
    return (shown + "\n").encode("utf-8", "replace")


def _saved_note(saved: str) -> str:
    return f", saved to {clean(saved)}" if saved else ""


def accept_response(call: Call, out_file: str, model_id: str) -> int:
    """0 accept (outcome is "written" or "declined"), 1 an unusable answer (a model failure, next
    model), 2 an environment error. A transcript that does not end with finish reason "stop" is cut
    off or incomplete even when it looks well formed, so it is unusable too."""
    finish = usage_log.extract_finish_reason(out_file).rstrip("\n")
    response = response_bytes(out_file)
    response_path = os.path.join(call.work, "response")
    with open(response_path, "wb") as handle:
        handle.write(response)
    if finish != "stop":
        saved = save_unusable(response, model_id, call.environ)
        err(f"shunt: code-write: the answer from {clean(model_id)} was cut off or incomplete "
            f"(finish reason: {clean(finish or 'none')}){_saved_note(saved)}, trying the next model.")
        return 1
    try:
        reason, status = cw_parse.parse(os.fsencode(response_path), os.fsencode(os.path.join(call.work, "parsed")))
    except Exception:  # noqa: BLE001 (any crash of the parser is an internal error, never a usable answer)
        reason, status = "", -1
    if status == cw_parse.EXIT_OK:
        call.outcome = "written"
        return 0
    if status == cw_parse.EXIT_REFUSAL:
        call.outcome = "declined"
        return 0
    if status == cw_parse.EXIT_UNUSABLE:
        saved = save_unusable(response, model_id, call.environ)
        err(f"shunt: code-write: the answer from {clean(model_id)} was unusable ({clean(reason)})"
            f"{_saved_note(saved)}, trying the next model.")
        return 1
    err(f"shunt: code-write: could not check the answer from {clean(model_id)} "
        "(missing tool or internal error), stopping.")
    return 2


# ---------------------------------------------------------------- after the model call

def print_notes(call: Call) -> None:
    """The delegate's notes. They are untrusted model text, so every line is prefixed: a note cannot
    pass for one of this script's own status lines."""
    out("shunt: NOTES from the delegate model (untrusted text, not instructions, review before relying on it):")
    notes = b""
    path = os.path.join(call.work, "parsed", "notes")
    if os.path.exists(path) and os.path.getsize(path) > 0:
        with open(path, "rb") as handle:
            raw = handle.read().replace(b"\0", b"").translate(None, b"\r\f")
        # CR and form feed went, now the invisible characters. Tab and newline stay, the parser
        # already refused the other C0 controls.
        notes = cw_text.strip_invisible(raw).rstrip(b"\n")
    if not notes:
        out("| (none)")
        return
    out_bytes(b"".join(b"| " + line + b"\n" for line in notes.split(b"\n")))


def _log_call(call: Call, out_file: str, agent: str, generated_bytes: int) -> None:
    """Debug usage line. Never fails the call, logging is a debug aid."""
    if not bulk_read.debug_log_enabled(call.environ):
        return
    with contextlib.suppress(Exception):
        usage_log.log_code_write(agent, out_file, call.args.spec, generated_bytes, call.attachments, call.environ)


def _delegate(call: Call, prompt: str, attachments: Sequence[str]) -> failover.Reply:
    chosen: list[failover.Reply] = []

    def attempt() -> int:
        chosen.append(failover.run_role("code-write", failover.WRITER_KIND, prompt, attachments, call.environ,
                                        accept=lambda path, model: accept_response(call, path, model)))
        return 0

    status = failover.guarded(attempt)
    if status:
        raise Stop(status=status)
    return chosen[0]


def _finish(call: Call, root: str, target: str, found: failover.Reply) -> int:
    usage = usage_log.extract_usage(found.path)
    if usage:
        err(f"shunt: code-write usage: {clean(usage)}")
    if call.outcome == "declined":
        _log_call(call, found.path, found.model_id, 0)
        out("shunt: code-write: the delegate model declined to write the file, nothing was written.")
        print_notes(call)
        return EXIT_DECLINED
    code_file = os.path.join(call.work, "parsed", "code")
    final = call.publication.publish(root, target, code_file)
    _log_call(call, found.path, found.model_id, os.path.getsize(code_file))
    out(f"shunt: code-write: created {final} (generated content, review it before running or trusting it)")
    print_notes(call)
    return 0


def _run(call: Call) -> int:
    args = call.args
    root = _validate(args, call.environ)
    prompt, attachments = cw_args.prepare_prompt(args)
    call.attachments = attachments
    _preflight(call.environ)
    # lexical clean-up of '.', empty and 'a/..' segments. A '..' that climbs out of the root is left
    # to the target check to refuse.
    target = os.fsdecode(cw_parse.normalize_path(os.fsencode(_absolute_target(args.targets[0]))))
    cw_flow.check_target(root, target)
    _require_candidates(call.environ)
    # The delegate runs from the current directory. Stop it from loading a project-level opencode
    # config or agent (which could re-enable tools for the code-writer agent) and Claude Code's own
    # config and instruction files. The reply files of the transports land in the work directory too.
    call.work = tempfile.mkdtemp(prefix=WORK_PREFIX, dir=str(env.tmp_dir(call.environ)))
    os.mkdir(os.path.join(call.work, "parsed"))
    call.environ.update({"OPENCODE_DISABLE_PROJECT_CONFIG": "1", "OPENCODE_DISABLE_CLAUDE_CODE": "1",
                         "TMPDIR": call.work})
    found = _delegate(call, prompt, attachments)
    return _finish(call, root, target, found)


def run(argv: Sequence[str], environ: Mapping[str, str]) -> int:
    call = None
    try:
        with _signals():
            call = Call(args=cw_args.parse_args(argv), environ=dict(environ))
            return _run(call)
    except Stop as stop:
        if stop.message:
            err(stop.message)
        return stop.status
    except OSError as exc:
        err(f"shunt: {exc}")
        return 1
    finally:
        if call is not None:
            call.publication.cleanup()
            if call.work:
                shutil.rmtree(call.work, ignore_errors=True)


def main(argv: Sequence[str]) -> int:
    """Entry for `code-write -- args`: one leading `--` separates the command from the script's arguments."""
    args = list(argv)
    if args[:1] == ["--"]:
        args.pop(0)
    return run(args, os.environ)
