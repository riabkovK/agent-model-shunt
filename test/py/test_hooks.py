"""The Claude Code hooks: decisions, bounded untrusted input, exact stdout, fail-open behaviour."""

import json
import os
import subprocess
import sys

import pytest

from conftest import REPO_ROOT, SHUNT_MAIN
from shunt import breaker, hooks

ALLOW = '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}'
HOOKS_DIR = REPO_ROOT / "hooks"


def numbered(path, count):
    path.write_text("".join(f"{i}\n" for i in range(count)))
    return str(path)


def run_main(name, payload, env_extra=None, python=sys.executable):
    env = {**os.environ, **(env_extra or {})}
    return subprocess.run([python, "-I", "-B", "-S", str(SHUNT_MAIN), "hook", name], input=payload,
                          capture_output=True, text=True, env=env, timeout=30)


def read_payload(path, **extra):
    return json.dumps({"tool_input": {"file_path": path, **extra}})


def registry(tmp_path, monkeypatch, models=None):
    path = tmp_path / "models.json"
    path.write_text(json.dumps({"active": "p/m", "models": models or [{"id": "p/m", "agent": "a"}]}))
    monkeypatch.setenv("SHUNT_MODELS_FILE", str(path))
    monkeypatch.setenv("SHUNT_BREAKER_STATE_FILE", str(tmp_path / "breaker.json"))


# ---------------------------------------------------------------- Read

def test_read_allows_a_small_file(tmp_path):
    assert hooks.decide_read({"file_path": numbered(tmp_path / "s", 10)}, {}) == ALLOW


def test_read_denies_a_large_file_with_the_exact_reason(tmp_path):
    out = hooks.decide_read({"file_path": numbered(tmp_path / "b", 400)}, {})
    assert json.loads(out)["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert ('"permissionDecisionReason": "File is 400 lines (threshold: 350). Use the /bulk-reader skill to '
            'delegate this read to a custom model instead of reading it directly. If you need exact content '
            'for editing, re-read with an offset/limit for just the section you need."}}') in out


@pytest.mark.parametrize("extra", [{"offset": 5}, {"limit": 10}, {"offset": 0}])
def test_read_allows_a_slice(tmp_path, extra):
    assert hooks.decide_read({"file_path": numbered(tmp_path / "b", 400), **extra}, {}) == ALLOW


@pytest.mark.parametrize("extra", [{"offset": None}, {"limit": False}, {"offset": ""}])
def test_read_treats_null_false_and_empty_slice_fields_as_unset(tmp_path, extra):
    assert '"deny"' in hooks.decide_read({"file_path": numbered(tmp_path / "b", 400), **extra}, {})


@pytest.mark.parametrize("value", ["1", "true", "TRUE", "yes", "YES"])
def test_read_hooks_disabled_allows(tmp_path, value):
    big = numbered(tmp_path / "b", 400)
    assert hooks.decide_read({"file_path": big}, {"SHUNT_HOOKS_DISABLED": value}) == ALLOW


def test_read_hooks_disabled_ignores_other_values(tmp_path):
    big = numbered(tmp_path / "b", 400)
    assert '"deny"' in hooks.decide_read({"file_path": big}, {"SHUNT_HOOKS_DISABLED": "on"})


@pytest.mark.parametrize("target", ["", "missing", "dir"])
def test_read_allows_a_missing_or_non_file_path(tmp_path, target):
    (tmp_path / "dir").mkdir()
    path = str(tmp_path / target) if target else ""
    assert hooks.decide_read({"file_path": path}, {}) == ALLOW


@pytest.mark.parametrize("value", [5, None, ["x"], {"a": 1}, "bad\0path"])
def test_read_allows_a_file_path_that_is_not_a_usable_string(value):
    assert hooks.decide_read({"file_path": value}, {}) == ALLOW


@pytest.mark.parametrize(("env_value", "expected"), [("500", "allow"), ("abc", "deny"), ("", "deny"), ("0", "deny"),
                                                     ("9" * 40, "allow")])
def test_threshold_comes_from_shunt_min_lines(tmp_path, env_value, expected):
    out = hooks.decide_read({"file_path": numbered(tmp_path / "b", 400)}, {"SHUNT_MIN_LINES": env_value})
    assert json.loads(out)["hookSpecificOutput"]["permissionDecision"] == expected


def test_read_denies_with_a_usable_registry(tmp_path, monkeypatch):
    registry(tmp_path, monkeypatch)
    assert '"deny"' in hooks.decide_read({"file_path": numbered(tmp_path / "b", 400)}, os.environ)


def test_read_allows_when_every_delegate_breaker_is_open(tmp_path, monkeypatch):
    registry(tmp_path, monkeypatch)
    monkeypatch.setenv("SHUNT_BREAKER_THRESHOLD", "1")
    breaker.record_failure(os.environ, "p/m")
    assert hooks.decide_read({"file_path": numbered(tmp_path / "b", 400)}, os.environ) == ALLOW


def test_read_allows_when_the_registry_has_no_delegate(tmp_path, monkeypatch):
    registry(tmp_path, monkeypatch, models=[{"id": "p/m", "agent": "a", "enabled": False}])
    assert hooks.decide_read({"file_path": numbered(tmp_path / "b", 400)}, os.environ) == ALLOW


def test_read_denies_when_the_registry_is_invalid(tmp_path, monkeypatch):
    registry(tmp_path, monkeypatch)
    (tmp_path / "models.json").write_text("{not json")
    assert '"deny"' in hooks.decide_read({"file_path": numbered(tmp_path / "b", 400)}, os.environ)


# ---------------------------------------------------------------- Bash

@pytest.mark.parametrize(("command", "expected"), [
    ("cat f", "f"), ("head -n 5 f", "f"), ("tail -c 10 f", "f"), ("less -S f", "f"), ("more f", "f"),
    ("cat   f g", "f"), ("cat 'f'", "f"), ('cat "f"', "f"), ("cat -n -- f", "f"), ("cat -", ""),
    ("cat", ""), ("catf f", ""), ("ls f", ""), (" cat f", ""), ("echo hi\ncat f", "echo"), ("cat\tf", ""),
    ("cat a\nb", "a"), ("head -n", ""),
])
def test_file_argument(command, expected):
    assert hooks.file_argument(command) == expected


def test_bash_denies_cat_of_a_large_file(tmp_path):
    out = hooks.decide_bash({"command": f"cat {numbered(tmp_path / 'b', 400)}"}, {})
    assert out == ('{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", '
                   '"permissionDecisionReason": "File is 400 lines (threshold: 350). Use the /bulk-reader skill '
                   'to delegate this read to a custom model instead of cat/head/tail."}}')


@pytest.mark.parametrize("template", ["cat {f} | head", "cat {f} > /dev/null", "ls {f}", "grep x {f}", "cat"])
def test_bash_allows_pipes_redirects_and_other_commands(tmp_path, template):
    assert hooks.decide_bash({"command": template.format(f=numbered(tmp_path / "b", 400))}, {}) == ALLOW


def test_bash_allows_a_small_or_missing_file(tmp_path):
    assert hooks.decide_bash({"command": f"cat {numbered(tmp_path / 's', 5)}"}, {}) == ALLOW
    assert hooks.decide_bash({"command": f"cat {tmp_path}/missing"}, {}) == ALLOW


def test_bash_hooks_disabled_and_threshold(tmp_path):
    command = {"command": f"cat {numbered(tmp_path / 'b', 400)}"}
    assert hooks.decide_bash(command, {"SHUNT_HOOKS_DISABLED": "1"}) == ALLOW
    assert hooks.decide_bash(command, {"SHUNT_MIN_LINES": "400"}) == ALLOW
    assert '"deny"' in hooks.decide_bash(command, {"SHUNT_MIN_LINES": "399"})


def test_bash_does_not_consult_the_registry(tmp_path, monkeypatch):
    registry(tmp_path, monkeypatch)
    monkeypatch.setenv("SHUNT_BREAKER_THRESHOLD", "1")
    breaker.record_failure(os.environ, "p/m")
    assert '"deny"' in hooks.decide_bash({"command": f"cat {numbered(tmp_path / 'b', 400)}"}, os.environ)


# ---------------------------------------------------------------- input handling

@pytest.mark.parametrize("payload", ["", "{", "null", "[]", '{"tool_input": 5}', '{"tool_input": null}', "NaN",
                                     '{"tool_input": {"file_path": "x"}} trailing', "\xff"])
def test_tool_input_is_empty_for_malformed_payloads(payload, tmp_path):
    path = tmp_path / "stdin"
    path.write_bytes(payload.encode("utf-8", errors="surrogateescape"))
    fd = os.open(path, os.O_RDONLY)
    try:
        assert hooks.tool_input(fd) == {}
    finally:
        os.close(fd)


def test_tool_input_reads_a_valid_payload_with_surrounding_space(tmp_path):
    path = tmp_path / "stdin"
    path.write_text(' \n{"tool_input": {"file_path": "x", "n": [1, 2.5, "é"]}}\n')
    fd = os.open(path, os.O_RDONLY)
    try:
        assert hooks.tool_input(fd) == {"file_path": "x", "n": [1, 2.5, "é"]}
    finally:
        os.close(fd)


def test_parse_json_matches_json_loads_on_valid_and_invalid_text():
    for text in ('{"a": [1, {"b": null}], "c": "\\u00e9\\n"}', "  true ", "12", '"s"'):
        assert hooks.parse_json(text) == json.loads(text)
    for text in ("", "{", "{'a': 1}", "[1,]", "Infinity", "1 2"):
        with pytest.raises(ValueError):
            hooks.parse_json(text)


def test_stdin_is_read_with_a_cap(tmp_path):
    big = tmp_path / "stdin"
    big.write_bytes(b'{"tool_input": {"file_path": "' + b"a" * (hooks.MAX_STDIN_BYTES * 2) + b'"}}')
    fd = os.open(big, os.O_RDONLY)
    try:
        assert hooks.tool_input(fd) == {}
    finally:
        os.close(fd)


def test_count_lines_only_reads_regular_files(tmp_path):
    fifo = tmp_path / "fifo"
    os.mkfifo(fifo)
    assert hooks.count_lines(str(fifo)) is None
    assert hooks.count_lines(str(tmp_path)) is None
    assert hooks.count_lines(numbered(tmp_path / "f", 3)) == 3
    (tmp_path / "link").symlink_to(tmp_path / "f")
    assert hooks.count_lines(str(tmp_path / "link")) == 3


# ---------------------------------------------------------------- processes

def test_read_hook_process_prints_one_json_line_and_exits_zero(tmp_path):
    done = run_main("check-file-size", read_payload(numbered(tmp_path / "b", 400)))
    assert done.returncode == 0
    assert done.stderr == ""
    assert done.stdout.count("\n") == 1
    assert json.loads(done.stdout)["hookSpecificOutput"]["permissionDecision"] == "deny"


@pytest.mark.parametrize("name", ["check-file-size", "check-bash-read"])
def test_pretool_hooks_allow_on_garbage_input_and_exit_zero(name):
    done = run_main(name, "\x00{{{ not json")
    assert (done.returncode, done.stdout, done.stderr) == (0, ALLOW + "\n", "")


def test_unknown_hook_name_fails_open():
    done = run_main("nope", "{}")
    assert (done.returncode, done.stdout) == (0, ALLOW + "\n")


def test_a_too_old_interpreter_does_nothing_and_exits_zero(monkeypatch, capsys):
    assert hooks.main(["check-file-size"], "shunt: Python 3.11 or newer is required, found 3.8") == 0
    captured = capsys.readouterr()
    assert captured.err.startswith("shunt: Python 3.11 or newer")


def launcher(name, python, tmp_path):
    return subprocess.run([str(HOOKS_DIR / name)], input="{}", capture_output=True, text=True, timeout=30,
                          env={**os.environ, "SHUNT_PYTHON": python})


def test_launchers_survive_a_missing_interpreter(tmp_path):
    missing = str(tmp_path / "no-python")
    for name in ("check-file-size", "check-bash-read"):
        done = launcher(name, missing, tmp_path)
        assert (done.returncode, done.stdout) == (0, ALLOW + "\n")
        assert done.stderr.startswith("shunt: the Python interpreter is unusable")
    done = launcher("session-start-orchestrator", missing, tmp_path)
    assert (done.returncode, done.stdout) == (0, "")


def test_launchers_exec_one_python_process_and_answer(tmp_path):
    done = launcher("check-bash-read", sys.executable, tmp_path)
    assert (done.returncode, done.stdout) == (0, ALLOW + "\n")


# ---------------------------------------------------------------- session start

def test_session_start_prints_jq_style_json_with_a_trailing_newline(tmp_path, monkeypatch):
    registry(tmp_path, monkeypatch)
    out = hooks.session_start(os.environ)
    doc = json.loads(out)
    assert out == json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
    assert out.startswith('{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": "Shunt')
    assert doc["hookSpecificOutput"]["additionalContext"].startswith("Shunt delegation (cheap models; Claude keeps judgment).\n")


def test_session_start_is_empty_when_the_registry_is_corrupt(tmp_path, monkeypatch):
    registry(tmp_path, monkeypatch)
    (tmp_path / "models.json").write_text("{not json")
    assert hooks.session_start(os.environ) == ""


def test_session_start_process_exits_zero_with_stdin_closed(tmp_path, monkeypatch):
    registry(tmp_path, monkeypatch)
    done = subprocess.run([sys.executable, "-I", "-B", "-S", str(SHUNT_MAIN), "hook", "session-start"],
                          stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    assert done.returncode == 0
    assert "SessionStart" in done.stdout
