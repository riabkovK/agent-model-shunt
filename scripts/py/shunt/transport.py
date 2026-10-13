"""Transport dispatch: which transport serves an agent, and one delegated call through it.

Port of shunt_transport_invoke, _shunt_transport_of_resolved and shunt_transport_for_agent of
scripts/lib/transport.sh. A call yields the path of one normalized response file (see the header of
transport_reply.py) or one of the SHUNT_TRY_INVOKE_* statuses, with the reason already on stderr:

  TIMEOUT 124, ERROR 2, EMPTY 3, AUTH 4, DEADLINE 5, OVERSIZE 6, CONFIG 7, and 1 for an
  unexpected failure. The failover loop (failover.py) maps them to a reason and to the breaker.
"""

from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from . import env, models, opencode_cli, providers, transport_http
from . import transport_reply as reply
from .transport_reply import CONFIG


@dataclass(frozen=True)
class Resolved:
    """The registry entry of an agent: what the opencode guard and the dispatcher need."""

    model_id: str
    context_tokens: str
    found: tuple[dict[str, Any], str]  # the registry entry and role, for the HTTP transport


def resolve(agent: str, environ: Mapping[str, str]) -> Resolved | None:
    """The model whose bulk-reader or code-writer agent is `agent`. None without a usable registry
    or without such a model. Says nothing."""
    try:
        found = transport_http.lookup_model(agent, str(env.models_file(environ)))
    except (models.RegistryUnreadable, OSError, ValueError):
        return None
    if found is None:
        return None
    model = found[0]
    return Resolved(str(model.get("id")), transport_http._text(model.get("context_tokens")), found)


def transport_of(resolved: Resolved | None, environ: Mapping[str, str]) -> str:
    """SHUNT_TRANSPORT when set (tests), else the providers.json transport of the model's provider.
    An unresolved agent is the implicit "opencode". Raises ProviderError for an invalid providers.json."""
    override = environ.get("SHUNT_TRANSPORT") or ""
    if override:
        return override
    if resolved is None or not resolved.model_id:
        return "opencode"
    return providers.field(env.providers_file_text(environ), resolved.model_id.split("/", 1)[0], "transport")


def transport_for_agent(agent: str, environ: Mapping[str, str]) -> str:
    return transport_of(resolve(agent, environ), environ)


def _dispatch(agent: str, question: str, files: Sequence[str], environ: Mapping[str, str]) -> str:
    resolved = resolve(agent, environ)
    try:
        transport = transport_of(resolved, environ)
    except providers.ProviderError as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        sys.stderr.write(f"shunt: cannot work out the transport of agent '{agent}': providers.json is "
                         "unusable (config problem, no request sent).\n")
        raise reply.Abort(CONFIG) from None
    if transport == "opencode":
        return opencode_cli.invoke(agent, question, files, resolved.model_id if resolved else "",
                                   resolved.context_tokens if resolved else "", environ)
    if transport == "http":
        return transport_http.http_call(agent, question, files, environ, resolved.found if resolved else None)
    sys.stderr.write(f"shunt: unknown transport '{transport}' (supported: opencode, http).\n")
    raise reply.Abort(CONFIG)


def invoke_status(agent: str, question: str, files: Sequence[str],
                  environ: Mapping[str, str]) -> tuple[int, str]:
    """One delegated call: (0, response file) or (SHUNT_TRY_INVOKE_* status, ""). Never raises
    for a failed call."""
    return transport_http.call_status(lambda: _dispatch(agent, question, files, environ), "transport")


def _invoke(args: argparse.Namespace) -> int:
    status, path = invoke_status(args.agent, args.question, args.files, os.environ)
    if status == 0:
        sys.stdout.write(path + "\n")
    return status


def _for_agent(args: argparse.Namespace) -> int:
    try:
        sys.stdout.write(transport_for_agent(args.agent, os.environ) + "\n")
    except providers.ProviderError as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return exc.code
    return 0


def _normalize(args: argparse.Namespace) -> int:
    sys.stdout.write(reply.dump(opencode_cli.normalize_file(args.file)))
    return 0


def register(subparsers: Any) -> None:
    """Add the `transport` command group: http-call, invoke, for-agent, normalize."""
    group = subparsers.add_parser("transport", help="send one request through a transport")
    sub = group.add_subparsers(dest="transport_command", required=True)
    transport_http.add_commands(sub)
    invoke = sub.add_parser("invoke")
    invoke.set_defaults(func=_invoke)
    invoke.add_argument("agent")
    invoke.add_argument("question")
    invoke.add_argument("files", nargs="*")
    sub.add_parser("for-agent").add_argument("agent")
    sub.choices["for-agent"].set_defaults(func=_for_agent)
    sub.add_parser("normalize").add_argument("file")
    sub.choices["normalize"].set_defaults(func=_normalize)
