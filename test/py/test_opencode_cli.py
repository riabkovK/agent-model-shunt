"""The OpenCode CLI transport (opencode_cli.py): normalizing, the size guard, the isolated config and
running the child under a timeout."""

import json
import os
import stat
import time

import pytest

from shunt import opencode_cli
from shunt import transport_reply as reply


def step(reason="stop", **part):
    return json.dumps({"type": "step_finish", "part": {"reason": reason, **part}})


def text(value):
    return json.dumps({"type": "text", "part": {"text": value}})


def test_normalize_sums_steps_adds_cache_and_reasoning_and_keeps_the_last_text():
    out = opencode_cli.normalize_text("\n".join([
        text("first"), step("tool-calls", cost=0.01, tokens={"input": 1, "output": 1}),
        text("final"), step("stop", cost=0.125, tokens={"input": 100, "output": 50, "reasoning": 5,
                                                         "cache": {"read": 6912, "write": 3}})]))
    assert out == {"text": "final", "finish_reason": "stop",
                   "usage": {"input": 7016, "output": 56}, "cost": 0.135}


@pytest.mark.parametrize("transcript", ["not json", '"a string"', "[1]", '{"type":"text","part":"x"}'])
def test_normalize_gives_the_empty_answer_for_input_jq_would_reject(transcript):
    assert opencode_cli.normalize_text(transcript) == {"text": "", "finish_reason": ""}


def test_normalize_leaves_out_usage_without_a_step_and_cost_without_a_number():
    assert opencode_cli.normalize_text(text("hi")) == {"text": "hi", "finish_reason": ""}
    out = opencode_cli.normalize_text(step(tokens={"input": "7", "output": None, "cache": "none"}, cost="free"))
    assert out == {"text": "", "finish_reason": "stop", "usage": {"input": 0, "output": 0}}


def test_normalize_reads_values_split_over_lines_and_back_to_back():
    assert opencode_cli.normalize_text(text("a") + text("b"))["text"] == "b"
    assert opencode_cli.normalize_text('{"type":\n"text","part":{"text":"x"}}')["text"] == "x"


def test_file_too_big_checks_lines_then_bytes_then_the_longest_line(tmp_path):
    many = tmp_path / "many"
    many.write_text("a\n" * 2001)
    assert opencode_cli.file_too_big(str(many)) == "2001 lines, opencode keeps 2000"
    wide = tmp_path / "wide"
    wide.write_text(("x" * 99 + "\n") * 600)
    assert opencode_cli.file_too_big(str(wide)) == "60000 bytes, opencode keeps 51200"
    long = tmp_path / "long"
    long.write_text("é" * 2001 + "\n")
    assert opencode_cli.file_too_big(str(long)) == "a line of 2001 characters, opencode keeps 2000"
    ok = tmp_path / "ok"
    ok.write_text("x" * 2000)
    assert opencode_cli.file_too_big(str(ok)) is None
    assert opencode_cli.file_too_big(str(tmp_path / "missing")) is None


def test_guard_size_uses_the_context_budget_and_names_the_model(tmp_path, capsys):
    path = tmp_path / "f"
    path.write_text(("x" * 99 + "\n") * 30)
    opencode_cli.guard_size("agent", "q", [str(path)], "p/m", "")
    opencode_cli.guard_size("agent", "q", [str(path)], "p/m", "10000")
    with pytest.raises(reply.Abort) as info:
        opencode_cli.guard_size("agent", "q", [str(path)], "p/m", "1000")
    assert info.value.status == reply.OVERSIZE
    assert ("shunt: model p/m: input is too large for the model (about 1001 tokens, budget 600), "
            "no request sent.") in capsys.readouterr().err
    with pytest.raises(reply.Abort) as info:
        opencode_cli.guard_size("agent", "q", [], "p/m", "1e30")
    assert info.value.status == reply.CONFIG
    assert "invalid context_tokens" in capsys.readouterr().err


def test_isolated_config_is_owner_only_and_holds_one_provider(tmp_path):
    home = tmp_path / "ocfg"
    (home / "agents").mkdir(parents=True)
    (home / "agents" / "legacy.md").write_text("---\nmodel: acme/m: x\n---\nbody\n")
    (home / "opencode.json").write_text(json.dumps({"provider": {"acme": {"options": {"apiKey": "k"}}, "other": {}}}))
    environ = {"SHUNT_OPENCODE_CONFIG_HOME": str(home), "SHUNT_AGENTS_DIR": str(tmp_path / "agents"),
               "SHUNT_ISOLATED_CONFIG_DIR": str(tmp_path / "iso" / "deep")}
    old = os.umask(0o022)
    try:
        root = opencode_cli.prepare_isolated_config("legacy", environ)
    finally:
        os.umask(old)
    assert root == str(tmp_path / "iso" / "deep" / "legacy")
    config = json.loads((tmp_path / "iso" / "deep" / "legacy" / "opencode" / "opencode.json").read_text())
    assert config == {"provider": {"acme": {"options": {"apiKey": "k"}}}}
    modes = {p: stat.S_IMODE(os.stat(p).st_mode) for p in (
        tmp_path / "iso", tmp_path / "iso" / "deep", root, root + "/opencode", root + "/opencode/agents",
        root + "/opencode/opencode.json", root + "/opencode/agents/legacy.md")}
    assert list(modes.values()) == [0o700] * 5 + [0o600] * 2


def test_isolated_config_without_a_provider_file_is_empty_and_a_missing_agent_is_an_error(tmp_path):
    agents = tmp_path / "agents"
    agents.mkdir()
    (agents / "a.md").write_text("no model line\n")
    environ = {"SHUNT_OPENCODE_CONFIG_HOME": str(tmp_path / "ocfg"), "SHUNT_AGENTS_DIR": str(agents),
               "SHUNT_ISOLATED_CONFIG_DIR": str(tmp_path / "iso")}
    root = opencode_cli.prepare_isolated_config("a", environ)
    assert (tmp_path / "iso" / "a" / "opencode" / "opencode.json").read_text() == "{}\n"
    assert root.endswith("/a")
    with pytest.raises(opencode_cli.ConfigError, match=r"OpenCode agent 'zzz' not found in .*agents or .*ocfg/agents"):
        opencode_cli.prepare_isolated_config("zzz", environ)
    (agents / "b.md").write_text("model: acme/m\n")
    (tmp_path / "ocfg").mkdir()
    (tmp_path / "ocfg" / "opencode.json").write_text("{broken")
    with pytest.raises(opencode_cli.ConfigError, match="failed to build isolated OpenCode config"):
        opencode_cli.prepare_isolated_config("b", environ)


@pytest.mark.parametrize("raw, expected", [("5", 5.0), ("1.5", 1.5), ("2m", 120.0), ("1h", 3600.0), ("0", None), ("0s", None)])
def test_parse_timeout_follows_gnu_timeout(raw, expected):
    assert opencode_cli.parse_timeout(raw) == expected


@pytest.mark.parametrize("raw", ["", "abc", "-1", "1x", "1e3", "5 "])
def test_parse_timeout_refuses_what_gnu_timeout_refuses(raw):
    with pytest.raises(ValueError):
        opencode_cli.parse_timeout(raw)


def _script(tmp_path, body):
    path = tmp_path / "tool"
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)
    return str(path)


def test_run_with_timeout_returns_124_and_kills_the_whole_group(tmp_path):
    marker = tmp_path / "survivor"
    tool = _script(tmp_path, f"(sleep 3; touch {marker}) &\nsleep 30\n")
    with open(os.devnull, "wb") as sink:
        started = time.monotonic()
        assert opencode_cli.run_with_timeout([tool], dict(os.environ), sink.fileno(), 0.3) == opencode_cli.TIMED_OUT
    assert time.monotonic() - started < 5
    time.sleep(3.2)
    assert not marker.exists()


def test_run_with_timeout_passes_the_status_and_output_through(tmp_path):
    tool = _script(tmp_path, "echo out; read line; echo \"stdin:[$line]\"; exit 3\n")
    out = tmp_path / "out"
    with open(out, "wb") as sink:
        assert opencode_cli.run_with_timeout([tool], dict(os.environ), sink.fileno(), None) == 3
    assert out.read_text() == "out\nstdin:[]\n"


def test_run_with_timeout_reports_a_missing_binary_as_a_failure(tmp_path):
    with open(os.devnull, "wb") as sink:
        assert opencode_cli.run_with_timeout([str(tmp_path / "none")], dict(os.environ), sink.fileno(), 1) == 127


def test_invoke_maps_failure_empty_output_timeout_and_a_bad_timeout_setting(tmp_path):
    agents = tmp_path / "agents"
    agents.mkdir()
    (agents / "a.md").write_text("model: p/m\n")
    tmp = tmp_path / "scratch"
    tmp.mkdir()
    base = {"SHUNT_AGENTS_DIR": str(agents), "SHUNT_OPENCODE_CONFIG_HOME": str(tmp_path / "ocfg"),
            "SHUNT_ISOLATED_CONFIG_DIR": str(tmp_path / "iso"), "TMPDIR": str(tmp), "PATH": os.environ["PATH"]}

    def status(body, **extra):
        environ = {**base, "SHUNT_OPENCODE_BIN": _script(tmp_path, body), **extra}
        with pytest.raises(reply.Abort) as info:
            opencode_cli.invoke("a", "q", [], "", "", environ)
        return info.value.status

    assert status("exit 7\n") == reply.ERROR
    assert status("exit 0\n") == reply.EMPTY
    assert status("sleep 30\n", SHUNT_TIMEOUT_SECONDS="0.2") == reply.TIMEOUT
    assert status("echo x\n", SHUNT_TIMEOUT_SECONDS="soon") == reply.ERROR
    assert list(tmp.iterdir()) == []  # no temp file is left behind


def test_a_failed_reply_write_closes_the_descriptor_and_removes_the_temp_file(tmp_path, monkeypatch):
    agents = tmp_path / "agents"
    agents.mkdir()
    (agents / "a.md").write_text("model: p/m\n")
    tmp = tmp_path / "scratch"
    tmp.mkdir()
    environ = {"SHUNT_AGENTS_DIR": str(agents), "SHUNT_OPENCODE_CONFIG_HOME": str(tmp_path / "ocfg"),
               "SHUNT_ISOLATED_CONFIG_DIR": str(tmp_path / "iso"), "TMPDIR": str(tmp), "PATH": os.environ["PATH"],
               "SHUNT_OPENCODE_BIN": _script(tmp_path, "echo '{\"type\":\"text\",\"part\":{\"text\":\"x\"}}'\n")}
    opened = []
    real_fdopen = os.fdopen

    def failing_fdopen(fd, *args, **kwargs):
        if kwargs.get("encoding") != "utf-8":
            return real_fdopen(fd, *args, **kwargs)
        opened.append(fd)
        raise OSError(12, "Cannot allocate memory")

    monkeypatch.setattr(os, "fdopen", failing_fdopen)
    with pytest.raises(reply.Abort) as info:
        opencode_cli.invoke("a", "q", [], "", "", environ)
    assert info.value.status == reply.ERROR
    assert list(tmp.iterdir()) == []  # neither the raw output nor the reply file is left
    with pytest.raises(OSError):
        os.fstat(opened[-1])  # the descriptor was closed


def test_a_failed_reply_write_removes_the_temp_file(tmp_path, monkeypatch):
    def failing_dump(_value):
        raise OSError(28, "No space left on device")

    scratch = tmp_path / "scratch"
    scratch.mkdir()
    monkeypatch.setattr(reply, "dump", failing_dump)
    with pytest.raises(reply.Abort) as info:
        opencode_cli._write_reply(str(scratch), {"text": "x"})
    assert info.value.status == reply.ERROR
    assert list(scratch.iterdir()) == []


def test_a_timeout_kills_a_group_member_even_when_the_leader_dies_on_sigterm(tmp_path):
    marker = tmp_path / "survivor"
    pids = tmp_path / "pids"
    # The leader exits on SIGTERM, its child ignores it and would touch the marker later.
    tool = _script(tmp_path, f"(trap '' TERM; sleep 2; touch {marker}) &\necho $! >{pids}\nsleep 30\n")
    with open(os.devnull, "wb") as sink:
        assert opencode_cli.run_with_timeout([tool], dict(os.environ), sink.fileno(), 0.3) == opencode_cli.TIMED_OUT
    time.sleep(2.5)
    assert not marker.exists()


def test_the_signal_handlers_are_in_place_before_the_child_starts(tmp_path, monkeypatch):
    import signal
    import subprocess
    seen = {}
    real_popen = subprocess.Popen

    def spying_popen(*args, **kwargs):
        seen["term"] = signal.getsignal(signal.SIGTERM)
        seen["hup"] = signal.getsignal(signal.SIGHUP)
        return real_popen(*args, **kwargs)

    before = signal.getsignal(signal.SIGTERM)
    monkeypatch.setattr(subprocess, "Popen", spying_popen)
    with open(os.devnull, "wb") as sink:
        assert opencode_cli.run_with_timeout([_script(tmp_path, "exit 0\n")], dict(os.environ), sink.fileno(), 5) == 0
    assert callable(seen["term"]) and seen["term"] is not before
    assert callable(seen["hup"])
    assert signal.getsignal(signal.SIGTERM) is before  # restored afterwards


def test_a_sigterm_while_the_child_runs_ends_us_and_kills_the_child(tmp_path):
    import signal
    import subprocess
    import sys
    marker = tmp_path / "survivor"
    tool = _script(tmp_path, f"(sleep 2; touch {marker}) &\nsleep 30\n")
    code = ("import os, sys; sys.path.insert(0, sys.argv[1]); from shunt import opencode_cli\n"
            "sink = open(os.devnull, 'wb')\n"
            "opencode_cli.run_with_timeout([sys.argv[2]], dict(os.environ), sink.fileno(), None)\n")
    proc = subprocess.Popen([sys.executable, "-I", "-B", "-c", code, str(opencode_cli.__file__.rsplit("/shunt/", 1)[0]),
                             tool])
    time.sleep(0.8)
    proc.send_signal(signal.SIGTERM)
    assert proc.wait(timeout=10) == 128 + signal.SIGTERM
    time.sleep(2.3)
    assert not marker.exists()
