"""Small read-only questions about models.json, providers.json and opencode.json.

The shell scripts used to ask these with jq. Each subcommand is one question and
prints plain lines or answers with its exit status (0 yes, 1 no), so a script
needs no JSON tool. Paths come from the same environment variables as everywhere
else. The answers match the jq programs they replace, including how null and
false count as unset (jq `//`) and how a non-string value prints (jq -r).
"""

import argparse
import json
import os
import sys
from collections.abc import Callable, Mapping, Sequence
from typing import Any

from . import env, models
from .jsonio import JsonReadError, read_json
from .providers import _tojson as jq_tojson

NO = 1
Answer = tuple[Sequence[str], int]


def _doc(path: str) -> Any:
    try:
        return read_json(path)
    except JsonReadError:
        return None


def _models(environ: Mapping[str, str]) -> list[Any] | None:
    doc = _doc(env.models_file_text(environ))
    entries = doc.get("models") if isinstance(doc, dict) else None
    return entries if isinstance(entries, list) else None


def _need_models(environ: Mapping[str, str]) -> list[dict[str, Any]]:
    """The model entries. Anything else is a failure, as jq's error was."""
    entries = _models(environ)
    if entries is None or not all(isinstance(m, dict) for m in entries):
        raise ValueError("no readable models array")
    return entries


def _providers(environ: Mapping[str, str]) -> Any:
    doc = _doc(env.providers_file_text(environ))
    return doc.get("providers") if isinstance(doc, dict) else None


def _truthy(value: Any) -> bool:
    """jq -e on a value: false and null fail."""
    return value is not None and value is not False


def _yes(condition: bool) -> Answer:
    return [], 0 if condition else NO


def _roles(model: Mapping[str, Any]) -> list[Any]:
    roles = model.get("roles")
    if roles is None or roles is False:
        return list(models.ROLES)
    if not isinstance(roles, list):
        raise ValueError("roles is not a list")
    return roles


def _join_roles(model: Mapping[str, Any]) -> str:
    return ",".join(models._interp(r) if not isinstance(r, str) else r for r in _roles(model))


def _model_ids(environ: Mapping[str, str], _arg: str) -> Answer:
    return [models._raw(m.get("id")) for m in _need_models(environ)], 0


def _active(environ: Mapping[str, str], _arg: str) -> Answer:
    doc = _doc(env.models_file_text(environ))
    active = doc.get("active") if isinstance(doc, dict) else None
    return ([models._raw(active)] if _truthy(active) else []), 0


def _count(environ: Mapping[str, str], _arg: str) -> Answer:
    return [str(len(_need_models(environ)))], 0


def _any_enabled(environ: Mapping[str, str], _arg: str) -> Answer:
    return _yes(any(m.get("enabled") is not False for m in _need_models(environ)))


def _role_ids(environ: Mapping[str, str], role: str) -> Answer:
    return [models._raw(m.get("id")) for m in _need_models(environ) if role in _roles(m)], 0


def _status_rows(environ: Mapping[str, str], _arg: str) -> Answer:
    doc = _doc(env.models_file_text(environ))
    active = doc.get("active") if isinstance(doc, dict) else None
    rows = []
    for m in _need_models(environ):
        enabled = m.get("enabled") is not False
        if m.get("id") != active:
            state = ""
        else:
            state = "active" if enabled else "active (skipped, disabled)"
        rows.append("\t".join([
            models._interp(m.get("id")), models._interp(m.get("agent")), "enabled" if enabled else "disabled",
            f"thinking={models._interp(m.get('thinking'))}",
            f"thinking_off={'none' if m.get('thinking_off_options') is None else 'set'}",
            f"roles={_join_roles(m)}", state]))
    return rows, 0


def _has_array(environ: Mapping[str, str], _arg: str) -> Answer:
    return _yes(_models(environ) is not None)


def _has_id(environ: Mapping[str, str], model_id: str) -> Answer:
    entries = _models(environ)
    return _yes(entries is not None and any(isinstance(m, dict) and m.get("id") == model_id for m in entries))


def _providers_object(environ: Mapping[str, str], _arg: str) -> Answer:
    return _yes(isinstance(_providers(environ), dict))


def _providers_empty(environ: Mapping[str, str], _arg: str) -> Answer:
    providers = _providers(environ)
    return _yes(isinstance(providers, dict) and not providers)


def _provider_entry(environ: Mapping[str, str], name: str) -> Any:
    providers = _providers(environ)
    return providers.get(name) if isinstance(providers, dict) else None


def _provider_exists(environ: Mapping[str, str], name: str) -> Answer:
    return _yes(_truthy(_provider_entry(environ, name)))


def _provider_name_refusal(environ: Mapping[str, str], name: str) -> Answer:
    path = env.providers_file_text(environ)
    if _provider_entry(environ, name) is not None:
        return [f"shunt: invalid provider name: {path} has an entry named {jq_tojson(name)}, which uses characters "
                "other than letters, digits, dot, dash and underscore (or does not start with a letter or digit). "
                "Please edit providers.json to remove or rename that entry."], 0
    return ["shunt: invalid provider name (use letters, digits, dot, dash, underscore)."], 0


def _opencode_provider(environ: Mapping[str, str], name: str) -> Answer:
    doc = _doc(str(env.opencode_config_home(environ) / "opencode.json"))
    table = doc.get("provider") if isinstance(doc, dict) else None
    return _yes(isinstance(table, dict) and _truthy(table.get(name)))


def _json_object(_environ: Mapping[str, str], text: str) -> Answer:
    try:
        return _yes(isinstance(json.loads(text), dict))
    except ValueError:
        return _yes(False)


_QUESTIONS: dict[str, Callable[[Mapping[str, str], str], Answer]] = {
    "model-ids": _model_ids, "active": _active, "model-count": _count, "any-enabled": _any_enabled,
    "role-ids": _role_ids, "status-rows": _status_rows, "has-models-array": _has_array, "has-model": _has_id,
    "providers-object": _providers_object, "providers-empty": _providers_empty,
    "provider-exists": _provider_exists, "provider-name-refusal": _provider_name_refusal,
    "opencode-provider": _opencode_provider, "json-object": _json_object,
}


def run(args: argparse.Namespace) -> int:
    arg = args.arg
    if args.question == "json-object":
        arg = sys.stdin.read()
    try:
        lines, code = _QUESTIONS[args.question](os.environ, arg)
    except (ValueError, OSError, TypeError, AttributeError):
        return NO
    for line in lines:
        sys.stdout.write(line + "\n")
    return code


def register(subparsers: Any) -> None:
    """Add the `probe <question> [arg]` command."""
    parser = subparsers.add_parser("probe", help="answer a small question about the registry files")
    parser.set_defaults(func=run)
    parser.add_argument("question", choices=sorted(_QUESTIONS))
    parser.add_argument("arg", nargs="?", default="")
