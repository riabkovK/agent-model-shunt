"""Context window detection against the scripted local server."""

import json
import os
import socket
import subprocess
import sys

import pytest

from conftest import REPO_ROOT, SHUNT_MAIN
from shunt import context_detect

KEY = "sk-super-secret-value-123"
PROVIDERS = "providers.json"


@pytest.fixture
def setup(tmp_path, http_server, isolated_env):
    """Providers file for `acme` pointing at the server. Returns (environ, server)."""
    def write(base_url=None, key_type="env"):
        key = {"type": "env", "ref": "ACME_KEY"} if key_type == "env" else {"type": "none"}
        doc = {"version": 1, "providers": {"acme": {
            "transport": "http", "base_url": base_url or http_server.url + "/v1", "key": key}}}
        (tmp_path / PROVIDERS).write_text(json.dumps(doc))

    write()
    (tmp_path / "models.json").write_text(json.dumps({"models": [{"id": "acme/m1"}]}))
    environ = {**os.environ, "SHUNT_PROVIDERS_FILE": str(tmp_path / PROVIDERS), "ACME_KEY": KEY,
               "SHUNT_MODELS_FILE": str(tmp_path / "models.json")}
    return environ, http_server, write


def detect(environ, model="acme/m1"):
    return context_detect.detect(model, environ)


def test_reads_context_length_from_models_slash_model(setup):
    environ, server, _ = setup
    server.script("/v1/models/m1", body={"id": "m1", "context_length": 131072})
    assert detect(environ) == (131072, 0)


def test_falls_back_to_the_models_list_entry_with_the_matching_id(setup):
    environ, server, _ = setup
    server.script("/v1/models", body={"data": [{"id": "other", "context_length": 5}, {"id": "m1", "max_model_len": 32768}]})
    assert detect(environ) == (32768, 0)


@pytest.mark.parametrize("doc,expected", [
    ([{"id": "m1", "context_length": 7}], 7),
    ({"models": [{"id": "m1", "context_length": 7}]}, 7),
    ({"data": None, "models": [{"id": "m1", "context_length": 7}]}, 7),
    ({"data": {"a": {"id": "m1", "context_length": 7}}}, 7),
    ({"id": "m1", "context_length": 7}, None),
])
def test_the_models_list_shapes_jq_accepted(setup, doc, expected):
    environ, server, _ = setup
    server.script("/v1/models", body=doc)
    assert detect(environ)[0] == expected


def test_falls_back_to_ollama_api_show_without_the_v1_suffix(setup):
    environ, server, _ = setup
    server.script("/api/show", body={"model_info": {"general.architecture": "qwen", "qwen3.context_length": 262144}})
    assert detect(environ) == (262144, 0)
    show = [r for r in server.requests if r.path == "/api/show"][0]
    assert show.method == "POST"
    assert json.loads(show.body) == {"model": "m1"}


def test_ollama_num_ctx_wins_over_the_architecture_maximum(setup):
    environ, server, _ = setup
    server.script("/api/show", body={"parameters": 'stop "<x>"\nnum_ctx                        131072\ntemperature 1',
                                     "model_info": {"qwen3.context_length": 262144}})
    assert detect(environ) == (131072, 0)


def test_ollama_without_num_ctx_uses_the_model_info_maximum(setup):
    environ, server, _ = setup
    server.script("/api/show", body={"parameters": 'stop "<x>"', "model_info": {"qwen3.context_length": 262144}})
    assert detect(environ) == (262144, 0)


def test_field_precedence_follows_the_documented_order(setup):
    environ, server, _ = setup
    path = "/v1/models/m1"
    server.script(path, body={"max_input_tokens": 1, "context_window": 3, "max_model_len": 2, "context_length": 4})
    assert detect(environ)[0] == 4
    server.script(path, body={"max_input_tokens": 1, "context_window": 3, "max_model_len": 2})
    assert detect(environ)[0] == 2
    server.script(path, body={"max_input_tokens": 1, "max_context_length": 9, "context_window": 3})
    assert detect(environ)[0] == 3


def test_skips_non_positive_non_integer_and_boolean_values(setup):
    environ, server, _ = setup
    server.script("/v1/models/m1", body={"context_length": 0, "max_model_len": "1000", "context_window": 1.5,
                                         "max_context_length": True, "max_input_tokens": 7000.0})
    assert detect(environ) == (7000, 0)


def test_nothing_found_is_exit_1(setup):
    environ, server, _ = setup
    server.script("/v1/models", body={"data": [{"id": "m1"}]})
    assert detect(environ) == (None, 1)


def test_bad_json_non_2xx_and_dropped_connections_all_mean_not_found(setup):
    environ, server, _ = setup
    server.script("/v1/models/m1", body="not json")
    server.script("/v1/models", status=500, body={"data": [{"id": "m1", "context_length": 100}]})
    server.script("/api/show", drop=True)
    assert detect(environ) == (None, 1)


def test_a_timeout_means_not_found(setup):
    environ, server, _ = setup
    for path in ("/v1/models/m1", "/v1/models", "/api/show"):
        server.script(path, delay=3)
    environ["SHUNT_DETECT_TIMEOUT_SECONDS"] = "0.3"
    assert detect(environ) == (None, 1)


@pytest.mark.parametrize("raw", ["abc", "-1", "nan", "inf", "1x", "1e1", " 5"])
def test_a_bad_timeout_means_not_found_without_a_request(setup, raw):
    environ, server, _ = setup
    server.script("/v1/models/m1", body={"context_length": 5})
    environ["SHUNT_DETECT_TIMEOUT_SECONDS"] = raw
    assert detect(environ) == (None, 1)
    assert server.requests == []


def test_connection_refused_means_not_found(setup):
    environ, _, write = setup
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    write(f"http://127.0.0.1:{port}/v1")
    assert detect(environ) == (None, 1)


@pytest.mark.parametrize("model", ["acme/m 1?x=y", "acme/../../admin", "acme/a//b", "acme/./x", "acme/m\n1", "acme/"])
def test_unsafe_model_names_are_not_sent_anywhere(setup, model):
    environ, server, _ = setup
    assert detect(environ, model) == (None, 1)
    assert server.requests == []


def test_the_key_is_sent_as_a_bearer_header_on_every_probe(setup):
    environ, server, _ = setup
    detect(environ)
    assert [r.path for r in server.requests] == ["/v1/models/m1", "/v1/models", "/api/show"]
    assert {r.headers["authorization"] for r in server.requests} == {f"Bearer {KEY}"}


def test_a_provider_without_a_key_sends_no_authorization_header(setup):
    environ, server, write = setup
    write(key_type="none")
    server.script("/v1/models/m1", body={"context_length": 9})
    assert detect(environ) == (9, 0)
    assert "authorization" not in server.requests[0].headers


def test_a_401_is_an_auth_failure_and_stops_the_other_probes(setup):
    environ, server, _ = setup
    server.script("/v1/models/m1", status=401, body={"error": "unauthorized"})
    assert detect(environ) == (None, 3)
    assert [r.path for r in server.requests] == ["/v1/models/m1"]


def test_a_403_on_models_slash_model_alone_does_not_stop_the_list_fallback(setup):
    environ, server, _ = setup
    server.script("/v1/models/m1", status=403, body={"message": "Missing Authentication Token"})
    server.script("/v1/models", body={"data": [{"id": "m1", "context_length": 32768}]})
    assert detect(environ) == (32768, 0)


def test_a_403_everywhere_is_an_auth_failure(setup):
    environ, server, _ = setup
    server.script("/v1/models", status=403)
    assert detect(environ) == (None, 3)
    assert len(server.requests) == 3


def test_a_404_everywhere_is_the_plain_not_found(setup):
    environ, _, _ = setup
    assert detect(environ) == (None, 1)


def test_a_redirect_is_not_followed_and_counts_as_not_found(setup):
    environ, server, _ = setup
    server.script("/v1/models/m1", status=302, headers={"Location": "/elsewhere"})
    server.script("/elsewhere", body={"context_length": 5})
    assert detect(environ) == (None, 1)
    assert "/elsewhere" not in [r.path for r in server.requests]


def test_an_over_limit_answer_counts_as_not_found_with_a_note(setup, capsys):
    environ, server, _ = setup
    server.script("/v1/models/m1", body={"context_length": 131072, "pad": "x" * 3000})
    environ["SHUNT_HTTP_MAX_RESPONSE_BYTES"] = "1000"
    assert detect(environ) == (None, 1)
    assert "larger than 1000 bytes" in capsys.readouterr().err


def test_a_value_beyond_the_digit_limit_is_still_printed_for_the_caller_to_refuse(setup):
    environ, server, _ = setup
    server.script("/v1/models/m1", body='{"context_length":100000000000000000000}')
    assert detect(environ) == (100000000000000000000, 0)


def test_a_base_url_without_a_scheme_assumes_https(setup):
    environ, _, write = setup
    write("127.0.0.1:1/v1")  # https to a closed port: fails as not found, no crash
    assert detect(environ) == (None, 1)


@pytest.mark.parametrize("url,fragment", [("ftp://x/v1", "scheme must be http:// or https://"),
                                           ("http://user:pw@x/v1", "has credentials")])
def test_a_bad_base_url_is_refused_before_any_request(setup, capsys, url, fragment):
    environ, server, write = setup
    write(url)
    assert detect(environ) == (None, 1)
    assert fragment in capsys.readouterr().err
    assert server.requests == []


def test_an_unset_env_key_is_a_config_failure_with_a_shunt_line(setup, capsys):
    environ, server, _ = setup
    del environ["ACME_KEY"]
    assert detect(environ) == (None, 1)
    assert "environment variable ACME_KEY is unset or empty" in capsys.readouterr().err
    assert server.requests == []


def run_cli(environ, *args):
    return subprocess.run([sys.executable, "-I", "-B", str(SHUNT_MAIN), "context", "detect", *args],
                          capture_output=True, text=True, env=environ, check=False)


def test_cli_prints_the_value_and_exits_0(setup):
    environ, server, _ = setup
    server.script("/v1/models/m1", body={"context_length": 4096})
    proc = run_cli(environ, "--", "acme/m1")
    assert (proc.returncode, proc.stdout, proc.stderr) == (0, "4096\n", "")


def test_cli_exit_codes_for_not_found_and_auth(setup):
    environ, server, _ = setup
    assert run_cli(environ, "--", "acme/m1").returncode == 1
    server.script("/v1/models/m1", status=401)
    assert run_cli(environ, "--", "acme/m1").returncode == 3


def test_cli_refuses_an_id_missing_from_the_registry_before_any_request(setup):
    environ, server, _ = setup
    server.script("/v1/models/zzz", body={"context_length": 4096})
    proc = run_cli(environ, "--", "acme/zzz")
    assert (proc.returncode, proc.stdout) == (1, "")
    assert "model 'acme/zzz' is not in the registry" in proc.stderr
    assert server.requests == []


@pytest.mark.parametrize("status", [401, 403, 500])
def test_the_key_never_reaches_stderr_stdout_or_argv_on_error_answers(setup, status):
    environ, server, _ = setup
    server.script("/v1/models/m1", status=status, body={"error": "bad"})
    server.script("/v1/models", status=status, body={"error": "bad"})
    server.script("/api/show", status=status, body={"error": "bad"})
    proc = run_cli(environ, "--", "acme/m1")
    assert KEY not in proc.stderr + proc.stdout


def test_the_key_never_reaches_stderr_on_connection_errors(setup):
    environ, server, write = setup
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    write(f"http://127.0.0.1:{port}/v1")
    refused = run_cli(environ, "--", "acme/m1")
    server.script("/v1/models/m1", drop=True)
    write()
    dropped = run_cli(environ, "--", "acme/m1")
    assert KEY not in refused.stderr + refused.stdout + dropped.stderr + dropped.stdout
    assert "Traceback" not in refused.stderr + dropped.stderr


def test_the_key_never_reaches_stderr_when_it_is_unusable(setup):
    environ, _, _ = setup
    environ["ACME_KEY"] = KEY + "\nX-Evil: 1"
    proc = run_cli(environ, "--", "acme/m1")
    assert proc.returncode == 1
    assert KEY not in proc.stderr and "Traceback" not in proc.stderr
    environ["ACME_KEY"] = KEY + "\ud800".encode("utf-8", "surrogatepass").decode("latin-1")
    proc = run_cli(environ, "--", "acme/m1")
    assert KEY not in proc.stderr and "Traceback" not in proc.stderr
