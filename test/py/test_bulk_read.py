"""scripts/bulk-read in one process (bulk_read.py), against the scripted local server."""

import json
import os
import stat

import pytest

from shunt import bulk_read, usage_log

KEY = "sk-bulk-secret-key-321"
ROUTE = "/v1/chat/completions"
OK = {"choices": [{"message": {"content": "hello\n\n"}, "finish_reason": "stop"}],
      "usage": {"prompt_tokens": 12, "completion_tokens": 5}}


@pytest.fixture
def world(tmp_path, http_server):
    http_server.script(ROUTE, body=OK)
    prompts = tmp_path / "prompts"
    prompts.mkdir()
    (prompts / "bulk-reader.md").write_text("You read.\n")
    fake = tmp_path / "opencode"
    fake.write_text("#!/bin/sh\nexit 1\n")
    fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
    (tmp_path / "models.json").write_text(json.dumps({"version": 1, "models": [{"id": "acme/m1", "enabled": True}]}))
    (tmp_path / "providers.json").write_text(json.dumps({"version": 1, "providers": {"acme": {
        "transport": "http", "base_url": http_server.url + "/v1", "key": {"type": "env", "ref": "ACME_KEY"}}}}))
    source = tmp_path / "sample.txt"
    source.write_text("alpha=1\n")

    class World:
        server = http_server
        sample = str(source)
        log = tmp_path / "usage.jsonl"
        environ = {**os.environ, "SHUNT_MODELS_FILE": str(tmp_path / "models.json"),
                   "SHUNT_PROVIDERS_FILE": str(tmp_path / "providers.json"), "SHUNT_PROMPTS_DIR": str(prompts),
                   "SHUNT_AGENTS_DIR": str(tmp_path / "agents"), "SHUNT_OPENCODE_BIN": str(fake),
                   "SHUNT_BREAKER_STATE_FILE": str(tmp_path / "breaker.json"),
                   "SHUNT_BREAKER_CONFIG_FILE": str(tmp_path / "breaker-config.json"),
                   "SHUNT_DEBUG_LOG_PATH": str(tmp_path / "usage.jsonl"), "SHUNT_TIMEOUT_SECONDS": "5",
                   "ACME_KEY": KEY, "SHUNT_DEBUG_LOG": "", "TMPDIR": str(tmp_path / "tmp")}

        def leftovers(self):
            return sorted(os.listdir(tmp_path / "tmp"))

    return World()


def test_answer_goes_to_stdout_and_usage_to_stderr_and_the_reply_file_is_removed(world, capsys):
    assert bulk_read.run(["--question", "q", "--paths", world.sample], world.environ) == 0
    captured = capsys.readouterr()
    assert captured.out == "hello\n"
    assert captured.err == "shunt: bulk-read usage: input=12 output=5 cost=0\n"
    assert world.leftovers() == []
    assert not world.log.exists()
    assert KEY not in captured.out + captured.err


def test_the_debug_log_line_names_the_model_and_the_files(world):
    environ = {**world.environ, "SHUNT_DEBUG_LOG": "yes"}
    assert bulk_read.run(["--question", "why", "--paths", world.sample], environ) == 0
    entry = json.loads(world.log.read_text())
    assert (entry["tool"], entry["agent"], entry["model"]) == ("bulk-read", "acme/m1", "acme/m1")
    assert entry["files"] == [{"path": world.sample, "lines": 1, "bytes": 8}]
    assert (entry["question_chars"], entry["delegate_input_tokens"], entry["delegate_output_tokens"]) == (3, 12, 5)
    assert KEY not in world.log.read_text()


@pytest.mark.parametrize("argv, message", [
    ([], "shunt: --question is required.\n"),
    (["--question"], "shunt: --question requires a value.\n"),
    (["--question", ""], "shunt: --question is required.\n"),
    (["--question", "q"], "shunt: --paths requires at least one file.\n"),
    (["--question", "q", "--paths", "--other"], "shunt: unknown argument: --other\n"),
    (["--bogus"], "shunt: unknown argument: --bogus\n"),
    (["--question", "q", "--paths", "/nonexistent/file"], "shunt: file not found: /nonexistent/file\n"),
])
def test_usage_errors_exit_1_with_a_shunt_line_and_send_nothing(world, capsys, argv, message):
    assert bulk_read.run(argv, world.environ) == 1
    assert capsys.readouterr().err == message
    assert world.server.requests == []


def test_an_unreadable_file_is_refused(world, capsys, tmp_path):
    if os.geteuid() == 0:
        pytest.skip("root reads everything")
    secret = tmp_path / "locked.txt"
    secret.write_text("x")
    secret.chmod(0)
    assert bulk_read.run(["--question", "q", "--paths", str(secret)], world.environ) == 1
    assert capsys.readouterr().err == f"shunt: file not readable: {secret}\n"


def test_a_missing_opencode_binary_is_refused(world, capsys):
    environ = {**world.environ, "SHUNT_OPENCODE_BIN": "/nonexistent/opencode"}
    assert bulk_read.run(["--question", "q", "--paths", world.sample], environ) == 1
    assert "'/nonexistent/opencode' not found in PATH. Install OpenCode" in capsys.readouterr().err


def test_jq_and_timeout_are_not_needed(world, capsys, tmp_path):
    bin_dir = tmp_path / "emptybin"
    bin_dir.mkdir()
    environ = {**world.environ, "PATH": str(bin_dir)}
    assert bulk_read.run(["--question", "q", "--paths", world.sample], environ) == 0
    assert capsys.readouterr().out == "hello\n"


def test_a_failed_call_exits_1_with_the_failover_message(world, capsys):
    world.server.script(ROUTE, status=500, body={"error": "boom"})
    assert bulk_read.run(["--question", "q", "--paths", world.sample], world.environ) == 1
    err = capsys.readouterr().err
    assert "shunt: acme/m1 failed: HTTP request error" in err
    assert "shunt: all delegate models in the registry failed for this call." in err
    assert world.leftovers() == []


def test_an_answer_without_text_keeps_the_reply_file_and_exits_1(world, capsys, monkeypatch):
    monkeypatch.setattr(usage_log, "extract_text", lambda _path: "")
    assert bulk_read.run(["--question", "q", "--paths", world.sample], world.environ) == 1
    err = capsys.readouterr().err
    assert "shunt: could not extract assistant text from the delegate response" in err
    assert len(world.leftovers()) == 1


def test_main_drops_one_leading_separator_only(world, capsys, monkeypatch):
    for name, value in world.environ.items():
        monkeypatch.setenv(name, value)
    assert bulk_read.main(["--", "--question", "q", "--paths", world.sample]) == 0
    assert capsys.readouterr().out == "hello\n"
    assert bulk_read.main(["--", "--", "--question", "q"]) == 1
    assert capsys.readouterr().err == "shunt: unknown argument: --\n"
