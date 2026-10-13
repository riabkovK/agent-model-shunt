"""HTTP transport: one non-streaming POST to <base_url>/chat/completions of an
OpenAI-compatible provider, normalized into the response format of transport.sh.

Port of scripts/lib/transport-http.sh (setup, size guard, request, reply
checks). The total deadline, the chunking and the temp file cleanup stay in
bash until sub-phase 9: the wrapper passes the max time of each request in
SHUNT_HTTP_MAX_TIME and runs map_reduce when `http-call` exits 90.

Status mapping (the SHUNT_TRY_INVOKE_* codes of transport.sh, see transport_reply):
  timeout                              TIMEOUT (the wrapper makes it DEADLINE when the
                                       request's max time was cut to the total deadline)
  other transport failure, 429, 5xx,
  400/404/413 and any other non-2xx    ERROR (model failure, the breaker counts it)
  401, 403                             AUTH (a key problem, the failover skips the breaker)
  2xx, text empty                      EMPTY
  2xx, finish_reason not "stop"        ERROR (a cut off answer is unusable)
  2xx, not a chat completion           ERROR
  input over the context budget        OVERSIZE (map_reduce: exit 90 for a bulk-reader)
  missing key, bad base_url, request_body, oversize policy, no context_tokens,
  missing role prompt                  CONFIG (nothing sent)

Secret rules: the key lives only in this process: it is put into the
Authorization header of the one request and into the scrubber of the error
excerpt. It is never in argv, a file, a child environment or a message. Redirects
are never followed, so the header cannot be replayed to another host.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn

from . import env, httpclient, models, providers
from . import transport_reply as reply
from .transport_reply import AUTH, CONFIG, EMPTY, ERROR, NEEDS_CHUNKING, OVERSIZE, TIMEOUT

BYTES_PER_TOKEN = 3
CONTEXT_BUDGET_PERCENT = 60
UNKNOWN_CONTEXT_MAX_TOKENS = 4000
MAX_CONTEXT_DIGITS = 12
DEFAULT_OVERSIZE_POLICY = "map_reduce"
DEFAULT_TIMEOUT_SECONDS = "300"
FINISH_REASON_CHARS = 40
OUT_PREFIX = "shunt-opencode."  # the name shunt_tmpfile gives, the caller removes the file
_CONTEXT_RE = re.compile(r"[1-9][0-9]*")
_TIME_RE = re.compile(r"[0-9]+(?:\.[0-9]*)?|\.[0-9]+")
_CAMEL_RE = re.compile(r"(?P<a>[a-z0-9])(?P<b>[A-Z])")
_CAMEL_RUN_RE = re.compile(r"(?P<a>[A-Z]+)(?P<b>[A-Z][a-z])")
_STATUS_BEATS_SIZE = (401, 403, 429)
_KEY_ROLE = {"bulk-reader": "bulk-read", "code-writer": "code-write"}


class _Stop(Exception):
    """End the call with this SHUNT_TRY_INVOKE_* status. The reason is already on stderr."""

    def __init__(self, status: int) -> None:
        super().__init__(status)
        self.status = status


def _fail(status: int, message: str = "") -> NoReturn:
    if message:
        sys.stderr.write(f"shunt: {message}\n")
    raise _Stop(status)


@dataclass(frozen=True)
class _Setup:
    model_id: str
    role: str
    provider: str
    base_url: str
    assumed_https: bool
    body: Mapping[str, Any]
    system: bytes
    context_tokens: str
    policy: str


# ---------------------------------------------------------------- registry

def _text(value: Any) -> str:
    """jq tostring for the optional registry fields: null and false mean absent."""
    if value is None or value is False:
        return ""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return value if isinstance(value, str) else json.dumps(value, separators=(",", ":"))
    try:
        return str(int(value // 1))
    except (OverflowError, ValueError):
        return json.dumps(value)


def _find_model(agent: str, path: str) -> tuple[dict[str, Any], str]:
    """The registry entry whose bulk-reader or code-writer agent is `agent`, and the role."""
    if not models.available(path):
        _fail(CONFIG, f"no model in the registry for agent '{agent}'.")
    for model in models._entries(models._load(path)):
        model_id = str(model.get("id"))
        named = model.get("agent")
        bulk = models.slug(model_id) if named is None or named is False or named == "" else str(named)
        if agent == bulk:
            return model, "bulk-reader"
        if agent == models.code_writer_agent_for(model_id):
            return model, "code-writer"
    _fail(CONFIG, f"no model in the registry for agent '{agent}'.")


def _check_base_url(provider: str, url: str) -> tuple[str, bool]:
    code = providers.base_url_check(url)
    if code == 0:
        return url, False
    if code == 3:
        return "https://" + url, True
    if code == 2:
        _fail(CONFIG, f"provider '{provider}': base_url scheme must be http:// or https:// "
                      "(config problem, no request sent).")
    _fail(CONFIG, f"provider '{provider}': base_url is malformed or has credentials in it "
                  "(config problem, no request sent).")


def _snake_key(key: str) -> str:
    if not re.search("[A-Z]", key):
        return key
    key = _CAMEL_RE.sub(r"\g<a>_\g<b>", key)
    key = _CAMEL_RUN_RE.sub(r"\g<a>_\g<b>", key)
    return key.translate({c: c + 32 for c in range(ord("A"), ord("Z") + 1)})


def _snake(value: Any, model_id: str, field: str) -> Any:
    if isinstance(value, list):
        return [_snake(v, model_id, field) for v in value]
    if not isinstance(value, dict):
        return value
    converted: dict[str, Any] = {}
    seen = sorted(value)
    names = {k: _snake_key(k) for k in seen}
    clash = sorted(n for n in set(names.values()) if list(names.values()).count(n) > 1)
    if clash:
        shown = re.split(r'[\\"]', clash[0])[0]
        _fail(CONFIG, f"model '{model_id}': {field} has keys that collide after snake_case "
                      f"conversion (key '{shown}').")
    for key in value:
        converted[names[key]] = _snake(value[key], model_id, field)
    return converted


def _request_body(model: Mapping[str, Any], role: str, model_id: str) -> dict[str, Any]:
    """request_body, then the thinking options (snake_case), then the role's keys, later wins."""
    base = model.get("request_body")
    base = {} if base is None or base is False else base
    role_bodies = model.get("role_request_body")
    role_bodies = {} if role_bodies is None or role_bodies is False else role_bodies
    field = "thinking_options" if model.get("thinking") is True else "thinking_off_options"
    think = model.get(field)
    if not isinstance(base, dict):
        _fail(CONFIG, f"model '{model_id}': request_body must be a JSON object.")
    if not isinstance(role_bodies, dict) or not all(isinstance(v, dict) for v in role_bodies.values()):
        _fail(CONFIG, f"model '{model_id}': role_request_body must be a JSON object of JSON objects.")
    if think is not None and not isinstance(think, dict):
        _fail(CONFIG, f"model '{model_id}': {field} must be a JSON object or null.")
    merged = dict(base)
    merged.update(_snake(think or {}, model_id, field))
    merged.update(role_bodies.get(_KEY_ROLE[role]) or {})
    return merged


def _system_prompt(role: str, environ: Mapping[str, str]) -> bytes:
    path = Path(models._prompts_dir(environ)) / f"{role}.md"
    try:
        data = path.read_bytes()
    except OSError:
        _fail(CONFIG, f"the {role} prompt is missing at {path} (incomplete plugin install).")
    return data.replace(b"\0", b"").rstrip(b"\n")  # bash read it through $(<file)


def _setup(agent: str, environ: Mapping[str, str]) -> _Setup:
    model, role = _find_model(agent, str(env.models_file(environ)))
    model_id = str(model.get("id"))
    provider = model_id.split("/", 1)[0]
    try:
        raw_url = providers.field(env.providers_file_text(environ), provider, "base-url")
    except providers.ProviderError as exc:
        _fail(CONFIG, str(exc))
    base_url, assumed = _check_base_url(provider, raw_url)
    body = _request_body(model, role, model_id)
    return _Setup(model_id, role, provider, base_url, assumed, body, _system_prompt(role, environ),
                  _text(model.get("context_tokens")), _text(model.get("oversize_policy")))


# ---------------------------------------------------------------- prompt and size guard

def _read_attached(name: str) -> bytes:
    path = Path(name)
    if not path.is_file() or not os.access(path, os.R_OK):
        _fail(CONFIG, f"cannot read attached file '{name}'.")
    try:
        return path.read_bytes()
    except OSError:
        _fail(CONFIG, f"cannot read attached file '{name}'.")


def build_prompt(question: str, files: Sequence[str]) -> bytes:
    """The question, then each attached file in a labelled block."""
    parts = [question.encode("utf-8", "surrogateescape") + b"\n"]
    for name in files:
        label = name.encode("utf-8", "surrogateescape")
        parts += [b"\n--- file: " + label + b" ---\n", _read_attached(name), b"\n--- end of file ---\n"]
    return b"".join(parts)


def _guard_size(setup: _Setup, size: int) -> None:
    """Return when the request may be sent. Otherwise explain and stop (NEEDS_CHUNKING says nothing)."""
    tokens = -(-size // BYTES_PER_TOKEN)
    context = setup.context_tokens
    if context and not (_CONTEXT_RE.fullmatch(context) and len(context) <= MAX_CONTEXT_DIGITS):
        _fail(CONFIG, f"model {setup.model_id} has an invalid context_tokens in models.json (config problem, "
                      f"no request sent). Run: shunt-models set-context {setup.model_id} <tokens>.")
    if not context:
        if tokens <= UNKNOWN_CONTEXT_MAX_TOKENS:
            return
        _fail(CONFIG, f"model {setup.model_id} has no context_tokens. Run: shunt-models detect-context "
                      f"{setup.model_id} --write, or shunt-models set-context {setup.model_id} <tokens> "
                      "(config problem, no request sent).")
    budget = int(context) * CONTEXT_BUDGET_PERCENT // 100
    if tokens <= budget:
        return
    policy = setup.policy or DEFAULT_OVERSIZE_POLICY
    if setup.role != "code-writer" and policy == "map_reduce":
        raise _Stop(NEEDS_CHUNKING)
    sys.stderr.write(f"shunt: model {setup.model_id}: input is too large for the model "
                     f"(about {tokens} tokens, budget {budget}), no request sent.\n")
    if policy in ("fail", "map_reduce"):
        raise _Stop(OVERSIZE)
    _fail(CONFIG, f"model {setup.model_id} has an invalid oversize_policy (config problem).")


# ---------------------------------------------------------------- request

def _timeout(environ: Mapping[str, str]) -> float | None:
    raw = environ.get("SHUNT_HTTP_MAX_TIME") or environ.get("SHUNT_TIMEOUT_SECONDS") or DEFAULT_TIMEOUT_SECONDS
    if not _TIME_RE.fullmatch(raw):
        _fail(CONFIG, "the request time limit must be a non-negative number of seconds "
                      "(config problem, no request sent).")
    return float(raw) or None


def _models_command() -> str:
    root = Path(os.path.abspath(__file__)).parents[3]
    return providers._bash_quote(str(root / "scripts" / "shunt-models"))


def _transport_failure(setup: _Setup, err: httpclient.HttpError, environ: Mapping[str, str],
                       key: str | None) -> NoReturn:
    provider = setup.provider
    if err.kind == "timeout":
        raise _Stop(TIMEOUT)
    # An auth or rate limit status says more than the size of its body.
    if err.kind == "too_large" and err.status in _STATUS_BEATS_SIZE:
        _check_status(setup, httpclient.Response(err.status, {}, b""), key)
    if err.kind == "too_large":
        _fail(ERROR, f"provider '{provider}' sent a response larger than "
                     f"{httpclient.max_response_bytes(environ)} bytes.")
    sys.stderr.write(f"shunt: request to provider '{provider}' failed (curl exit {err.curl_exit}): {err}\n")
    if setup.assumed_https:
        sys.stderr.write(f"shunt: provider '{provider}': cannot reach {setup.base_url} (no scheme in base_url, "
                         "https was assumed; write http://... explicitly for a plain http endpoint).\n")
    raise _Stop(ERROR)


def _check_status(setup: _Setup, response: httpclient.Response, key: str | None) -> None:
    provider, code = setup.provider, response.status
    if response.ok:
        return
    if code in (401, 403):
        _fail(AUTH, f"auth failed for provider {provider}: the key was rejected or is missing. Re-enter it "
                    f"through /model-config (it opens a password window), or without a desktop: "
                    f"! {_models_command()} key set {providers._bash_quote(provider)}")
    if code in (400, 404, 413):
        _fail(ERROR, f"provider '{provider}' answered HTTP {code}: {reply.excerpt(response.body, key)}")
    _fail(ERROR, f"provider '{provider}' answered HTTP {code}.")


def _answer(setup: _Setup, response: httpclient.Response, key: str | None) -> dict[str, Any]:
    normalized = reply.normalize(response.body)
    if normalized is None:
        _fail(ERROR, f"provider '{setup.provider}' sent a reply that is not a chat completion.")
    finish = reply.finish_text(normalized["finish_reason"])
    if finish and finish != "stop":
        shown = reply.excerpt(finish.encode("utf-8", "surrogateescape"), key)[:FINISH_REASON_CHARS]
        _fail(ERROR, f"provider '{setup.provider}' ended the answer with finish_reason '{shown}'.")
    if not normalized["text"]:
        raise _Stop(EMPTY)
    return normalized


def _send(setup: _Setup, prompt: bytes, environ: Mapping[str, str]) -> dict[str, Any]:
    timeout = _timeout(environ)
    try:
        key = providers.bearer_key(env.providers_file_text(environ), setup.provider, environ,
                                   env.proc_version_file_text(environ))
    except providers.ProviderError as exc:
        _fail(CONFIG if exc.code == providers.EXIT_CONFIG else ERROR, str(exc))
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    messages = [{"role": "system", "content": setup.system.decode("utf-8", "replace")},
                {"role": "user", "content": prompt.decode("utf-8", "replace")}]
    payload = {**setup.body, "model": setup.model_id.split("/", 1)[-1], "messages": messages}
    url = setup.base_url[:-1] if setup.base_url.endswith("/") else setup.base_url
    try:
        response = httpclient.post_json(url + "/chat/completions", payload, headers=headers, timeout=timeout,
                                        max_bytes=httpclient.max_response_bytes(environ))
    except httpclient.HttpError as err:
        _transport_failure(setup, err, environ, key)
    _check_status(setup, response, key)
    return _answer(setup, response, key)


def _write_reply(normalized: dict[str, Any], environ: Mapping[str, str]) -> str:
    try:
        fd, path = tempfile.mkstemp(prefix=OUT_PREFIX, dir=str(env.tmp_dir(environ)))
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(reply.dump(normalized))
    except OSError:
        _fail(ERROR, "cannot create a temp file for the reply.")
    return path


# ---------------------------------------------------------------- entry points

def http_call(agent: str, question: str, files: Sequence[str], environ: Mapping[str, str]) -> str:
    """The whole call except chunking: setup, prompt, size guard, request. Returns the reply file."""
    setup = _setup(agent, environ)
    prompt = build_prompt(question, files)
    _guard_size(setup, len(setup.system) + len(prompt))
    return _write_reply(_send(setup, prompt, environ), environ)


def http_ask(agent: str, prompt_file: str, environ: Mapping[str, str]) -> str:
    """One request for a prompt already in a file (a chunk or merge request, no size guard)."""
    setup = _setup(agent, environ)
    return _write_reply(_send(setup, _read_attached(prompt_file), environ), environ)


def run(args: argparse.Namespace) -> int:
    environ = os.environ
    try:
        if args.transport_command == "http-call":
            path = http_call(args.agent, args.question, args.files, environ)
        else:
            path = http_ask(args.agent, args.prompt_file, environ)
    except _Stop as stop:
        return stop.status
    except BrokenPipeError:
        raise
    except (OSError, models.RegistryUnreadable) as exc:  # paths and strerror text, never a key
        sys.stderr.write(f"shunt: {exc}\n")
        return CONFIG
    sys.stdout.write(path + "\n")
    return 0


def register(subparsers: Any) -> None:
    """Add the `transport` command group to the top-level subparsers."""
    group = subparsers.add_parser("transport", help="send one request through the HTTP transport")
    group.set_defaults(func=run)
    sub = group.add_subparsers(dest="transport_command", required=True)
    call = sub.add_parser("http-call")
    call.add_argument("agent")
    call.add_argument("question")
    call.add_argument("files", nargs="*")
    ask = sub.add_parser("http-ask")
    ask.add_argument("agent")
    ask.add_argument("prompt_file")
