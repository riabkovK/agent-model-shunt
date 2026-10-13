"""The runtime needs no jq: a representative command set runs with a PATH that has no jq."""

import json
import os
import shutil
import subprocess

import pytest

from conftest import REPO_ROOT

SCRIPTS = REPO_ROOT / "scripts"
ROUTE = "/v1/chat/completions"
OK = {"choices": [{"message": {"content": "no jq needed\n"}, "finish_reason": "stop"}],
      "usage": {"prompt_tokens": 3, "completion_tokens": 2}}
KEY = "sk-no-jq-secret-key"


@pytest.fixture(scope="module")
def bin_dir(tmp_path_factory):
    """A directory of links to every tool on PATH except jq."""
    path = tmp_path_factory.mktemp("nojq-bin")
    for directory in os.environ["PATH"].split(os.pathsep):
        if not os.path.isdir(directory):
            continue
        for name in os.listdir(directory):
            target = os.path.join(directory, name)
            if name != "jq" and not (path / name).exists() and os.access(target, os.X_OK):
                os.symlink(target, path / name)
    assert shutil.which("jq", path=str(path)) is None
    return path


@pytest.fixture
def world(tmp_path, bin_dir, http_server):
    http_server.script(ROUTE, body=OK)
    prompts = tmp_path / "prompts"
    prompts.mkdir()
    (prompts / "bulk-reader.md").write_text("You read.\n")
    registry = {"version": 1, "active": "acme/m1", "models": [
        {"id": "acme/m1", "enabled": True, "context_tokens": 100000}, {"id": "acme/m2", "enabled": False}]}
    (tmp_path / "models.json").write_text(json.dumps(registry))
    (tmp_path / "providers.json").write_text(json.dumps({"version": 1, "providers": {"acme": {
        "transport": "http", "base_url": http_server.url + "/v1", "key": {"type": "env", "ref": "ACME_KEY"}}}}))
    (tmp_path / "sample.txt").write_text("alpha=1\n")
    (tmp_path / "usage.jsonl").write_text(
        '{"agent":"a/x","delegate_input_tokens":1,"delegate_output_tokens":1,"delegate_cost_usd":0.5,"avoided_tokens_estimate":4}\n')
    fake = tmp_path / "opencode"
    fake.write_text("#!/bin/sh\nexit 1\n")
    fake.chmod(0o755)
    environ = {
        "SHUNT_OPENCODE_BIN": str(fake), "PATH": str(bin_dir), "HOME": str(tmp_path / "home"), "TMPDIR": str(tmp_path / "tmp"),
        "SHUNT_MODELS_FILE": str(tmp_path / "models.json"), "SHUNT_PROVIDERS_FILE": str(tmp_path / "providers.json"),
        "SHUNT_PROMPTS_DIR": str(prompts), "SHUNT_AGENTS_DIR": str(tmp_path / "agents"),
        "SHUNT_BREAKER_STATE_FILE": str(tmp_path / "breaker.json"),
        "SHUNT_BREAKER_CONFIG_FILE": str(tmp_path / "breaker-config.json"),
        "SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE": str(tmp_path / "selffix.json"),
        "SHUNT_DEBUG_LOG_PATH": str(tmp_path / "usage.jsonl"), "SHUNT_TIMEOUT_SECONDS": "5", "ACME_KEY": KEY,
    }
    (tmp_path / "home").mkdir(exist_ok=True)
    (tmp_path / "tmp").mkdir(exist_ok=True)
    return environ, tmp_path


def run(world, *argv):
    environ, _ = world
    proc = subprocess.run(["bash", *map(str, argv)], env=environ, capture_output=True, text=True, timeout=60)
    assert "jq" not in proc.stderr, proc.stderr
    assert KEY not in proc.stdout + proc.stderr
    return proc


@pytest.mark.parametrize("argv, expected", [
    (["shunt-models", "list"], "acme/m1 (active)\nacme/m2\n"),
    (["shunt-models", "provider", "list"], "acme\thttp\t"),
    (["shunt-models", "key", "status", "acme"], "shunt: provider 'acme': yes (type env)\n"),
    (["shunt-models", "status"], "acme/m1\t"),
    (["shunt-models", "dashboard"], "registry: ok\nproviders_file: ok\n"),
    (["shunt-breaker-config", "show"], "threshold=3 (default: 3)\n"),
    (["shunt-breaker-config", "set", "threshold", "5"], "shunt: breaker threshold set to 5.\n"),
    (["shunt-breaker-config", "disable"], "shunt: circuit breaker disabled"),
    (["shunt-codewrite-config", "show"], "self_fix_retries=1 (default: 1)\n"),
    (["shunt-codewrite-config", "set", "self-fix-retries", "2"], "shunt: self-fix retry count set to 2.\n"),
])
def test_command_works_without_jq(world, argv, expected):
    proc = run(world, SCRIPTS / argv[0], *argv[1:])
    assert proc.returncode == 0, proc.stderr
    assert expected in proc.stdout


def test_config_scripts_keep_their_effect_without_jq(world):
    _, tmp = world
    assert run(world, SCRIPTS / "shunt-breaker-config", "set", "threshold", "5").returncode == 0
    assert run(world, SCRIPTS / "shunt-codewrite-config", "set", "self-fix-retries", "2").returncode == 0
    assert json.loads((tmp / "breaker-config.json").read_text())["threshold"] == 5
    assert json.loads((tmp / "selffix.json").read_text()) == {"self_fix_retries": 2}
    shown = run(world, SCRIPTS / "shunt-breaker-config", "show").stdout
    assert shown.startswith("threshold=5 (default: 3)\n")
    assert "acme/m1: failures=0 open=false" in shown


def test_usage_report_works_without_jq(world):
    _, tmp = world
    proc = run(world, SCRIPTS / "usage-report", tmp / "usage.jsonl")
    assert proc.returncode == 0
    assert json.loads(proc.stdout)["calls"] == 1
    assert "shunt: avoided_tokens_estimate is a chars/4 estimate" in proc.stderr


def test_bulk_read_works_without_jq(world):
    _, tmp = world
    proc = run(world, SCRIPTS / "bulk-read", "--question", "q", "--paths", tmp / "sample.txt")
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "no jq needed\n"
