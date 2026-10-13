"""`shunt-models dashboard`: everything the /model-config dashboard shows, in one call.

Port of scripts/lib/dashboard.sh. One record per line, fields separated by single
spaces (the tab below only parses the provider list), values without spaces:
  registry: ok|missing|invalid
  providers_file: ok|missing|invalid
  provider <name> transport=<t> base_url=<url|-> key=<type|env:VAR> key_present=yes|no|unknown [healthcheck=on|off]
  provider <name> invalid
  model <id> enabled=.. active=.. roles=.. thinking=on|off thinking_off=set|none
        context_tokens=<n|unset> oversize_policy=<p>(|default) provider_transport=<t>
  breaker threshold=<n> default=3 cooldown_seconds=<n> default=300
        unreachable_cooldown_seconds=<n> default=120 status=enabled|disabled
  breaker_state <id> <bulk-read|code-write> failures=<n> open=true|false
  self_fix_retries=<n> default=1
  first_choice <bulk-read|code-write> <id|none>
  opencode config=present|absent importable=<name,...|none>
  issue <code> <subject>
  setup: empty|opencode-importable|incomplete|ok
A key value is never printed: key_present only says whether one resolves.
"""

import contextlib
import io
import os
import sys
from collections.abc import Mapping
from typing import Any

from . import breaker, env, models, providers, selffix
from .migrate_plan import Ctx, collect_providers
from .models import RegistryUnreadable

SEP = "\t"


def _doc(path: str) -> Any:
    try:
        return models.read_json(path)
    except Exception:  # an unreadable or malformed file is simply not usable
        return None


def _models_doc(environ: Mapping[str, str]) -> list[dict[str, Any]]:
    return models._entries(models._load(env.models_file_text(environ)))


def providers_state(environ: Mapping[str, str]) -> str:
    path = env.providers_file_text(environ)
    if not os.path.isfile(path):
        return "missing"
    try:
        providers.validate(path)
    except providers.ProviderError:
        return "invalid"
    return "ok"


def _provider_lines(path: str) -> list[str]:
    """The provider list lines. Lines printed before an error still count, as they did in bash."""
    sink = io.StringIO()
    try:
        with contextlib.redirect_stdout(sink):
            return providers.list_lines(path)
    except providers.ProviderError:
        return sink.getvalue().splitlines()


def key_present(environ: Mapping[str, str], name: str) -> str:
    try:
        providers.key_resolve(env.providers_file_text(environ), name, environ, env.proc_version_file_text(environ))
    except Exception:  # any failure to resolve means no key
        return "no"
    return "yes"


def _healthcheck_state(path: str, name: str) -> str:
    try:
        return "on" if providers.field(path, name, "healthcheck") == "true" else "off"
    except providers.ProviderError:
        return "off"


def provider_records(environ: Mapping[str, str], state: str, issues: list[str]) -> list[str]:
    path = env.providers_file_text(environ)
    if state == "missing":
        return []
    if state == "invalid" and not isinstance(_providers_value(path), dict):
        return []
    out = []
    for line in _provider_lines(path):
        name, _, rest = line.partition(SEP)
        if rest.startswith("invalid:"):
            out.append(f"provider {name} invalid")
            issues.append(f"provider-invalid {name}")
            continue
        transport, base_url, key = (rest.split(SEP) + ["", "", ""])[:3]
        # Keys are not looked up while the file is invalid: every lookup fails.
        present = key_present(environ, name) if state == "ok" else "unknown"
        check = f" healthcheck={_healthcheck_state(path, name)}" if state == "ok" else ""
        out.append(f"provider {name} transport={transport} base_url={base_url} key={key} key_present={present}{check}")
        if transport == "http" and present == "no":
            issues.append(f"key-missing {name}")
    return out


def _providers_value(path: str) -> Any:
    doc = _doc(path)
    return doc.get("providers") if isinstance(doc, dict) else None


def _thinking_roles(model: Mapping[str, Any]) -> list[str]:
    """`thinking_roles=<role>:on|off,...` (effective state per role), only when role_thinking is a non-empty object."""
    overrides = model.get("role_thinking")
    if not isinstance(overrides, dict) or not overrides:
        return []
    states = ",".join(f"{role}:{'on' if models.effective_thinking(model, role) else 'off'}" for role in models.ROLES)
    return [f"thinking_roles={states}"]


def _model_rest(model: Mapping[str, Any], active: Any) -> str:
    context = model.get("context_tokens")
    policy = model.get("oversize_policy")
    return " ".join([
        f"enabled={'no' if model.get('enabled') is False else 'yes'}",
        f"active={'yes' if model.get('id') == active else 'no'}",
        f"roles={','.join(str(r) for r in (models._roles_of(model)))}",
        f"thinking={'on' if model.get('thinking') is True else 'off'}",
        *_thinking_roles(model),
        f"thinking_off={'none' if model.get('thinking_off_options') is None else 'set'}",
        f"context_tokens={'unset' if context is None or context is False else models._interp(context)}",
        f"oversize_policy={'map_reduce(default)' if policy is None or policy is False else models._interp(policy)}",
    ])


def model_records(environ: Mapping[str, str], state: str, issues: list[str]) -> list[str]:
    path = env.providers_file_text(environ)
    doc = models._load(env.models_file_text(environ))
    out = []
    for model in _models_doc(environ):
        model_id = models._interp(model.get("id"))
        rest = _model_rest(model, doc.get("active") if isinstance(doc, dict) else None)
        transport = providers.field(path, model_id.split("/")[0], "transport") if state == "ok" else "opencode"
        out.append(f"model {model_id} {rest} provider_transport={transport}")
        if transport == "http" and "context_tokens=unset" in rest:
            issues.append(f"context-missing {model_id}")
    return out


def breaker_records(environ: Mapping[str, str]) -> list[str]:
    threshold, cooldown = breaker.limits(environ)
    unreachable = breaker.unreachable_cooldown(environ)
    status = "enabled" if threshold < breaker.DISABLED_THRESHOLD else "disabled"
    out = [f"breaker threshold={threshold} default=3 cooldown_seconds={cooldown} default=300 "
           f"unreachable_cooldown_seconds={unreachable} default=120 status={status}"]
    path = env.models_file_text(environ)
    if not models.available(path):
        return out
    for model in _models_doc(environ):
        model_id = models._interp(model.get("id"))
        if models.has_role(path, model_id, "bulk-read"):
            out.append(f"breaker_state {model_id} bulk-read {breaker.status(environ, model_id)}")
        if models.has_role(path, model_id, "code-write"):
            out.append(f"breaker_state {model_id} code-write {breaker.status(environ, model_id + '#code-write')}")
    return out


def _candidates(environ: Mapping[str, str], role: str) -> list[str]:
    path = env.models_file_text(environ)
    if not models.available(path):
        return []
    try:
        return models.candidates(path, role)[1]
    except (RegistryUnreadable, OSError, TypeError, AttributeError):
        return []


def first_choices(environ: Mapping[str, str]) -> list[str]:
    return [f"first_choice {role} {(_candidates(environ, role) or ['none'])[0]}" for role in models.ROLES]


def importable(environ: Mapping[str, str], pstate: str) -> str:
    """The opencode providers the migration would pick up, minus those already on the http transport."""
    if not models.available(env.models_file_text(environ)):
        return ""
    ctx = Ctx(environ=environ)
    if not os.path.isfile(ctx.opencode_json):
        return ""
    http_names: set[str] = set()
    if pstate == "ok":
        table = _providers_value(env.providers_file_text(environ))
        http_names = {k for k, v in table.items() if isinstance(v, dict) and v.get("transport") == "http"}
    return ",".join(p["name"] for p in collect_providers(ctx) if p["name"] not in http_names)


def _counts(environ: Mapping[str, str], rstate: str, pstate: str) -> tuple[int, int, int]:
    """(models, providers, http providers) as the setup verdict needs them."""
    count = len(_models_doc(environ)) if rstate == "ok" else 0
    if pstate == "missing":
        return count, 0, 0
    path = env.providers_file_text(environ)
    value = _providers_value(path)
    if not os.path.isfile(path) or _doc(path) is None:
        return count, 1, 0
    total = 0 if value is None else len(value) if isinstance(value, (dict, list, str)) else 1
    http = 0
    if isinstance(value, dict) and all(v is None or isinstance(v, dict) for v in value.values()):
        http = sum(1 for v in value.values() if v and v.get("transport") == "http")
    return count, total, http


def setup_verdict(environ: Mapping[str, str], rstate: str, pstate: str, found: str, issues: list[str]) -> str:
    count, total, http = _counts(environ, rstate, pstate)
    if rstate != "invalid" and pstate != "invalid" and count == 0 and total == 0:
        return "setup: empty"
    if rstate == "ok" and pstate != "invalid" and http == 0 and found:
        return "setup: opencode-importable"
    return "setup: incomplete" if issues else "setup: ok"


def registry_issues(environ: Mapping[str, str], rstate: str, issues: list[str]) -> None:
    if rstate == "invalid":
        issues.append("registry-invalid models.json")
    elif rstate == "missing":
        issues.append("no-models -")
    elif not _models_doc(environ):
        issues.append("no-models -")
    elif not _candidates(environ, "bulk-read"):
        issues.append("no-bulk-read-model -")


def registry_state(environ: Mapping[str, str]) -> str:
    path = env.models_file_text(environ)
    if not os.path.isfile(path):
        return "missing"
    return "ok" if models.available(path) else "invalid"


def report(environ: Mapping[str, str]) -> list[str]:
    issues: list[str] = []
    rstate, pstate = registry_state(environ), providers_state(environ)
    out = [f"registry: {rstate}", f"providers_file: {pstate}"]
    out += provider_records(environ, pstate, issues)
    if rstate == "ok":
        out += model_records(environ, pstate, issues)
    out += breaker_records(environ)
    retries = selffix.resolve_retries(str(env.self_fix_config_file(environ)),
                                      environ.get("SHUNT_CODE_WRITE_SELF_FIX_RETRIES", ""))
    out.append(f"self_fix_retries={retries} default=1")
    out += first_choices(environ)
    found = importable(environ, pstate)
    present = "present" if os.path.isfile(Ctx(environ=environ).opencode_json) else "absent"
    out.append(f"opencode config={present} importable={found or 'none'}")
    if pstate == "invalid":
        issues.append("providers-invalid providers.json")
    registry_issues(environ, rstate, issues)
    out += [f"issue {issue}" for issue in issues]
    out.append(setup_verdict(environ, rstate, pstate, found, issues))
    return out


def run(_args: Any) -> int:
    try:
        lines = report(os.environ)
    except (RegistryUnreadable, OSError, ValueError, TypeError, AttributeError, KeyError) as exc:
        print(f"shunt: cannot build the dashboard: {type(exc).__name__}", file=sys.stderr)
        return 1
    print("\n".join(lines))
    return 0


def register(subparsers: Any) -> None:
    """Add the `dashboard` command."""
    subparsers.add_parser("dashboard", help="everything the /model-config dashboard shows").set_defaults(func=run)
