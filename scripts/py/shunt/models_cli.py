"""`shunt-models`: the command line of the delegate model registry and its providers.

Port of scripts/shunt-models. The usage lines, the `shunt:` messages, the exit codes and the order of
the checks are those of the bash script. The work is done in process by the modules that held it
before: models (reads, agent files), models_write (the registry writer under its lock), probe (the
small questions), providers and providers_write (providers.json and keys), breaker, context_detect,
migrate and dashboard.

The launcher passes the user's arguments raw (after one `--`), argparse never sees them: a value such
as `--clear` or a JSON body starting with a dash is data here.
"""

import getpass
import io
import os
import re
import sys
from argparse import Namespace
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any

from . import breaker, context_detect, dashboard, env, migrate, models, models_write, probe, providers, providers_write
from .models_write import MAX_CONTEXT_DIGITS
from .models import ROLES, RegistryUnreadable, ShuntError
from .providers import ProviderError

COMMAND = "shunt-models"
AUTH_FAILED_EXIT = 3  # the exit status of detect-context when the provider rejected the key
CODE_WRITE = "code-write"
CLEAR = "--clear"
TRANSPORTS = ("http", "opencode")
_PROVIDER_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
_ENV_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_CONTEXT_RE = re.compile(rf"[1-9][0-9]{{0,{MAX_CONTEXT_DIGITS - 1}}}")
_POSITION_RE = re.compile(r"[0-9]+")
_ROLES_TEXT = " ".join(ROLES)
_PROVIDER_SET_USAGE = ("usage: shunt-models provider set <name> [--transport http|opencode] [--base-url <url>] "
                       "[--key keyring|plaintext|none|env:<VARNAME>] [--healthcheck on|off]")
_MAIN_USAGE = ("usage: shunt-models <list|status|dashboard|add|remove|reorder|activate|enable|disable|thinking|"
               "request-body|roles|set-context|detect-context|oversize-policy|sync|provider|key|"
               "--migrate-from-opencode> [args...]")


class CliError(Exception):
    """A failure printed as `shunt: <message>` with the given exit status."""

    def __init__(self, message: str, code: int = 1) -> None:
        super().__init__(message)
        self.code = code


def _fail(message: str) -> CliError:
    return CliError(message)


def _say(text: str = "") -> None:
    sys.stdout.write(text + "\n")


def _warn(text: str) -> None:
    sys.stderr.write(text + "\n")


# ---------------------------------------------------------------- shared checks

def _models_path() -> str:
    return env.models_file_text(os.environ)


def _providers_path() -> str:
    return env.providers_file_text(os.environ)


def _hint_cmd() -> str:
    """The absolute, shell-quoted path of this script for hints the user copies."""
    script = Path(os.path.abspath(__file__)).parents[2] / COMMAND
    return providers._bash_quote(str(script))


def _registry_available() -> bool:
    path = _models_path()
    return os.path.isfile(path) and models.available(path)


def _require_registry() -> None:
    if not _registry_available():
        raise _fail(f"no models registry at {_models_path()}.")


def _require_entry(model_id: str) -> None:
    """The registry file exists, has a models array and holds model_id. It need not be otherwise valid."""
    path = _models_path()
    if not os.path.isfile(path):
        raise _fail(f"no models registry at {path}.")
    if probe.ask(os.environ, "has-models-array")[1] != 0:
        raise _fail(f"{path} is not a valid models registry.")
    if probe.ask(os.environ, "has-model", model_id)[1] != 0:
        raise _fail(f"model '{model_id}' is not in the registry.")


def _ask_lines(question: str, arg: str = "") -> list[str]:
    lines, code = probe.ask(os.environ, question, arg)
    if code != 0:
        raise CliError("", code)
    return list(lines)


def _write(action: Callable[..., Any], *args: Any) -> Any:
    """Run a models_write function on the registry file under the models lock."""
    path = _models_path()
    with models_write.models_lock(path, os.environ):
        return action(path, *args)


def _require_prompts(roles: Sequence[str]) -> None:
    models.require_prompts(models._prompts_dir(os.environ), roles)


def _materialize(model_id: str) -> None:
    models.materialize_agent(_models_path(), env.agents_dir(os.environ), models._prompts_dir(os.environ), model_id)


def _clear_breaker(model_id: str) -> str | None:
    """Drop the model's breaker state. Returns the problem text, None on success (or no state file)."""
    try:
        breaker.clear_state(os.environ, model_id)
    except (ShuntError, OSError, UnicodeError, ValueError) as exc:
        return str(exc)
    return None


def _clear_breaker_or_warn(model_id: str) -> None:
    problem = _clear_breaker(model_id)
    if problem is not None:
        _warn(f"shunt: {problem}")
        _warn(f"shunt: warning, could not reset the breaker state of '{model_id}'.")


# ---------------------------------------------------------------- registry writes

def cmd_add(args: Sequence[str]) -> int:
    model_id, roles_arg = _arg(args, 0), _arg(args, 1)
    if not model_id:
        raise _fail(f"usage: shunt-models add <provider/model> [<role>[,<role>...]] (roles: {_ROLES_TEXT})")
    roles = models_write.parse_roles(roles_arg) if roles_arg else list(ROLES)
    roles_csv = ",".join(roles)
    provider = model_id.split("/", 1)[0]
    try:
        transport = providers.field(_providers_path(), provider, "transport")
    except ProviderError as exc:
        raise _fail(str(exc)) from None
    if transport != "http":
        opencode_json = f"{env.opencode_config_home(os.environ)}/opencode.json"
        if not os.path.isfile(opencode_json) or probe.ask(os.environ, "opencode-provider", provider)[1] != 0:
            raise _fail(
                f"provider '{provider}' not found in {opencode_json}. Add it to your OpenCode config first, or "
                f"configure it for the HTTP transport with: shunt-models provider set {provider} --transport http "
                "--base-url <url> --key <type>")
    _require_prompts(roles)
    slug = _write(models_write.add, model_id, roles_csv)
    _materialize(model_id)
    _say(f"shunt: added '{model_id}' (agent: {slug}, roles: {roles_csv}).")
    return 0


def cmd_remove(args: Sequence[str]) -> int:
    model_id = _arg(args, 0)
    if not model_id:
        raise _fail("usage: shunt-models remove <provider/model>")
    _require_registry()
    _require_entry(model_id)
    agent = models.agent_for(_models_path(), model_id)
    writer = models.code_writer_agent_for(model_id)
    _write(models_write.remove, model_id)
    # The registry write succeeded: drop the leftovers (agent files, breaker state).
    agents_dir = env.agents_dir(os.environ)
    if agent:
        (agents_dir / f"{agent}.md").unlink(missing_ok=True)
    (agents_dir / f"{writer}.md").unlink(missing_ok=True)
    problem = _clear_breaker(model_id)
    if problem is not None:
        raise _fail(problem)
    _say(f"shunt: removed '{model_id}'.")
    return 0


def cmd_reorder(args: Sequence[str]) -> int:
    model_id, position = _arg(args, 0), _arg(args, 1)
    if not model_id or not position:
        raise _fail("usage: shunt-models reorder <provider/model> <1-based position>")
    if not _POSITION_RE.fullmatch(position):
        raise _fail("position must be a positive integer.")
    _require_registry()
    _require_entry(model_id)
    _write(models_write.reorder, model_id, int(position))
    _say(f"shunt: moved '{model_id}' to position {position}.")
    return 0


def cmd_activate(args: Sequence[str]) -> int:
    model_id = _arg(args, 0)
    if not model_id:
        raise _fail("usage: shunt-models activate <provider/model>")
    _require_registry()
    _require_entry(model_id)
    _write(models_write.activate, model_id)  # refuses a disabled model before it writes
    _say(f"shunt: activated '{model_id}'.")
    return 0


def _set_enabled(value: bool, args: Sequence[str]) -> int:
    verb = "enable" if value else "disable"
    model_id = _arg(args, 0)
    if not model_id:
        raise _fail(f"usage: shunt-models {verb} <provider/model>")
    _require_registry()
    _require_entry(model_id)
    _write(models_write.set_enabled, model_id, value)
    _say(f"shunt: {verb}d '{model_id}'.")
    return 0


def cmd_enable(args: Sequence[str]) -> int:
    return _set_enabled(True, args)


def cmd_disable(args: Sequence[str]) -> int:
    return _set_enabled(False, args)


def cmd_thinking(args: Sequence[str]) -> int:
    model_id, state, options = _arg(args, 0), _arg(args, 1), _arg(args, 2)
    if not model_id or not state:
        raise _fail("usage: shunt-models thinking <provider/model> <on|off> [options-json]")
    if state not in ("on", "off"):
        raise _fail("thinking state must be 'on' or 'off'.")
    _require_registry()
    _require_entry(model_id)
    _write(models_write.thinking, model_id, state, options)
    _materialize(model_id)
    _say(f"shunt: thinking for '{model_id}' set to {state}.")
    return 0


def cmd_request_body(args: Sequence[str]) -> int:
    usage = f"usage: shunt-models request-body <provider/model> [--role <{ROLES[0]}|{ROLES[1]}>] <json-object|--clear>"
    model_id = _arg(args, 0)
    if not model_id:
        raise _fail(usage)
    rest = list(args[1:])
    role = ""
    if rest[:1] == ["--role"]:
        role = _arg(rest, 1)
        if not role:
            raise _fail(usage)
        rest = rest[2:]
    value = _arg(rest, 0)
    if not value or len(rest) != 1:
        raise _fail(usage)
    if role and role not in ROLES:
        raise _fail(f"unknown role '{role}' (roles: {_ROLES_TEXT}).")
    if value != CLEAR and probe.ask(os.environ, "json-object", value)[1] != 0:
        raise _fail(f"request body must be a JSON object: {value}")
    _require_registry()
    _require_entry(model_id)
    outcome = _write(models_write.request_body, model_id, role, value)
    suffix = f" (role {role})" if role else ""
    _say(f"shunt: request body for '{model_id}'{suffix} {outcome}.")
    return 0


def cmd_roles(args: Sequence[str]) -> int:
    model_id, roles_arg = _arg(args, 0), _arg(args, 1)
    if not model_id or not roles_arg:
        raise _fail(f"usage: shunt-models roles <provider/model> <role>[,<role>...] (roles: {_ROLES_TEXT})")
    roles = models_write.parse_roles(roles_arg)
    roles_csv = ",".join(roles)
    # Deliberately not _require_registry: this command repairs a registry that is invalid only
    # because of a bad `roles` value.
    _require_entry(model_id)
    _require_prompts(roles)
    _write(models_write.set_roles, model_id, roles_csv)
    _materialize(model_id)
    _say(f"shunt: roles for '{model_id}' set to {roles_csv}.")
    problem = models.validate(_models_path())
    if problem is not None:
        _warn(f"shunt: warning, the registry is still invalid: shunt: {problem}")
    return 0


def _store_context(model_id: str, tokens: str) -> None:
    if not _CONTEXT_RE.fullmatch(tokens):
        raise _fail(f"tokens must be a positive integer of at most {MAX_CONTEXT_DIGITS} digits.")
    _require_entry(model_id)
    _write(models_write.set_context, model_id, tokens)
    _clear_breaker_or_warn(model_id)  # a missing context window was recorded as a model failure
    _say(f"shunt: context_tokens for '{model_id}' set to {tokens}.")


def cmd_set_context(args: Sequence[str]) -> int:
    model_id, tokens = _arg(args, 0), _arg(args, 1)
    if not model_id or not tokens:
        raise _fail("usage: shunt-models set-context <provider/model> <tokens>")
    _store_context(model_id, tokens)
    return 0


def cmd_detect_context(args: Sequence[str]) -> int:
    model_id, write = _arg(args, 0), _arg(args, 1)
    if not model_id or write not in ("", "--write"):
        raise _fail("usage: shunt-models detect-context <provider/model> [--write]")
    _require_entry(model_id)
    value, status = context_detect.detect(model_id, os.environ)
    if status == AUTH_FAILED_EXIT:
        _warn(f"shunt: auth failed for the provider of '{model_id}' (the key was rejected with 401 or 403): "
              "re-enter the key through /model-config.")
        return AUTH_FAILED_EXIT
    if status != 0 or value is None:
        raise _fail(f"could not detect the context window of '{model_id}' from its provider. "
                    f"Enter it yourself: shunt-models set-context {model_id} <tokens>")
    if write:
        _store_context(model_id, str(value))
    _say(str(value))
    return 0


def cmd_oversize_policy(args: Sequence[str]) -> int:
    model_id, policy = _arg(args, 0), _arg(args, 1)
    usage = "usage: shunt-models oversize-policy <provider/model> <map_reduce|fail|--clear>"
    if policy not in ("map_reduce", "fail", CLEAR) or not model_id:
        raise _fail(usage)
    _require_entry(model_id)
    _write(models_write.set_oversize, model_id, policy)
    _clear_breaker_or_warn(model_id)  # an oversize failure under the old policy counted against the model
    if policy == CLEAR:
        _say(f"shunt: oversize_policy for '{model_id}' cleared (map_reduce applies).")
    else:
        _say(f"shunt: oversize_policy for '{model_id}' set to {policy}.")
    return 0


# ---------------------------------------------------------------- registry reads

def _unavailable_notice() -> str:
    path = _models_path()
    if os.path.isfile(path):
        reason = models.validate(path)
        return f"{'shunt: ' + reason if reason else ''} Delegate calls use the legacy single agent until it is fixed."
    return f"shunt: no models registry at {path} (legacy single-agent mode)."


def cmd_list(_args: Sequence[str]) -> int:
    if not _registry_available():
        _say(_unavailable_notice())
        return 0
    active = next(iter(_ask_lines("active")), "")
    for model_id in _ask_lines("model-ids"):
        _say(f"{model_id} (active)" if model_id == active else model_id)
    return 0


def _first_choice_lines() -> list[str]:
    """The bulk-read and code-write first choice lines of `status`."""
    path = _models_path()
    out = []
    unknown, ids = models.candidates(path, "bulk-read")
    if unknown:
        _warn(f"shunt: models registry's active model '{unknown}' is not in the models list; "
              "falling back to priority order.")
    if ids:
        out.append(f"shunt: first choice: {ids[0]}")
    elif probe.ask(os.environ, "any-enabled")[1] == 0:
        out.append("shunt: no enabled model has the bulk-read role (large reads are not redirected).")
    else:
        out.append("shunt: no enabled models (large reads are not redirected).")
    ids = models.candidates(path, CODE_WRITE)[1]  # quiet: the lookup above already warned
    if ids:
        out.append(f"shunt: code-write first choice: {ids[0]}")
    else:
        out.append("shunt: no enabled model has the code-write role (code-write is unavailable).")
    return out


def cmd_status(_args: Sequence[str]) -> int:
    if not _registry_available():
        _say(_unavailable_notice())
        return 0
    if int((_ask_lines("model-count") or ["0"])[0]) == 0:
        _say("shunt: no delegate models configured (large reads are not redirected).")
        return 0
    for row in _ask_lines("status-rows"):
        _say(row)
    for line in _first_choice_lines():
        _say(line)
    for model_id in _ask_lines("role-ids", CODE_WRITE):  # code-write keeps its own failure counter
        _say(f"shunt: code-write breaker {model_id}: {breaker.status(os.environ, f'{model_id}#{CODE_WRITE}')}")
    return 0


def cmd_sync(_args: Sequence[str]) -> int:
    _require_registry()
    for model_id in _ask_lines("model-ids"):
        _materialize(model_id)
        _say(f"shunt: re-materialized '{model_id}'.")
    return 0


def cmd_dashboard(args: Sequence[str]) -> int:
    if args:
        raise _fail("usage: shunt-models dashboard")
    return dashboard.run(None)


def cmd_migrate(args: Sequence[str]) -> int:
    os.environ["SHUNT_MODELS_HINT_CMD"] = _hint_cmd()  # the hints name this script, as the bash did
    return migrate.run(Namespace(args=list(args)))


# ---------------------------------------------------------------- providers and keys

def _parse_key_spec(spec: str) -> tuple[str, str]:
    """The key type and ref of a --key value. The spec is never echoed back, a pasted key must not leak."""
    if spec in ("keyring", "plaintext", "none"):
        return spec, ""
    if spec.startswith("env:"):
        name = spec[len("env:"):]
        if not _ENV_NAME_RE.fullmatch(name):
            raise _fail("--key env:<VARNAME> needs a valid environment variable name.")
        return "env", name
    raise _fail("--key must be keyring, plaintext, none or env:<VARNAME>. Never pass a key value here, "
                f"store it with: ! {_hint_cmd()} key set <provider>")


def _check_base_url(url: str) -> None:
    code = providers.base_url_check(url)
    if code in (2, 3):
        raise _fail("--base-url must start with http:// or https://.")
    if code != 0:
        raise _fail("--base-url is malformed: it needs a host and must not contain user:password@, "
                    "whitespace or control characters.")


def _parse_provider_options(options: Sequence[str]) -> dict[str, str]:
    """The options of `provider set` after the name, checked in the order the bash loop did."""
    got = {"transport": "", "base_url": "", "healthcheck": "", "key_type": "", "key_ref": ""}
    flags = {"--transport": "transport", "--base-url": "base_url", "--key": "", "--healthcheck": "healthcheck"}
    pos = 0
    while pos < len(options):
        flag = options[pos]
        if len(options) - pos < 2:
            raise _fail(_PROVIDER_SET_USAGE)
        value = options[pos + 1]
        if flag in flags and not value:
            raise _fail(f"{flag} needs a non-empty value.")
        if flag == "--key":
            got["key_type"], got["key_ref"] = _parse_key_spec(value)
        elif flag == "--healthcheck":
            if value not in ("on", "off"):
                raise _fail("--healthcheck must be on or off.")
            got["healthcheck"] = value
        elif flag in flags:
            got[flags[flag]] = value
        else:
            raise _fail(_PROVIDER_SET_USAGE)
        pos += 2
    if got["transport"] and got["transport"] not in TRANSPORTS:
        raise _fail(f"--transport must be one of: {' '.join(TRANSPORTS)}.")
    if got["base_url"]:
        _check_base_url(got["base_url"])
    return got


def _provider_set(args: Sequence[str]) -> int:
    name = _arg(args, 0)
    if not _PROVIDER_NAME_RE.fullmatch(name):
        raise _fail(_PROVIDER_SET_USAGE)
    got = _parse_provider_options(args[1:])
    path = _providers_path()
    try:
        with providers_write._lock(path, os.environ):
            summary = providers_write.set_provider(path, name, got["transport"], got["base_url"],
                                                   got["key_type"], got["key_ref"], got["healthcheck"])
    except ValueError:  # no exception text, it could echo a key
        raise _fail("the value could not be processed (invalid characters).") from None
    _say(f"shunt: provider '{name}' saved ({summary}).")
    if got["key_type"] in ("keyring", "plaintext"):
        _say("shunt: enter the key through /model-config (it opens a password window), or without a desktop: "
             f"! {_hint_cmd()} key set {name}. Never paste it into chat.")
    return 0


def _provider_list() -> int:
    path = _providers_path()
    none = f"shunt: no providers configured in {path}."
    if not os.path.isfile(path):
        _say(none)
        return 0
    if probe.ask(os.environ, "providers-object")[1] != 0:
        raise _fail(f'{path} is invalid JSON or has no "providers" object.')
    if probe.ask(os.environ, "providers-empty")[1] == 0:
        _say(none)
        return 0
    status = providers.run(Namespace(providers_command="list-lines"))
    if status != 0:
        return status
    try:
        providers.validate(path)
    except ProviderError:
        raise _fail(f"{path} has invalid entries (marked above). Fix them before using those providers.") from None
    return 0


def cmd_provider(args: Sequence[str]) -> int:
    action = _arg(args, 0)
    if action == "set":
        return _provider_set(args[1:])
    if action == "list":
        return _provider_list()
    raise _fail("usage: shunt-models provider <set|list> [args...]")


def _read_key() -> str:
    """One key line: from the terminal without echo, or from stdin when it is not a terminal."""
    if sys.stdin is not None and sys.stdin.isatty():
        try:
            return getpass.getpass("API key (input hidden): ")
        except EOFError:  # Ctrl-D: an empty key, as `read ... || true` gave
            return ""
        except UnicodeError:  # no exception text, it could carry a byte of the key
            raise _fail("the key could not be processed (invalid characters).") from None
    return providers_write._read_key_line()


def _store_key(provider: str, key_type: str) -> None:
    key = _read_key()
    if not key:
        raise _fail("empty key, nothing stored.")
    try:
        if key_type == "keyring":
            data = io.BytesIO(key.encode("utf-8", "surrogateescape") + b"\n")
            providers.keyring_store(provider, env.proc_version_file_text(os.environ), data)
        else:
            path = _providers_path()
            with providers_write._lock(path, os.environ):
                providers_write.plaintext_store(path, provider, key)
    except ValueError:  # no exception text, it could echo the key
        raise _fail("the key could not be processed (invalid characters).") from None
    except ProviderError as exc:
        raise CliError(str(exc)) from None
    if key_type != "keyring":
        _warn(providers.plaintext_warning(_providers_path()))
    _say(f"shunt: key stored for '{provider}' (type {key_type}).")


def _key_set(provider: str, key_type: str) -> int:
    if key_type == "env":
        raise _fail(f"provider '{provider}' uses an env key: export the variable named in its key.ref instead.")
    if key_type == "none":
        raise _fail(f"provider '{provider}' has key type none, there is no key to set.")
    if key_type == "keyring" and not providers.keyring_backend(env.proc_version_file_text(os.environ)):
        raise _fail("no keyring backend found (secret-tool, security, kwallet-query). Use an env key type instead.")
    _store_key(provider, key_type)
    return 0


def _key_status(provider: str, key_type: str) -> int:
    if key_type == "none":
        _say(f"shunt: provider '{provider}': yes (type none, no key needed)")
        return 0
    try:
        providers.key_resolve(_providers_path(), provider, os.environ, env.proc_version_file_text(os.environ))
        found = "yes"
    except (ProviderError, OSError, ValueError):
        found = "no"
    _say(f"shunt: provider '{provider}': {found} (type {key_type})")
    return 0


def cmd_key(args: Sequence[str]) -> int:
    action, provider = _arg(args, 0), _arg(args, 1)
    if not provider:
        raise _fail("usage: shunt-models key <set|status> <provider>")
    if not _PROVIDER_NAME_RE.fullmatch(provider):
        lines, _code = probe.ask(os.environ, "provider-name-refusal", provider)
        _warn("\n".join(lines))
        return 1
    path = _providers_path()
    if not os.path.isfile(path) or probe.ask(os.environ, "provider-exists", provider)[1] != 0:
        raise _fail(f"provider '{provider}' is not in {path}.")
    try:
        key_type = providers.field(path, provider, "key-type")
    except ProviderError as exc:
        raise _fail(str(exc)) from None
    if action == "set":
        return _key_set(provider, key_type)
    if action == "status":
        return _key_status(provider, key_type)
    raise _fail("usage: shunt-models key <set|status> <provider>")


# ---------------------------------------------------------------- entry

def _arg(args: Sequence[str], index: int) -> str:
    return args[index] if index < len(args) else ""


_COMMANDS: Mapping[str, Callable[[Sequence[str]], int]] = {
    "add": cmd_add, "remove": cmd_remove, "reorder": cmd_reorder, "activate": cmd_activate,
    "enable": cmd_enable, "disable": cmd_disable, "thinking": cmd_thinking, "request-body": cmd_request_body,
    "roles": cmd_roles, "set-context": cmd_set_context, "detect-context": cmd_detect_context,
    "oversize-policy": cmd_oversize_policy, "provider": cmd_provider, "list": cmd_list, "status": cmd_status,
    "dashboard": cmd_dashboard, "sync": cmd_sync, "key": cmd_key, "--migrate-from-opencode": cmd_migrate,
}


def _report(message: str, code: int) -> int:
    if message:
        _warn(f"shunt: {message}")
    return code


def main(argv: Sequence[str]) -> int:
    """Run one shunt-models command. argv is what the user typed after the script name."""
    try:
        if not argv or not argv[0]:
            raise _fail(_MAIN_USAGE)
        handler = _COMMANDS.get(argv[0])
        if handler is None:
            raise _fail(f"unknown subcommand: {argv[0]}")
        return handler(argv[1:])
    except CliError as exc:
        return _report(str(exc), exc.code)
    except ProviderError as exc:
        return _report(str(exc), exc.code)
    except RegistryUnreadable as exc:
        return _report(str(exc), 2)
    except (ShuntError, OSError, UnicodeError, ValueError) as exc:
        return _report(str(exc), 1)
    except KeyboardInterrupt:
        return 130
