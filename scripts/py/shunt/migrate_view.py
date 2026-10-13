"""Documents and text of the migration plan: the files as they would be after it, and the dry-run output.

Second half of the port of scripts/lib/migrate.sh, see migrate_plan.py for the plan itself.
"""

import json
import re
import sys
from collections.abc import Mapping
from typing import Any

from .migrate_plan import DETECT_KEY_VAR, Ctx, as_dict, is_unset, load, tojson

# ---------------------------------------------------------------- documents after the migration

def providers_doc(ctx: Ctx, plan: Mapping[str, Any]) -> dict[str, Any]:
    """providers.json as it would be after the migration (existing entries kept, migrated ones merged in)."""
    doc = load(ctx.providers_path)
    doc = doc if isinstance(doc, dict) else {"version": 1, "providers": {}}
    table = dict(as_dict(doc.get("providers")))
    for item in plan["providers"]:
        if item["entry"] is not None:
            old = as_dict(table.get(item["name"]))
            keep = {"healthcheck": old["healthcheck"]} if "healthcheck" in old else {}  # an existing choice stays
            table[item["name"]] = {**old, **item["entry"], **keep}
    return {**doc, "providers": table}


def models_doc(ctx: Ctx, plan: Mapping[str, Any]) -> dict[str, Any]:
    """The registry as it would be after the migration."""
    doc = load(ctx.models_path)
    by_id = {m["id"]: m for m in plan["models"]}
    models = []
    for model in doc["models"]:
        planned = by_id.get(model.get("id")) if isinstance(model, dict) else None
        if planned is not None:
            model = dict(model)
            if planned["request_body"] is not None and is_unset(model.get("request_body")):
                model["request_body"] = planned["request_body"]
            if planned["context"] is not None and is_unset(model.get("context_tokens")):
                model["context_tokens"] = planned["context"]["tokens"]
        models.append(model)
    return {**doc, "models": models}


def _canonical(doc: Any) -> str:
    return json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def has_changes(ctx: Ctx, plan: Mapping[str, Any]) -> bool:
    old = load(ctx.providers_path)
    old = old if old is not None else {"version": 1, "providers": {}}
    return (_canonical(old) != _canonical(providers_doc(ctx, plan))
            or _canonical(load(ctx.models_path)) != _canonical(models_doc(ctx, plan)))


def detect_doc(ctx: Ctx, plan: Mapping[str, Any]) -> dict[str, Any]:
    """The providers document used for context detection: planned providers only, plaintext keys replaced by an env ref."""
    names = {p["name"] for p in plan["providers"] if p["state"] in ("new", "done")}
    table = {}
    for name, value in providers_doc(ctx, plan)["providers"].items():
        if name not in names:
            continue
        key = as_dict(value).get("key")
        if isinstance(value, dict) and as_dict(key).get("type") == "plaintext" and as_dict(key).get("ref"):
            value = {**value, "key": {"type": "env", "ref": DETECT_KEY_VAR}}
        table[name] = value
    return {"providers": table}


# ---------------------------------------------------------------- printing

_KEY_PREFIX = {"file": "read from the apiKey file {path} (never shown), then ",
               "auth.json": "read from OpenCode auth.json (never shown), then "}


_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def safe(text: Any) -> str:
    """Text for the terminal: control characters (newline, ESC, C1) become \\xNN escapes."""
    return _CONTROL_RE.sub(lambda m: f"\\x{ord(m.group()):02x}", str(text))


def _storage_text(item: Mapping[str, Any], hint_cmd: str) -> str:
    storage = item["storage"]
    if storage == "none":
        return "none (no apiKey in opencode.json or auth.json)"
    if storage == "env":
        note = f" [{item['reason']}]" if item["reason"] else ""
        return f"env {item['env_ref']} (export it yourself, the key is not copied){note}"
    fixed = {"keyring": "copied to the keyring (never shown)",
             "plaintext": "copied to providers.json as plain text (mode 600, never shown)",
             "stored": "already stored",
             "ask": "key to copy, storage is asked at --apply (or pass --key-storage keyring|env|plaintext|skip)"}
    return fixed.get(storage) or f"skipped: run `! {hint_cmd} key set {item['name']}` then re-run"


def provider_line(item: Mapping[str, Any], hint_cmd: str) -> str:
    head = f"provider {item['name']}: "
    if item["state"] == "skip":
        return f"{head}skipped, {item['reason']}"
    if item["state"] == "done":
        return f"{head}{item['reason']}, nothing to do for the provider"
    target = "opencode (stays, key pending)" if item["state"] == "pending" else "http"
    prefix = _KEY_PREFIX.get(item["key_source"], "").format(path=item["key_path"])
    return (f"{head}base_url {item['base_url']}, transport opencode -> {target}, key: "
            f"{prefix}{_storage_text(item, hint_cmd)}")


def model_line(item: Mapping[str, Any]) -> str:
    body = "unchanged" if item["request_body"] is None else f"{tojson(item['request_body'])} (from reasoningEffort)"
    if item["context"] is not None:
        context = f"{item['context']['tokens']} ({item['context']['source']})"
    elif item["deferred"]:
        context = "detected at --apply, else the opencode.json limit (not verified)"
    else:
        context = "unchanged"
    return f"  model {item['id']}: request_body {body}, context_tokens {context}"


def print_plan(plan: Mapping[str, Any], hint_cmd: str) -> None:
    for item in plan["providers"]:
        sys.stdout.write(safe(provider_line(item, hint_cmd)) + "\n")
    for item in plan["models"]:
        sys.stdout.write(safe(model_line(item)) + "\n")
