"""Provider, key and context commands through the real scripts/shunt-models launcher.

The in-process behaviour is covered by test_models_cli.py, test_providers.py,
test_registry_write.py and test_context_detect.py. These tests run the launcher itself,
because the secret rules (key never in argv, output or xtrace, mode 600) must hold across
the process boundary.
"""

import json
import os
import stat
import subprocess
from concurrent.futures import ThreadPoolExecutor

import pytest

from conftest import REPO_ROOT

LAUNCHER = str(REPO_ROOT / "scripts" / "shunt-models")
SECRET = "sk-super-secret-value-123"


@pytest.fixture
def world(tmp_path):
    env = {**{k: v for k, v in os.environ.items() if not k.startswith("SHUNT_")},
           "SHUNT_PROVIDERS_FILE": str(tmp_path / "providers.json"),
           "SHUNT_MODELS_FILE": str(tmp_path / "models.json"),
           "SHUNT_OPENCODE_CONFIG_HOME": str(tmp_path / "oc"),
           "SHUNT_PROC_VERSION_FILE": str(tmp_path / "proc-version"),
           "SHUNT_BREAKER_STATE_FILE": str(tmp_path / "breaker.json"),
           "SHUNT_PYTHON": os.environ.get("SHUNT_PYTHON", "python3")}
    (tmp_path / "proc-version").write_text("Linux version 6.1\n")
    return tmp_path, env


def run(env, *args, stdin=""):
    return subprocess.run([LAUNCHER, *args], input=stdin, capture_output=True, text=True, env=env, check=False)


def write_providers(tmp_path, doc):
    path = tmp_path / "providers.json"
    path.write_text(json.dumps(doc))
    return path


def test_key_set_stores_a_plaintext_key_from_stdin_with_mode_600_and_does_not_echo_it(world):
    tmp_path, env = world
    path = write_providers(tmp_path, {"version": 1, "providers": {"p": {"transport": "http", "key": {"type": "plaintext"}}}})
    proc = run(env, "key", "set", "p", stdin=SECRET + "\n")
    assert proc.returncode == 0
    assert SECRET not in proc.stdout + proc.stderr
    assert "plain text" in proc.stdout + proc.stderr
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert json.loads(path.read_text())["providers"]["p"]["key"]["ref"] == SECRET


def test_key_set_keeps_the_key_out_of_xtrace_when_bash_env_asks_for_it(world):
    tmp_path, env = world
    write_providers(tmp_path, {"version": 1, "providers": {"p": {"transport": "http", "key": {"type": "plaintext"}}}})
    hook = tmp_path / "hook.sh"
    hook.write_text("set -x\n")  # bash itself sources it at startup, before the launcher unsets it
    for extra in ({"BASH_ENV": str(hook)}, {"SHELLOPTS": "xtrace"}):
        proc = run({**env, **extra}, "key", "set", "p", stdin=SECRET + "\n")
        assert proc.returncode == 0
        assert "+ " in proc.stderr  # control: the trace really was on
        assert SECRET not in proc.stdout + proc.stderr


def test_key_set_hands_the_key_to_the_keyring_tool_on_stdin_never_argv(world):
    tmp_path, env = world
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    tool = bin_dir / "secret-tool"
    tool.write_text('#!/bin/bash\necho "$*" >>"$FAKE_ARGV"\n[ "$1" = store ] && cat >"$FAKE_STORE"\nexit 0\n')
    tool.chmod(0o755)
    write_providers(tmp_path, {"providers": {"p": {"key": {"type": "keyring"}}}})
    env = {**env, "PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_ARGV": str(tmp_path / "argv"), "FAKE_STORE": str(tmp_path / "store")}
    proc = run(env, "key", "set", "p", stdin=SECRET + "\n")
    assert proc.returncode == 0
    assert SECRET not in proc.stdout + proc.stderr
    assert (tmp_path / "store").read_text().strip() == SECRET
    assert SECRET not in (tmp_path / "argv").read_text()


@pytest.mark.parametrize("action", ["set", "status"])
@pytest.mark.parametrize("name", ["a;rm -rf x", "$(id)"])
def test_key_commands_refuse_a_provider_name_outside_the_allowed_charset(world, action, name):
    tmp_path, env = world
    write_providers(tmp_path, {"version": 1, "providers": {"p": {"transport": "http", "key": {"type": "plaintext"}}}})
    proc = run(env, "key", action, name, stdin="k\n")
    assert proc.returncode != 0
    assert "invalid provider name" in proc.stderr + proc.stdout


@pytest.mark.parametrize("action", ["set", "status"])
def test_key_commands_on_an_existing_entry_with_a_rejected_name_say_to_edit_providers_json(world, action):
    tmp_path, env = world
    write_providers(tmp_path, {"version": 1, "providers": {"_old": {"transport": "http", "key": {"type": "plaintext"}}}})
    proc = run(env, "key", action, "_old", stdin="k\n")
    out = proc.stderr + proc.stdout
    assert proc.returncode != 0
    assert '"_old"' in out and "edit providers.json" in out


def test_provider_set_never_accepts_a_key_value_on_the_command_line(world):
    tmp_path, env = world
    proc = run(env, "provider", "set", "acme", "--transport", "http", "--base-url", "https://x", "--key", "plaintext:sk-secret")
    assert proc.returncode != 0
    assert "sk-secret" not in proc.stdout + proc.stderr
    assert not (tmp_path / "providers.json").exists()


def test_concurrent_provider_sets_lose_none_of_them(world):
    tmp_path, env = world
    write_providers(tmp_path, {"version": 1, "providers": {}})
    with ThreadPoolExecutor(max_workers=10) as pool:
        codes = list(pool.map(lambda i: run(env, "provider", "set", f"p{i}", "--transport", "opencode").returncode, range(20)))
    assert codes == [0] * 20
    assert len(json.loads((tmp_path / "providers.json").read_text())["providers"]) == 20


def test_add_works_for_an_http_provider_configured_only_with_provider_set(world):
    tmp_path, env = world
    assert run(env, "provider", "set", "acme", "--transport", "http", "--base-url", "http://127.0.0.1:9/v1", "--key", "none").returncode == 0
    assert not (tmp_path / "oc" / "opencode.json").exists()
    assert run(env, "add", "acme/m1").returncode == 0
    assert json.loads((tmp_path / "models.json").read_text())["models"][0]["id"] == "acme/m1"


def test_detect_context_sends_the_key_only_as_a_header_and_leaves_no_temp_file(world, http_server):
    tmp_path, env = world
    write_providers(tmp_path, {"version": 1, "providers": {"acme": {
        "transport": "http", "base_url": http_server.url + "/v1", "key": {"type": "env", "ref": "ACME_KEY"}}}})
    (tmp_path / "models.json").write_text(json.dumps({"version": 1, "models": [{"id": "acme/m1", "agent": "a1", "enabled": True}]}))
    http_server.script("/v1/models/m1", body={"context_length": 65536})
    proc = run({**env, "ACME_KEY": SECRET}, "detect-context", "acme/m1")
    assert proc.returncode == 0
    assert proc.stdout.strip() == "65536"
    assert SECRET not in proc.stdout + proc.stderr
    request = http_server.requests[0]
    assert request.headers["authorization"] == f"Bearer {SECRET}"
    assert SECRET not in request.path
    assert list((tmp_path / "tmp").iterdir()) == []
    proc = run({**env, "ACME_KEY": SECRET}, "detect-context", "acme/missing")
    assert proc.returncode != 0
    assert SECRET not in proc.stdout + proc.stderr
    assert list((tmp_path / "tmp").iterdir()) == []
