import json
import io
import os
import subprocess
import sys

import pytest

import shunt_main
from conftest import PY_DIR, REPO_ROOT
from shunt.version import plugin_version


def test_version_prints_plugin_json_version(run_shunt):
    expected = json.loads((REPO_ROOT / ".claude-plugin" / "plugin.json").read_text())["version"]

    result = run_shunt("version")

    assert result.returncode == 0
    assert result.stdout == expected + "\n"


def test_plugin_version_reads_given_file(tmp_path):
    path = tmp_path / "plugin.json"
    path.write_text('{"version": "9.8.7"}')

    assert plugin_version(path) == "9.8.7"


def test_check_python_accepts_minimum_and_newer():
    assert shunt_main.check_python((3, 11, 0)) is None
    assert shunt_main.check_python((3, 13, 2)) is None


@pytest.mark.parametrize("fake", [(3, 10, 12), (3, 8, 0), (2, 7, 18)])
def test_check_python_rejects_old_versions(fake):
    message = shunt_main.check_python(fake)

    assert message is not None
    assert "3.11" in message
    assert "\n" not in message


def test_run_exits_2_with_one_line_on_old_python(monkeypatch, capsys):
    monkeypatch.setattr(shunt_main.sys, "version_info", (3, 9, 1, "final", 0))

    code = shunt_main.run()

    err = capsys.readouterr().err
    assert code == 2
    assert err.count("\n") == 1


def test_unknown_subcommand_exits_nonzero(run_shunt):
    result = run_shunt("no-such-command")

    assert result.returncode != 0
    assert result.stdout == ""


def test_missing_subcommand_exits_nonzero(run_shunt):
    assert run_shunt().returncode != 0


def test_b_flag_leaves_no_pycache(run_shunt):
    run_shunt("version")

    assert not list(PY_DIR.rglob("__pycache__"))


def test_run_writes_utf8_whatever_the_stream_encoding(tmp_path, monkeypatch):
    registry = tmp_path / "models.json"
    registry.write_text(json.dumps({"models": [{"id": "p/m", "agent": "агент"}]}), encoding="utf-8")
    raw = io.BytesIO()
    stdout = io.TextIOWrapper(raw, encoding="ascii", errors="strict")
    monkeypatch.setattr(sys, "stdout", stdout)
    monkeypatch.setattr(sys, "argv", ["shunt_main.py", "models", "agent-for", "p/m"])
    monkeypatch.setenv("SHUNT_MODELS_FILE", str(registry))

    code = shunt_main.run()

    stdout.flush()
    assert code == 0
    assert raw.getvalue() == "агент\n".encode("utf-8")


def test_broken_pipe_exits_141_quietly(tmp_path):
    registry = tmp_path / "models.json"
    registry.write_text(json.dumps({"models": [{"id": "p/m"}]}))
    read_fd, write_fd = os.pipe()
    os.close(read_fd)  # nobody reads: the first write hits EPIPE

    result = subprocess.run(
        [sys.executable, "-I", "-B", str(PY_DIR / "shunt_main.py"), "models", "agent-for", "p/m"],
        stdout=write_fd, stderr=subprocess.PIPE, text=True, check=False,
        env={**os.environ, "SHUNT_MODELS_FILE": str(registry)})
    os.close(write_fd)

    assert result.returncode == 141
    assert result.stderr == ""
