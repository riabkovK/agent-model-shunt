"""Failover over the candidate models of a role, in one process.

Port of shunt_invoke, shunt_invoke_with_failover, shunt_invoke_role_with_failover, _shunt_note_failure,
_shunt_breaker_record and _shunt_report_no_delegate of scripts/lib/opencode.sh. The candidates come
from models.py, the circuit breaker is read and written in process (breaker.py), and each attempt is
transport.invoke_status (HTTP in process, the OpenCode CLI as a child).

A role whose answer must be judged by the caller (code-write) passes an `accept` callback. It gets
the reply file and the model id: 0 accepts (breaker success), 1 rejects (a model failure: breaker
failure, the reply file is removed, next model), anything else aborts the call with status 1 and
leaves the breaker alone.

Exit status 1 is a fatal `shunt:` line (every candidate failed or paused, no candidate, ...).
"""

from __future__ import annotations

import argparse
import os
import sys
import unicodedata
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any, NoReturn

from . import breaker, env, healthcheck_bg, models, transport
from . import transport_reply as reply
from .transport_reply import AUTH, CONFIG, DEADLINE, EMPTY, ERROR, OVERSIZE, SKIPPED, TIMEOUT, UNREACHABLE

DEFAULT_TIMEOUT = "300"
WRITER_KIND = "writer"


class Fatal(Exception):
    """End the call with this `shunt:` line and exit status 1."""


@dataclass(frozen=True)
class Reply:
    path: str
    model_id: str


def _fatal(message: str) -> NoReturn:
    raise Fatal(message)


def breaker_key(model_id: str, role: str) -> str:
    return model_id if role == "bulk-read" else f"{model_id}#{role}"


def _is_open(environ: Mapping[str, str], key: str) -> bool:
    try:
        return breaker.is_open(environ, key)
    except (models.ShuntError, OSError, UnicodeError, ValueError):
        return False  # a state file that cannot be read means closed


def _record(environ: Mapping[str, str], outcome: str, key: str, unreachable: bool = False) -> None:
    """Record an attempt outcome. A breaker write failure is only a warning: the breaker is an
    optimisation and must not kill a call whose paid generation already happened."""
    try:
        if outcome == "success":
            breaker.write_state(environ, key, 0, 0)
        else:
            breaker.record_failure(environ, key, unreachable=unreachable)
    except Exception:  # noqa: BLE001 (any failure to write the state, never fatal)
        state = environ.get("SHUNT_BREAKER_STATE_FILE") or str(env.breaker_state_file(environ))
        sys.stderr.write(f"shunt: warning: could not update the circuit breaker state ({state})\n")


def _strip_controls(text: str) -> str:
    return "".join(c for c in text if unicodedata.category(c) != "Cc")


def failure_reason(status: int, agent: str, environ: Mapping[str, str]) -> str:
    timeout = environ.get("SHUNT_TIMEOUT_SECONDS") or DEFAULT_TIMEOUT
    if status == TIMEOUT:
        return f"timed out after {timeout}s"
    if status == UNREACHABLE:
        return "unreachable (no connection within SHUNT_CONNECT_TIMEOUT)"
    if status == SKIPPED:
        return "skipped by the healthcheck (unhealthy at the last check)"
    if status == DEADLINE:
        return "total deadline reached (SHUNT_TOTAL_TIMEOUT_SECONDS)"
    if status == ERROR:
        try:
            kind = transport.transport_for_agent(agent, environ) if agent else ""
        except Exception:  # noqa: BLE001 (a transport that cannot be looked up is a "request error")
            kind = ""
        return {"opencode": "opencode error", "http": "HTTP request error"}.get(kind, "request error")
    fixed = {EMPTY: "empty output", AUTH: "auth failed", OVERSIZE: "input too large for this model",
             CONFIG: "config problem (see above), skipped"}
    return fixed.get(status) or "unexpected status " + "".join(c for c in str(status) if c.isdigit())


def note_failure(model_id: str, status: int, agent: str, environ: Mapping[str, str]) -> None:
    """One stderr line saying why a candidate failed. Control characters are stripped from the id."""
    sys.stderr.write(f"shunt: {_strip_controls(model_id)} failed: {failure_reason(status, agent, environ)}\n")


def _report_no_delegate(role: str, oversize: int) -> NoReturn:
    hint = " Read the file directly instead, in sections with offset/limit." if role == "bulk-read" else ""
    _fatal(f"no delegate model can take this input ({oversize} refused it as too large, the others "
           f"failed or are paused).{hint}")


def _agent_for(path: str, model_id: str, kind: str) -> str:
    return models.code_writer_agent_for(model_id) if kind == WRITER_KIND else models.agent_for(path, model_id)


Accept = Callable[[str, str], int]
ACCEPTED = 0
REJECTED = 1


def run_role(role: str, kind: str, question: str, files: Sequence[str], environ: Mapping[str, str], *,
             accept: Accept | None = None, warn_active: bool = False) -> Reply:
    """Try the candidates of `role` in order until one answers (and `accept`, when given, takes it).

    A model that fails to run gets a note and a breaker failure. One that refuses the input as too
    large (OVERSIZE), whose key is rejected (AUTH), that has a config problem (CONFIG) or that the healthcheck
    cache marks unhealthy (SKIPPED) is skipped
    without a breaker failure. Fatal (Fatal) once every candidate failed or is paused."""
    path = env.models_file_text(environ)
    if role not in models.ROLES:
        _fatal(f"unknown role '{role}' (known roles: {' '.join(models.ROLES)}).")
    unknown, ids = models.candidates(path, role)
    if unknown and warn_active:
        sys.stderr.write(f"shunt: models registry's active model '{unknown}' is not in the models "
                         "list; falling back to priority order.\n")
    if not ids:
        hint = (" Read the file directly instead, or add/enable a model with scripts/shunt-models."
                if role == "bulk-read" else " Add or enable a model with that role using scripts/shunt-models.")
        _fatal(f"no enabled delegate models with the {role} role in the registry at {path}.{hint}")
    tried_any = False
    oversize = 0
    for model_id in ids:
        key = breaker_key(model_id, role)
        if _is_open(environ, key):
            continue
        tried_any = True
        agent = _agent_for(path, model_id, kind)
        status, out = transport.invoke_status(agent, question, files, environ)
        if status == 0:
            verdict = ACCEPTED if accept is None else accept(out, model_id)
            if verdict == ACCEPTED:
                _record(environ, "success", key)
                return Reply(out, model_id)
            _unlink(out)
            if verdict != REJECTED:
                raise reply.Abort(1)
            _record(environ, "failure", key)
            continue
        note_failure(model_id, status, agent, environ)
        if status in (AUTH, CONFIG, SKIPPED):  # SKIPPED: no call was made, the healthcheck status is the pause
            continue
        if status == OVERSIZE:
            oversize += 1
            continue
        if status == UNREACHABLE and healthcheck_bg.owns_unreachable(environ, model_id):
            continue  # the healthcheck status (expires after SHUNT_HEALTHCHECK_RETRY) replaces the breaker pause
        _record(environ, "failure", key, unreachable=status == UNREACHABLE)
    if not tried_any:
        _fatal("every delegate model in the registry is currently paused (circuit breaker open); "
               "no candidates available.")
    if oversize:
        _report_no_delegate(role, oversize)
    _fatal("all delegate models in the registry failed for this call.")


def _unlink(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def invoke_legacy(agent: str, question: str, files: Sequence[str], environ: Mapping[str, str]) -> str:
    """The single-agent path (no registry): fatal on any failure. Returns the reply file."""
    status, out = transport.invoke_status(agent, question, files, environ)
    if status == 0:
        return out
    if status == OVERSIZE:
        _fatal(f"no delegate model can take this input (too large for agent '{agent}'). Read the file "
               "directly instead, in sections with offset/limit.")
    if status == CONFIG:
        _fatal(f"agent '{agent}' could not be run: it is not prepared or its model has a config problem "
               "(explained above), nothing was sent.")
    if status == 1:
        _fatal(f"agent '{agent}' failed with an unexpected status 1 (any reason is printed above).")
    try:
        is_http = transport.transport_for_agent(agent, environ) == "http"
    except Exception:  # noqa: BLE001
        is_http = False
    if is_http:
        note_failure(agent, status, agent, environ)
        _fatal(f"the HTTP request for agent '{agent}' failed (reason above).")
    _fatal(f"opencode run failed for agent '{agent}' (not found, timed out after "
           f"{environ.get('SHUNT_TIMEOUT_SECONDS') or DEFAULT_TIMEOUT}s, exited non-zero, or produced no output).")


# ---------------------------------------------------------------- command line

def guarded(call: Any) -> int:
    try:
        return call()
    except Fatal as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return 1
    except reply.Abort as stop:
        return stop.status
    except BrokenPipeError:
        raise
    except models.RegistryUnreadable as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return 2
    except OSError as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return 1


def _run(args: argparse.Namespace) -> int:
    def call() -> int:
        found = run_role(args.role, args.agent_kind, args.question, args.files, os.environ)
        sys.stdout.write(f"{found.path}\n{found.model_id}\n")
        return 0
    return guarded(call)


def select_bulk(legacy_agent: str, question: str, files: Sequence[str],
                environ: Mapping[str, str]) -> tuple[str, str]:
    """shunt_invoke_with_failover: the legacy agent without a registry, else the bulk-read role.
    Returns (reply file, agent or model id). Raises Fatal, reply.Abort or models.RegistryUnreadable."""
    if not models.available(env.models_file_text(environ)):
        return invoke_legacy(legacy_agent, question, files, environ), legacy_agent
    found = run_role("bulk-read", "bulk", question, files, environ, warn_active=True)
    return found.path, found.model_id


def _bulk(args: argparse.Namespace) -> int:
    def call() -> int:
        path, used = select_bulk(args.legacy_agent, args.question, args.files, os.environ)
        sys.stdout.write(f"{path}\n{used}\n")
        return 0
    return guarded(call)


def _legacy(args: argparse.Namespace) -> int:
    def call() -> int:
        sys.stdout.write(invoke_legacy(args.agent, args.question, args.files, os.environ) + "\n")
        return 0
    return guarded(call)


def _note(args: argparse.Namespace) -> int:
    note_failure(args.id, args.status, args.agent, os.environ)
    return 0


def register(subparsers: Any) -> None:
    """Add the `failover` command group: run, bulk, legacy, note-failure."""
    group = subparsers.add_parser("failover", help="run a call over the candidate models of a role")
    sub = group.add_subparsers(dest="failover_command", required=True)
    run = sub.add_parser("run")
    run.set_defaults(func=_run)
    run.add_argument("--role", required=True)
    run.add_argument("--agent-kind", choices=("bulk", WRITER_KIND), default="bulk")
    bulk = sub.add_parser("bulk")
    bulk.set_defaults(func=_bulk)
    bulk.add_argument("--legacy-agent", required=True)
    legacy = sub.add_parser("legacy")
    legacy.set_defaults(func=_legacy)
    legacy.add_argument("agent")
    for parser in (run, bulk, legacy):
        parser.add_argument("question")
        parser.add_argument("files", nargs="*")
    note = sub.add_parser("note-failure")
    note.set_defaults(func=_note)
    note.add_argument("id")
    note.add_argument("status", type=int)
    note.add_argument("agent", nargs="?", default="")
