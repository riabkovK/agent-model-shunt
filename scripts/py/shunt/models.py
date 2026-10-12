"""Reader side of the delegate model registry (models.json) and agent file rendering.

Port of scripts/lib/models.sh. Output text, stderr messages and exit codes match
the bash functions that now wrap these subcommands. This module only reads
models.json. The registry writers still live in scripts/shunt-models and
scripts/lib/migrate.sh until sub-phase 6.

Where the jq programs failed silently on a malformed shape (a model entry that
is not an object, `models` missing), the same shapes are treated as "cannot be
read" here: the validation stage that needs them is skipped or reports the
generic reason, exactly as the bash did.
"""

import argparse
import json
import os
import re
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from . import env
from .jsonio import JsonReadError, read_json, write_bytes_atomic

ROLES: tuple[str, ...] = ("bulk-read", "code-write")  # keep in sync with SHUNT_MODELS_ROLES in models.sh
AGENT_FILE_MODE = 0o600  # bash used mktemp, which creates 0600
BULK_PREFIX = "shunt-bulk-reader-"
WRITER_PREFIX = "shunt-code-writer-"
MAX_CONTEXT_TOKENS = 10**12
OVERSIZE_POLICIES = ("map_reduce", "fail")
AGENT_NAME_RE = re.compile(r"[a-z0-9][a-z0-9-]*")
_SLUG_NON_ALNUM = re.compile(r"[^a-z0-9]+")
_ASCII_LOWER = {c: c + 32 for c in range(ord("A"), ord("Z") + 1)}


class ShuntError(Exception):
    """A user-facing failure: printed as `shunt: <message>` on stderr, exit 1."""


class RegistryUnreadable(Exception):
    """The registry is missing, not JSON, or has a shape the readers cannot walk."""


# ---------------------------------------------------------------- jq-like helpers

def _tojson(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _interp(value: Any) -> str:
    """jq string interpolation: strings raw, everything else as compact JSON."""
    return value if isinstance(value, str) else _tojson(value)


def _raw(value: Any) -> str:
    """jq -r output: strings raw, everything else as pretty JSON."""
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False, indent=2)


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def slug_core(model_id: str) -> str:
    """Lowercase, dash-separated form of a provider/model id (ASCII lowering only, like jq)."""
    lowered = model_id.translate(_ASCII_LOWER)
    return _SLUG_NON_ALNUM.sub("-", lowered).strip("-")


def slug(model_id: str) -> str:
    return BULK_PREFIX + slug_core(model_id)


def code_writer_agent_for(model_id: str) -> str:
    return WRITER_PREFIX + slug_core(model_id)


# ---------------------------------------------------------------- registry access

def _load(path: Path) -> Any:
    try:
        return read_json(path)
    except JsonReadError as exc:
        raise RegistryUnreadable(str(exc)) from exc


def _entries(doc: Any) -> list[dict[str, Any]]:
    """The models array when every entry is an object, else RegistryUnreadable."""
    models = doc.get("models") if isinstance(doc, dict) else None
    if not isinstance(models, list) or not all(isinstance(m, dict) for m in models):
        raise RegistryUnreadable("the registry has no readable models array")
    return models


def _roles_of(model: Mapping[str, Any]) -> list[Any]:
    """A model's roles: every role when the field is absent or null/false."""
    roles = model.get("roles")
    if roles is None or roles is False:
        return list(ROLES)
    return roles if isinstance(roles, list) else []


def _matching(models: Sequence[dict[str, Any]], model_id: str) -> list[dict[str, Any]]:
    return [m for m in models if m.get("id") == model_id]


def _enabled(model: Mapping[str, Any]) -> bool:
    return model.get("enabled") is not False


# ---------------------------------------------------------------- validation

def _duplicate_error(models: list[dict[str, Any]], path: Path) -> str | None:
    seen: dict[str, Any] = {}
    dupes: dict[str, Any] = {}
    for model in models:
        key = _tojson(model.get("id"))
        if key in seen:
            dupes[key] = model.get("id")
        seen[key] = model.get("id")
    if not dupes:
        return None
    ids = sorted(_interp(v) for v in dupes.values())
    return f"models registry at {path} has duplicate model id(s): " + "".join(i + " " for i in ids)


def _roles_error(models: list[dict[str, Any]]) -> str | None:
    for model in models:
        if "roles" not in model:
            continue
        roles, mid = model["roles"], _interp(model.get("id"))
        if not isinstance(roles, list):
            return f'model "{mid}" has invalid roles: must be an array of role names.'
        if not roles:
            return f'model "{mid}" has an empty roles array.'
        bad = [_tojson(r) for r in roles if not isinstance(r, str) or r not in ROLES]
        if bad:
            return (f'model "{mid}" has unknown role(s): {", ".join(bad)}. '
                    f'Known roles: {", ".join(ROLES)}.')
    return None


def _agent_name_error(models: list[dict[str, Any]]) -> str | None:
    seen: dict[str, str] = {}
    for model in models:
        raw_id = model.get("id")
        mid = "" if raw_id is None else _interp(raw_id)
        if not mid:
            continue
        core = slug_core(mid)
        if not core:
            return f'model "{mid}" derives an empty agent name.'
        agent_field = model.get("agent")
        agent = BULK_PREFIX + core if agent_field is None or agent_field is False or agent_field in ("", "-") else _interp(agent_field)
        writer = WRITER_PREFIX + core if "code-write" in _roles_of(model) else ""
        if not AGENT_NAME_RE.fullmatch(agent):
            return (f'model "{mid}" has an invalid agent name "{agent}": '
                    "use lowercase letters, digits and dashes.")
        for name in (agent, writer):
            if not name:
                continue
            other = seen.setdefault(name, mid)
            if other != mid:
                return f'models "{other}" and "{mid}" would share the agent name "{name}".'
    return None


def _sizing_error(models: list[dict[str, Any]]) -> str | None:
    for model in models:
        mid = _interp(model.get("id"))
        if "context_tokens" in model:
            tokens = model["context_tokens"]
            if not (_is_number(tokens) and 1 <= tokens < MAX_CONTEXT_TOKENS and tokens == int(tokens)):
                return (f'model "{mid}" has invalid context_tokens: '
                        "must be a positive integer below 10^12.")
        if "oversize_policy" in model:
            policy = model["oversize_policy"]
            if not (isinstance(policy, str) and policy in OVERSIZE_POLICIES):
                return f'model "{mid}" has invalid oversize_policy: must be "map_reduce" or "fail".'
    return None


def validate(path: Path) -> str | None:
    """Return the one-line reason the registry is invalid, or None when it is valid."""
    if not path.is_file():
        return f"models registry not found at {path}"
    try:
        doc = read_json(path)
    except JsonReadError:
        doc = None
    if doc is None or doc is False:  # jq -e . rejects null and false too
        return f"models registry at {path} contains invalid JSON."

    try:
        models = _entries(doc)
    except RegistryUnreadable:
        # The duplicate, roles and agent-name stages skipped silently on a jq error.
        return f"models registry at {path}: cannot read context_tokens and oversize_policy."
    reason = _duplicate_error(models, path)
    if reason:
        return reason
    for check in (_roles_error, _agent_name_error, _sizing_error):
        reason = check(models)
        if reason:
            return f"models registry at {path}: {reason}"
    return None


def available(path: Path) -> bool:
    return path.is_file() and validate(path) is None


# ---------------------------------------------------------------- lookups

def candidates(path: Path, role: str) -> tuple[str, list[str]]:
    """Return (active id that is not in the registry or "", ids to try in order)."""
    doc = _load(path)
    models = _entries(doc)
    active = doc.get("active")
    active_id = "" if active is None or active is False else _interp(active)
    known = [m.get("id") for m in models]
    ids = [m.get("id") for m in models if _enabled(m) and role in _roles_of(m)]
    head = [active_id] if active_id and active_id in known and active_id in ids else []
    unknown = active_id if active_id and active_id not in known else ""
    ordered = head + [i for i in ids if i not in head]
    return unknown, [_interp(i) for i in ordered]


def agent_for(path: Path, model_id: str) -> str:
    """The registered agent name, the derived one for an entry without it, "" for an unknown id."""
    found = _matching(_entries(_load(path)), model_id)
    if not found:
        return ""
    agent = found[0].get("agent")
    if agent is None or agent is False or agent == "":
        return slug(model_id)
    return "" if agent == "-" else _raw(agent)


def _field_values(path: Path, model_id: str, field: str, default: Any) -> list[Any]:
    found = _matching(_entries(_load(path)), model_id)
    return [default if m.get(field) is None or m[field] is False and default is None else m[field] for m in found]


def thinking_for(path: Path, model_id: str) -> list[str]:
    return [_raw(v) for v in _field_values(path, model_id, "thinking", False)]


def thinking_options_for(path: Path, model_id: str, field: str = "thinking_options") -> list[str]:
    return [_tojson(v) for v in _field_values(path, model_id, field, None)]


def has_role(path: Path, model_id: str, role: str) -> bool:
    try:
        found = _matching(_entries(_load(path)), model_id)
    except RegistryUnreadable:
        return False
    return bool(found) and role in _roles_of(found[-1])


# ---------------------------------------------------------------- agent files

def thinking_block(path: Path, model_id: str) -> str:
    """Extra agent frontmatter lines for the model's current thinking state, or ""."""
    models = _matching(_entries(_load(path)), model_id)
    if not models:
        return ""
    model = models[0]
    thinking_on = model.get("thinking") is True
    options = model.get("thinking_options" if thinking_on else "thinking_off_options")
    if not isinstance(options, dict):
        return ""
    return "\n".join(f"{key}: {_interp(value)}" for key, value in options.items()).rstrip("\n")


_BULK_TOOLS = """\
tools:
  read: true
  bash: false
  write: false
  edit: false
  glob: false
  grep: false
  task: false
  webfetch: false
  todowrite: false
  skill: false
  changed-files: false
  dependency-analyzer: false
---
"""

_WRITER_TOOLS = """\
tools:
  "*": false
  read: false
  bash: false
  write: false
  edit: false
  glob: false
  grep: false
  task: false
  webfetch: false
  todowrite: false
  skill: false
  changed-files: false
  dependency-analyzer: false
---
"""


def _render(head: str, tools: str, model_id: str, block: str, prompt: bytes) -> bytes:
    extra = f"{block}\n" if block else ""
    text = f"---\n{head}model: {model_id}\n{extra}{tools}\n"
    return text.encode("utf-8", "surrogateescape") + prompt


_BULK_HEAD = ("description: Precise, read-only code analyst for delegated bulk-read questions.\n"
              "mode: primary\n")
_WRITER_HEAD = ("description: Tool-less code generator for delegated code-write calls.\n"
                "mode: primary\n")


def render_bulk_reader(model_id: str, block: str, prompt: bytes) -> bytes:
    return _render(_BULK_HEAD, _BULK_TOOLS, model_id, block, prompt)


def render_code_writer(model_id: str, block: str, prompt: bytes) -> bytes:
    # The temperature line sits between `model:` and the thinking block.
    block = "temperature: 0.2" + (f"\n{block}" if block else "")
    return _render(_WRITER_HEAD, _WRITER_TOOLS, model_id, block, prompt)


def require_prompts(prompts_dir: Path, roles: Sequence[str]) -> None:
    """Raise unless the role prompt files are readable (bulk-reader.md always)."""
    names = ["bulk-reader"] + (["code-writer"] if "code-write" in roles else [])
    for name in names:
        file = prompts_dir / f"{name}.md"
        if not os.access(file, os.R_OK):
            raise ShuntError(f"the role prompt file {file} is missing or unreadable, nothing was changed.")


def _agent_file(agents_dir: Path, name: str) -> Path:
    if not AGENT_NAME_RE.fullmatch(name):
        raise ShuntError(f"refusing to write an agent file for the unsafe agent name '{name}'.")
    return agents_dir / f"{name}.md"


def materialize_agent(path: Path, agents_dir: Path, prompts_dir: Path, model_id: str) -> None:
    """Render the model's agent files, dropping a code-writer file for a dropped role."""
    writes_code = has_role(path, model_id, "code-write")
    require_prompts(prompts_dir, ["code-write"] if writes_code else [])
    agent = agent_for(path, model_id)
    if not agent:
        raise ShuntError(f"no registered agent name for model '{model_id}'.")
    block = thinking_block(path, model_id)
    agents_dir.mkdir(parents=True, exist_ok=True)

    bulk_prompt = (prompts_dir / "bulk-reader.md").read_bytes()
    write_bytes_atomic(_agent_file(agents_dir, agent), render_bulk_reader(model_id, block, bulk_prompt),
                       AGENT_FILE_MODE)
    writer_file = _agent_file(agents_dir, code_writer_agent_for(model_id))
    if writes_code:
        writer_prompt = (prompts_dir / "code-writer.md").read_bytes()
        write_bytes_atomic(writer_file, render_code_writer(model_id, block, writer_prompt),
                           AGENT_FILE_MODE)
    else:
        writer_file.unlink(missing_ok=True)


# ---------------------------------------------------------------- command line

def _prompts_dir(environ: Mapping[str, str]) -> Path:
    default = Path(__file__).resolve().parents[3] / "prompts"
    return Path(environ.get("SHUNT_PROMPTS_DIR") or default)


def _out(lines: Sequence[str]) -> None:
    for line in lines:
        sys.stdout.write(line + "\n")


def _dispatch(args: argparse.Namespace, environ: Mapping[str, str]) -> int:
    path = env.models_file(environ)
    cmd = args.models_command
    if cmd == "validate":
        reason = validate(path)
        if reason:
            _out([f"shunt: {reason}"])
        return 1 if reason else 0
    if cmd == "available":
        return 0 if available(path) else 1
    if cmd == "candidates":
        unknown, ids = candidates(path, args.role)
        if unknown and args.quiet != "quiet":
            sys.stderr.write(f"shunt: models registry's active model '{unknown}' is not in the models "
                             "list; falling back to priority order.\n")
        _out(ids)
    elif cmd == "agent-for":
        agent = agent_for(path, args.id)
        _out([agent] if agent else [])
    elif cmd == "thinking-for":
        _out(thinking_for(path, args.id))
    elif cmd == "thinking-options-for":
        _out(thinking_options_for(path, args.id))
    elif cmd == "thinking-off-options-for":
        _out(thinking_options_for(path, args.id, "thinking_off_options"))
    elif cmd == "slug":
        _out([slug(args.id)])
    elif cmd == "slug-core":
        _out([slug_core(args.id)])
    elif cmd == "code-writer-agent-for":
        _out([code_writer_agent_for(args.id)])
    elif cmd == "has-role":
        return 0 if has_role(path, args.id, args.role) else 1
    elif cmd == "thinking-block":
        block = thinking_block(path, args.id)
        _out([block] if block else [])
    elif cmd == "require-prompts":
        require_prompts(_prompts_dir(environ), args.roles)
    elif cmd == "materialize":
        materialize_agent(path, env.agents_dir(environ), _prompts_dir(environ), args.id)
    return 0


def run(args: argparse.Namespace) -> int:
    try:
        return _dispatch(args, os.environ)
    except ShuntError as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return 1
    except RegistryUnreadable as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return 2
    except (OSError, UnicodeError) as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return 1


_ID_COMMANDS = ("agent-for", "thinking-for", "thinking-options-for", "thinking-off-options-for",
                "slug", "slug-core", "code-writer-agent-for", "thinking-block", "materialize")


def register(subparsers: Any) -> None:
    """Add the `models` command group to the top-level subparsers."""
    models = subparsers.add_parser("models", help="read the model registry")
    models.set_defaults(func=run)
    sub = models.add_subparsers(dest="models_command", required=True)
    sub.add_parser("validate")
    sub.add_parser("available")
    cands = sub.add_parser("candidates")
    cands.add_argument("role")
    cands.add_argument("quiet", nargs="?", default="")
    for name in _ID_COMMANDS:
        sub.add_parser(name).add_argument("id")
    has = sub.add_parser("has-role")
    has.add_argument("id")
    has.add_argument("role")
    sub.add_parser("require-prompts").add_argument("roles", nargs="*")
