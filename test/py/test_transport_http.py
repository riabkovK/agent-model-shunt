"""The HTTP transport against the scripted local server (port of transport-http.sh)."""

import json
import os
import re
import subprocess
import sys

import pytest

from conftest import REPO_ROOT, SHUNT_MAIN
from shunt import httpclient, transport_http
from shunt import transport_reply as reply

KEY = "sk-super-secret-value-123"
AGENT = "shunt-bulk-reader-acme-m1"
WRITER = "shunt-code-writer-acme-m1"
ROUTE = "/v1/chat/completions"
OK = {"choices": [{"message": {"content": "hello there"}, "finish_reason": "stop"}],
      "usage": {"prompt_tokens": 12, "completion_tokens": 5}}


@pytest.fixture
def world(tmp_path, http_server):
    """Registry, providers and prompts for `acme/m1`. Returns an object with environ and helpers."""
    prompts = tmp_path / "prompts"
    prompts.mkdir()
    (prompts / "bulk-reader.md").write_text("You read.\n\n")
    (prompts / "code-writer.md").write_text("You write.\n")

    class World:
        server = http_server
        environ = {**os.environ, "SHUNT_MODELS_FILE": str(tmp_path / "models.json"),
                   "SHUNT_PROVIDERS_FILE": str(tmp_path / "providers.json"),
                   "SHUNT_PROMPTS_DIR": str(prompts), "ACME_KEY": KEY,
                   "SHUNT_TIMEOUT_SECONDS": "5"}

        def registry(self, **fields):
            model = {"id": "acme/m1", "agent": AGENT, "enabled": True, **fields}
            (tmp_path / "models.json").write_text(json.dumps({"version": 1, "models": [model]}))

        def providers(self, base_url=None, key=None):
            key = key or {"type": "env", "ref": "ACME_KEY"}
            doc = {"version": 1, "providers": {"acme": {
                "transport": "http", "base_url": http_server.url + "/v1" if base_url is None else base_url, "key": key}}}
            (tmp_path / "providers.json").write_text(json.dumps(doc))

        def call(self, question="q", files=(), agent=AGENT, environ=None):
            return transport_http.http_call(agent, question, list(files), environ or self.environ)

        def sent(self, n=-1):
            return json.loads(http_server.requests[n].body)

    w = World()
    w.registry()
    w.providers()
    http_server.script(ROUTE, body=OK)
    return w


def status_of(world, capsys, **kwargs):
    """Run a call and return (status, stderr)."""
    try:
        path = world.call(**kwargs)
    except transport_http._Stop as stop:
        return stop.status, capsys.readouterr().err
    return (0, path), capsys.readouterr().err


def test_status_codes_match_transport_sh():
    text = (REPO_ROOT / "scripts" / "lib" / "transport.sh").read_text()
    shell = {n: int(v) for n, v in re.findall(r"^SHUNT_TRY_INVOKE_([A-Z]+)=(\d+)", text, re.M)}
    assert shell == {"TIMEOUT": reply.TIMEOUT, "ERROR": reply.ERROR, "EMPTY": reply.EMPTY, "AUTH": reply.AUTH,
                     "DEADLINE": 5, "OVERSIZE": reply.OVERSIZE, "CONFIG": reply.CONFIG}


def test_success_writes_the_normalized_reply(world):
    path = world.call("the question")
    doc = json.loads(open(path).read())
    assert doc == {"text": "hello there", "finish_reason": "stop", "usage": {"input": 12, "output": 5}}
    assert oct(os.stat(path).st_mode & 0o777) == "0o600"
    assert os.path.basename(path).startswith("shunt-opencode.")
    sent = world.sent()
    assert sent["model"] == "m1"
    assert sent["messages"][0] == {"role": "system", "content": "You read."}  # trailing newlines stripped
    assert sent["messages"][1] == {"role": "user", "content": "the question\n"}
    assert "max_tokens" not in sent and "stream" not in sent


def test_cost_is_kept_only_when_a_non_negative_number(world):
    world.server.script(ROUTE, body={**OK, "usage": {"prompt_tokens": 1, "completion_tokens": 2, "cost": 0.0125}})
    assert json.load(open(world.call()))["cost"] == 0.0125
    world.server.script(ROUTE, body={**OK, "cost": -1, "usage": {"prompt_tokens": -4, "completion_tokens": "x"}})
    doc = json.load(open(world.call()))
    assert "cost" not in doc and doc["usage"] == {"input": 0, "output": 0}


def test_the_key_goes_in_the_authorization_header_only(world, tmp_path, capsys):
    world.call()
    request = world.server.requests[0]
    assert request.headers["authorization"] == f"Bearer {KEY}"
    assert request.path == ROUTE
    assert KEY not in request.body.decode()
    leftovers = [p for p in (tmp_path / "tmp").iterdir()]
    assert len(leftovers) == 1  # the reply file only
    assert KEY not in leftovers[0].read_text()
    assert KEY not in capsys.readouterr().err


def test_cli_prints_only_the_path_and_the_key_is_not_in_argv_or_output(world, tmp_path):
    argv = [sys.executable, "-I", "-B", str(SHUNT_MAIN), "transport", "http-call", "--", AGENT, "--q", "-x"]
    done = subprocess.run(argv, env=world.environ, capture_output=True, text=True, check=False)
    assert done.returncode == reply.CONFIG  # the attached file "-x" does not exist
    argv = argv[:-1]
    done = subprocess.run(argv, env=world.environ, capture_output=True, text=True, check=False)
    assert done.returncode == 0 and done.stderr == ""
    path = done.stdout.strip()
    assert json.load(open(path))["text"] == "hello there"
    assert world.sent()["messages"][1]["content"] == "--q\n"
    assert KEY not in " ".join(argv) + done.stdout + done.stderr


def test_key_type_none_sends_no_authorization_header(world):
    world.providers(key={"type": "none"})
    world.call()
    assert "authorization" not in world.server.requests[0].headers


@pytest.mark.parametrize("code", [429, 500, 502, 503, 301, 418])
def test_other_statuses_are_errors(world, capsys, code):
    world.server.script(ROUTE, status=code, body="oops")
    status, err = status_of(world, capsys)
    assert status == reply.ERROR
    assert f"answered HTTP {code}." in err


@pytest.mark.parametrize("code", [400, 404, 413])
def test_client_errors_show_a_scrubbed_excerpt(world, capsys, code):
    body = '{"error":"bad\x1b[31m request %s %s"}' % (KEY, "x" * 1000)
    world.server.script(ROUTE, status=code, body=body)
    status, err = status_of(world, capsys)
    assert status == reply.ERROR
    assert "bad" in err and KEY not in err and "\x1b" not in err
    assert len(err) < 500


@pytest.mark.parametrize("code", [401, 403])
def test_auth_failures_ask_for_a_new_key(world, capsys, code):
    world.server.script(ROUTE, status=code, body="no")
    status, err = status_of(world, capsys)
    assert status == reply.AUTH
    assert "auth failed for provider acme" in err and "/model-config" in err
    assert f"! {REPO_ROOT}/scripts/shunt-models key set acme" in err
    assert KEY not in err


@pytest.mark.parametrize("code,expected", [(401, reply.AUTH), (429, reply.ERROR)])
def test_a_status_beats_an_oversized_body(world, capsys, code, expected):
    world.server.script(ROUTE, status=code, body="x" * 3000)
    world.environ["SHUNT_HTTP_MAX_RESPONSE_BYTES"] = "1000"
    status, err = status_of(world, capsys)
    assert status == expected
    assert "larger than" not in err


def test_oversized_reply_is_an_error_naming_the_cap(world, capsys):
    world.server.script(ROUTE, body="x" * 3000, chunked=True)
    world.environ["SHUNT_HTTP_MAX_RESPONSE_BYTES"] = "1000"
    status, err = status_of(world, capsys)
    assert status == reply.ERROR and "response larger than 1000 bytes" in err


def test_default_response_cap_is_16_mib():
    assert httpclient.max_response_bytes({}) == 16 * 1024 * 1024


def test_error_excerpt_never_echoes_the_key_or_request_headers(world, capsys):
    # A server that reflects what it was sent, including the Authorization header.
    world.server.script(ROUTE, status=400, body=json.dumps({"echo": f"Authorization: Bearer {KEY}", "k": KEY}))
    status, err = status_of(world, capsys)
    assert status == reply.ERROR
    assert KEY not in err and "[redacted]" in err


@pytest.mark.parametrize("key", ["sk-live/abcdef0123456789secret", "ab\tc-é-KEY123", 'q"uo\\te-KEY'])
def test_excerpt_scrubs_every_spelling_of_the_key(key):
    spellings = [key, json.dumps(key)[1:-1], json.dumps(key)[1:-1].replace("/", "\\/"),
                 json.dumps(key, ensure_ascii=True)[1:-1]]
    body = " | ".join(spellings).encode("utf-8")
    shown = reply.excerpt(body, key)
    assert "KEY123" not in shown and "abcdef0123" not in shown and "uo" not in shown.replace("[redacted]", "")


def test_excerpt_lowercases_u_escapes_and_scrubs_the_all_escaped_form():
    key = "abé"
    body = b'{"e":"\\u0061\\u0062\\u00E9 and ab\\u00E9"}'
    assert reply.excerpt(body, key).count("[redacted]") == 2


def test_excerpt_is_cut_to_300_characters():
    assert len(reply.excerpt(b"y" * 5000, KEY)) == 300


def test_empty_text_finish_reason_and_bad_bodies(world, capsys):
    world.server.script(ROUTE, body={**OK, "choices": [{"message": {"content": ""}, "finish_reason": "stop"}]})
    assert status_of(world, capsys)[0] == reply.EMPTY
    world.server.script(ROUTE, body={**OK, "choices": [{"message": {"content": "cut"}, "finish_reason": "length"}]})
    status, err = status_of(world, capsys)
    assert status == reply.ERROR and "finish_reason 'length'" in err
    for body in ("not json", "[]", "null", '{"choices":[]}', '{"choices":["x"]}', '{"choices":{"a":1}}'):
        world.server.script(ROUTE, body=body)
        status, err = status_of(world, capsys)
        assert status == reply.ERROR and "not a chat completion" in err, body


def test_a_finish_reason_that_echoes_the_key_is_scrubbed(world, capsys):
    world.server.script(ROUTE, body={**OK, "choices": [{"message": {"content": "cut"}, "finish_reason": f"x {KEY}"}]})

    status, err = status_of(world, capsys)

    assert status == reply.ERROR and "finish_reason 'x [redacted]'" in err and KEY not in err


def test_a_missing_finish_reason_and_non_string_content_are_normalized():
    assert reply.normalize(b'{"choices":[{"message":{"content":5}}]}') == {"text": "", "finish_reason": ""}
    assert reply.normalize(b'{"choices":[null]}') == {"text": "", "finish_reason": ""}
    assert reply.normalize(b'{"choices":[{"message":"x"}]}') is None


def test_timeout_is_reported_as_timeout(world, capsys):
    world.server.script(ROUTE, body=OK, delay=3)
    world.environ["SHUNT_TIMEOUT_SECONDS"] = "0.3"
    assert status_of(world, capsys)[0] == reply.TIMEOUT


def test_dropped_connection_is_an_error_with_the_curl_exit(world, capsys):
    world.server.script(ROUTE, drop=True)
    status, err = status_of(world, capsys)
    assert status == reply.ERROR and "(curl exit 52)" in err and KEY not in err


def test_scheme_less_base_url_assumes_https_and_says_so(world, capsys):
    world.providers(base_url=f"127.0.0.1:{world.server.port}/v1")
    status, err = status_of(world, capsys)
    assert status == reply.ERROR
    assert f"cannot reach https://127.0.0.1:{world.server.port}/v1" in err and "https was assumed" in err


def test_explicit_http_base_url_has_no_https_hint(world, capsys):
    world.providers(base_url="http://127.0.0.1:1/v1")
    status, err = status_of(world, capsys)
    assert status == reply.ERROR and "https was assumed" not in err


@pytest.mark.parametrize("url,message", [
    ("ftp://api.acme.test/v1", "base_url scheme must be http:// or https://"),
    ("http://localhost@evil.test/v1", "has credentials"),
    ("", "malformed or has credentials"),
])
def test_bad_base_urls_are_config_errors_and_send_nothing(world, capsys, url, message):
    world.providers(base_url=url)
    status, err = status_of(world, capsys)
    assert status == reply.CONFIG and message in err
    assert world.server.requests == []


def test_a_trailing_slash_of_the_base_url_is_dropped(world):
    world.providers(base_url=world.server.url + "/v1/")
    world.call()
    assert world.server.requests[0].path == ROUTE


def test_missing_key_is_a_config_error(world, capsys):
    del world.environ["ACME_KEY"]
    status, err = status_of(world, capsys)
    assert status == reply.CONFIG and "ACME_KEY" in err and world.server.requests == []


def test_registry_and_prompt_problems_are_config_errors(world, capsys, tmp_path):
    status, err = status_of(world, capsys, agent="shunt-bulk-reader-nope")
    assert status == reply.CONFIG and "no model in the registry for agent" in err
    world.environ["SHUNT_PROMPTS_DIR"] = str(tmp_path / "none")
    status, err = status_of(world, capsys)
    assert status == reply.CONFIG and "bulk-reader prompt is missing" in err
    world.environ["SHUNT_MODELS_FILE"] = str(tmp_path / "absent.json")
    assert status_of(world, capsys)[0] == reply.CONFIG
    assert world.server.requests == []


def test_attached_files_are_appended_and_unreadable_ones_refused(world, tmp_path, capsys):
    attached = tmp_path / "f.txt"
    attached.write_text("file body line\n")
    world.call("the question", [str(attached)])
    assert world.sent()["messages"][1]["content"] == (
        f"the question\n\n--- file: {attached} ---\nfile body line\n\n--- end of file ---\n")
    status, err = status_of(world, capsys, files=[str(tmp_path / "missing")])
    assert status == reply.CONFIG and "cannot read attached file" in err


def test_request_body_merges_in_order_and_cannot_replace_model_or_messages(world):
    world.registry(request_body={"temperature": 0.2, "model": "evil", "messages": []},
                   thinking=True, thinking_options={"reasoningEffort": "high", "budgetTokens": 2048,
                                                     "HTTPProxy": 1, "nested": {"innerKey": [{"itemKey": 2}]}},
                   thinking_off_options={"reasoningEffort": "none"},
                   role_request_body={"bulk-read": {"top_p": 0.5}, "code-write": {"temperature": 0.9}})
    world.call()
    sent = world.sent()
    assert sent["model"] == "m1" and len(sent["messages"]) == 2
    assert sent["temperature"] == 0.2 and sent["top_p"] == 0.5
    assert sent["reasoning_effort"] == "high" and sent["budget_tokens"] == 2048 and sent["http_proxy"] == 1
    assert sent["nested"] == {"inner_key": [{"item_key": 2}]}
    world.call(agent=WRITER)
    assert world.sent()["temperature"] == 0.9 and "top_p" not in world.sent()
    assert world.sent()["messages"][0]["content"] == "You write."


def test_thinking_off_uses_the_off_options(world):
    world.registry(thinking=False, thinking_options={"reasoningEffort": "high"},
                   thinking_off_options={"reasoningEffort": "none"})
    world.call()
    assert world.sent()["reasoning_effort"] == "none"


@pytest.mark.parametrize("fields,message", [
    ({"request_body": [1]}, "request_body must be a JSON object"),
    ({"role_request_body": {"bulk-read": "none"}}, "role_request_body must be a JSON object of JSON objects"),
    ({"role_request_body": [1]}, "role_request_body must be a JSON object of JSON objects"),
    ({"thinking_off_options": [1]}, "thinking_off_options must be a JSON object or null"),
    ({"thinking": True, "thinking_options": {"aB": 1, "a_b": 2}},
     "thinking_options has keys that collide after snake_case conversion (key 'a_b')"),
])
def test_invalid_request_bodies_are_config_errors(world, capsys, fields, message):
    world.registry(**fields)
    status, err = status_of(world, capsys)
    assert status == reply.CONFIG and message in err and world.server.requests == []


def setup_of(**fields):
    return transport_http._Setup("acme/m1", fields.pop("role", "bulk-reader"), "acme", "http://x", False, {}, b"",
                                 fields.pop("context", ""), fields.pop("policy", ""))


@pytest.mark.parametrize("fields,size,outcome", [
    ({"context": "1000"}, 1800, None),  # 600 tokens, budget 600
    ({"context": "1000"}, 1801, reply.NEEDS_CHUNKING),
    ({"context": "1000", "policy": "fail"}, 1801, reply.OVERSIZE),
    ({"context": "1000", "role": "code-writer"}, 1801, reply.OVERSIZE),
    ({"context": "1000", "policy": "bogus"}, 1801, reply.CONFIG),
    ({}, 12000, None),
    ({}, 12001, reply.CONFIG),
    ({"context": "1e+30"}, 1, reply.CONFIG),
    ({"context": "1.5"}, 1, reply.CONFIG),
    ({"context": "-3"}, 1, reply.CONFIG),
    ({"context": "1234567890123"}, 1, reply.CONFIG),
])
def test_size_guard(fields, size, outcome):
    if outcome is None:
        transport_http._guard_size(setup_of(**fields), size)
        return
    with pytest.raises(transport_http._Stop) as stop:
        transport_http._guard_size(setup_of(**fields), size)
    assert stop.value.status == outcome


def test_oversize_message_and_exit_code_through_the_cli(world):
    world.registry(context_tokens=1000, oversize_policy="fail")
    big = "x" * 4000
    argv = [sys.executable, "-I", "-B", str(SHUNT_MAIN), "transport", "http-call", "--", AGENT, big]
    done = subprocess.run(argv, env=world.environ, capture_output=True, text=True, check=False)
    assert done.returncode == reply.OVERSIZE and "input is too large for the model" in done.stderr
    assert world.server.requests == []


def test_an_oversize_map_reduce_input_is_chunked_in_the_same_process(world, tmp_path):
    world.registry(context_tokens=1000)
    attached = tmp_path / "big.txt"
    attached.write_text("".join(f"line {i:04d} {'x' * 80}\n" for i in range(80)))
    argv = [sys.executable, "-I", "-B", str(SHUNT_MAIN), "transport", "http-call", "--", AGENT, "q", str(attached)]
    done = subprocess.run(argv, env=world.environ, capture_output=True, text=True, check=False)
    assert done.returncode == 0 and "asking in" in done.stderr and len(world.server.requests) > 2
    assert json.load(open(done.stdout.strip()))["text"] == "hello there"


def test_invalid_utf8_is_replaced_not_fatal(world, tmp_path):
    attached = tmp_path / "bin.txt"
    attached.write_bytes(b"ok \xff\xfe end")
    world.call("q", [str(attached)])
    assert "ok �� end" in world.sent()["messages"][1]["content"]


def test_lookup_model_finds_an_entry_without_an_agent_by_its_code_writer_name_and_keeps_its_fields(tmp_path):
    registry = tmp_path / "models.json"
    registry.write_text(json.dumps({"version": 1, "models": [
        {"id": "acme/m1", "enabled": True, "context_tokens": 1000, "request_body": {"reasoning_effort": "low"},
         "oversize_policy": "fail"}]}))
    model, role = transport_http.lookup_model(WRITER, str(registry))
    assert role == "code-writer"
    assert (model["id"], model["context_tokens"], model["oversize_policy"]) == ("acme/m1", 1000, "fail")
    assert transport_http.lookup_model("shunt-code-writer-nobody", str(registry)) is None
    assert transport_http.lookup_model(WRITER, str(tmp_path / "missing.json")) is None
