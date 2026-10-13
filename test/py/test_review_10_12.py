"""Fixes of reviews 10-12: catch-all exit, post-publish output, hook scan cap and exit code,
process group clean-up, oversize transcript, surrogate labels, wider denylist, option-like
questions and the usage log file checks."""

import os
import subprocess
import sys

import pytest

from conftest import PY_DIR
from shunt import code_write, cw_target, hooks, opencode_cli, usage_log, usage_report
from shunt import transport_reply as reply


def _script(tmp_path, body):
    path = tmp_path / "tool"
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)
    return str(path)


def _invoke_env(tmp_path, binary):
    agents = tmp_path / "agents"
    agents.mkdir(exist_ok=True)
    (agents / "a.md").write_text("model: p/m\n")
    tmp = tmp_path / "scratch"
    tmp.mkdir(exist_ok=True)
    return {"SHUNT_AGENTS_DIR": str(agents), "SHUNT_OPENCODE_CONFIG_HOME": str(tmp_path / "ocfg"),
            "SHUNT_ISOLATED_CONFIG_DIR": str(tmp_path / "iso"), "TMPDIR": str(tmp), "PATH": os.environ["PATH"],
            "SHUNT_OPENCODE_BIN": binary}


# A
def test_an_unexpected_exception_prints_one_line_and_no_traceback():
    code = ("import sys\n"
            f"sys.path.insert(0, {str(PY_DIR)!r})\n"
            "import shunt_main, shunt.cli\n"
            "from shunt import providers\n"
            "def boom(argv):\n"
            "    raise providers.ProviderError('secret detail')\n"
            "shunt.cli.main = boom\n"
            "sys.argv = ['x', 'dashboard']\n"
            "sys.exit(shunt_main.run())\n")
    done = subprocess.run([sys.executable, "-I", "-B", "-c", code], capture_output=True, text=True, check=False)
    assert done.returncode == 1
    assert done.stderr == "shunt: unexpected error (ProviderError)\n"


# B
def _finish_call(monkeypatch, tmp_path, out_error):
    class Publication:
        def publish(self, root, target, code_file):
            return "/final"

    call = code_write.Call(args=None, environ={})
    call.publication = Publication()
    call.work = str(tmp_path)
    (tmp_path / "parsed").mkdir()
    (tmp_path / "parsed" / "code").write_text("x")
    call.outcome = ""
    monkeypatch.setattr(code_write.usage_log, "extract_usage", lambda path: "")
    monkeypatch.setattr(code_write, "out", out_error)
    monkeypatch.setattr(code_write.os, "dup2", lambda *a: None)
    return call


def test_a_closed_pipe_after_publish_keeps_exit_zero(monkeypatch, tmp_path):
    def broken(text):
        raise BrokenPipeError(32, "Broken pipe")

    call = _finish_call(monkeypatch, tmp_path, broken)
    found = code_write.failover.Reply(path=str(tmp_path / "r"), model_id="p/m")
    assert code_write._finish(call, "/root", "/target", found) == 0


def test_a_broken_pipe_during_the_run_is_not_turned_into_exit_one(monkeypatch):
    def raising(argv):
        raise BrokenPipeError(32, "Broken pipe")

    monkeypatch.setattr(code_write.cw_args, "parse_args", raising)
    with pytest.raises(BrokenPipeError):
        code_write.run([], {})


# C
def test_scan_lines_stops_after_the_chunk_that_passes_the_limit(tmp_path, monkeypatch):
    monkeypatch.setattr(hooks, "READ_CHUNK", 10)
    big = tmp_path / "big"
    big.write_bytes(b"a\n" * 1000)
    count, complete = hooks.scan_lines(str(big), 20)
    assert not complete and 20 < count < 1000
    assert hooks.scan_lines(str(big)) == (1000, True)
    assert hooks.scan_lines(str(big), 5000) == (1000, True)
    assert hooks.count_lines(str(big)) == 1000


# D
def test_a_failed_stdout_write_still_exits_zero_and_silences_fd_one(monkeypatch):
    class Dead:
        def write(self, data):
            raise BrokenPipeError(32, "Broken pipe")

        flush = write

    class Stdout:
        buffer = Dead()

    calls = []
    monkeypatch.setattr(hooks.sys, "stdout", Stdout())
    monkeypatch.setattr(hooks.os, "dup2", lambda src, dst: calls.append(dst))
    monkeypatch.setattr(hooks, "_answer", lambda name: "x\n")
    assert hooks.main(["check-file-size"]) == 0
    assert calls == [1]


# E
def test_a_child_exiting_with_124_is_not_a_timeout(tmp_path):
    with open(os.devnull, "wb") as sink:
        status = opencode_cli.run_with_timeout([_script(tmp_path, "exit 124\n")], dict(os.environ), sink.fileno(), 5)
    assert status == 124 != opencode_cli.TIMED_OUT
    environ = _invoke_env(tmp_path, _script(tmp_path, "exit 124\n"))
    with pytest.raises(reply.Abort) as info:
        opencode_cli.invoke("a", "q", [], "", "", environ)
    assert info.value.status == reply.ERROR


def test_an_unrunnable_binary_names_itself_on_stderr(tmp_path, capsys):
    with open(os.devnull, "wb") as sink:
        status = opencode_cli.run_with_timeout([str(tmp_path / "none")], dict(os.environ), sink.fileno(), 1)
    assert status == 127
    assert capsys.readouterr().err == f"shunt: cannot run '{tmp_path / 'none'}': No such file or directory\n"


def test_the_group_is_killed_after_a_normal_exit(tmp_path, monkeypatch):
    kills = []
    real = opencode_cli.os.killpg
    monkeypatch.setattr(opencode_cli.os, "killpg", lambda pid, sig: (kills.append(sig), real(pid, sig)))
    with open(os.devnull, "wb") as sink:
        opencode_cli.run_with_timeout([_script(tmp_path, "exit 0\n")], dict(os.environ), sink.fileno(), 5)
    assert opencode_cli.signal.SIGKILL in kills


# F
def test_an_oversize_transcript_ends_the_call_as_empty(tmp_path, monkeypatch):
    monkeypatch.setattr(opencode_cli, "MAX_TRANSCRIPT_BYTES", 10)
    environ = _invoke_env(tmp_path, _script(tmp_path, "echo '{\"type\":\"text\",\"part\":{\"text\":\"xxxxxxxxxx\"}}'\n"))
    with pytest.raises(reply.Abort) as info:
        opencode_cli.invoke("a", "q", [], "", "", environ)
    assert info.value.status == reply.EMPTY


# G
def test_a_lone_surrogate_in_a_label_does_not_break_the_report(tmp_path, capsys):
    log = tmp_path / "u.jsonl"
    log.write_text('{"agent": "a\\ud800b", "tool": "t", "delegate_input_tokens": 1, "delegate_output_tokens": 1, '
                   '"delegate_cost_usd": 0, "avoided_tokens_estimate": 1}\n')
    assert usage_report.main([str(log)], {}) == 0
    assert "\\ud800" in capsys.readouterr().out


# H
@pytest.mark.parametrize("name", [
    "setup.py", "SiteCustomize.py", "build.rs", "pom.xml", "CMakeLists.txt", "tox.ini", "pyproject.toml",
    "package.json", "Dockerfile", "docker-compose.yml", "compose.yaml", "Gemfile", "evil.pth", "vite.config.ts",
    "jest.config.cjs", "ESLint.config.mjs", "setup.py.", "build.gradle.kts"])
def test_build_and_tooling_entry_points_are_refused(name):
    assert cw_target.find_denied(f"src/{name}".encode()) is not None


@pytest.mark.parametrize("name", ["main.py", "app.config.ts", "vite.config.json", "notes.txt", "pth.py"])
def test_ordinary_names_are_not_refused(name):
    assert cw_target.find_denied(f"src/{name}".encode()) is None


# I
def test_a_question_starting_with_a_dash_is_not_an_option(tmp_path):
    record = tmp_path / "argv"
    environ = _invoke_env(tmp_path, _script(tmp_path, f'printf "%s\\n" "$@" > {record}\n'
                                            "echo '{\"type\":\"text\",\"part\":{\"text\":\"x\"}}'\n"))
    for question, expected in (("--version", "Question: --version"), ("plain", "plain")):
        opencode_cli.invoke("a", question, [], "", "", environ)
        assert record.read_text().splitlines()[3] == expected


# J
def _log_entry(path):
    usage_log._append("a", str(path.parent / "none"), "q", [], 0, {}, {"SHUNT_DEBUG_LOG_PATH": str(path)})


def test_the_usage_log_is_created_private_and_appended(tmp_path):
    log = tmp_path / "usage.jsonl"
    _log_entry(log)
    _log_entry(log)
    assert len(log.read_text().splitlines()) == 2
    assert log.stat().st_mode & 0o777 == 0o600


def test_the_usage_log_does_not_follow_a_symlink(tmp_path):
    target = tmp_path / "target"
    target.write_text("")
    link = tmp_path / "link"
    link.symlink_to(target)
    _log_entry(link)
    assert target.read_text() == ""


def test_the_usage_log_skips_a_file_of_another_owner(tmp_path, monkeypatch):
    log = tmp_path / "usage.jsonl"
    log.write_text("")
    other = os.getuid() + 1
    monkeypatch.setattr(usage_log.os, "getuid", lambda: other)
    _log_entry(log)
    assert log.read_text() == ""
