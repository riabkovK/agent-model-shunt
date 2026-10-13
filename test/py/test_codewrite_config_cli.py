"""shunt-codewrite-config (codewrite_config_cli.py): usage, output lines, exit codes and config writes."""

import json
import os
import subprocess
import sys

import pytest

from conftest import SHUNT_MAIN
from shunt import codewrite_config_cli as cli


@pytest.fixture
def config_file(tmp_path, monkeypatch):
    path = tmp_path / "cfg" / "code-write-self-fix-config.json"
    monkeypatch.setenv("SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE", str(path))
    monkeypatch.delenv("SHUNT_CODE_WRITE_SELF_FIX_RETRIES", raising=False)
    return path


def run(capsys, *args):
    code = cli.main(list(args))
    out = capsys.readouterr()
    return code, out.out, out.err


def test_show_reports_the_hardcoded_default_when_no_config_file_exists(config_file, capsys):
    assert run(capsys, "show") == (0, "self_fix_retries=1 (default: 1)\n", "")


def test_set_self_fix_retries_writes_the_config_file_and_show_reflects_it(config_file, capsys):
    assert run(capsys, "set", "self-fix-retries", "3") == (0, "shunt: self-fix retry count set to 3.\n", "")
    assert json.loads(config_file.read_text()) == {"self_fix_retries": 3}
    assert run(capsys, "show")[1] == "self_fix_retries=3 (default: 1)\n"


def test_set_self_fix_retries_accepts_zero(config_file, capsys):
    assert run(capsys, "set", "self-fix-retries", "0")[0] == 0
    assert run(capsys, "show")[1] == "self_fix_retries=0 (default: 1)\n"


def test_set_keeps_the_other_fields_of_the_config_file(config_file, capsys):
    config_file.parent.mkdir()
    config_file.write_text('{"note": "x"}')
    run(capsys, "set", "self-fix-retries", "2")
    assert json.loads(config_file.read_text()) == {"note": "x", "self_fix_retries": 2}


@pytest.mark.parametrize("value", ["abc", "-1", "", "1.5", "1" * 16, "٣"])
def test_set_rejects_a_value_that_is_not_a_non_negative_integer(config_file, capsys, value):
    code, out, err = run(capsys, "set", "self-fix-retries", value)
    assert (code, out) == (1, "")
    assert err == "shunt: self-fix-retries must be a non-negative integer.\n"
    assert not config_file.exists()


def test_set_rejects_an_unknown_field(config_file, capsys):
    code, _, err = run(capsys, "set", "threshold", "3")
    assert (code, err) == (1, "shunt: usage: shunt-codewrite-config set self-fix-retries <value>\n")


def test_set_refuses_a_non_object_config_file_and_leaves_it_alone(config_file, capsys):
    config_file.parent.mkdir()
    config_file.write_text("[1]")
    code, out, err = run(capsys, "set", "self-fix-retries", "2")
    assert (code, out) == (1, "")
    assert err == "shunt: refusing to write an invalid self-fix config.\n"
    assert config_file.read_text() == "[1]"


def test_reset_removes_the_config_file_and_restores_the_default(config_file, capsys):
    run(capsys, "set", "self-fix-retries", "5")
    assert run(capsys, "reset") == (0, "shunt: self-fix config reset to hardcoded defaults.\n", "")
    assert not config_file.exists()
    assert run(capsys, "show")[1] == "self_fix_retries=1 (default: 1)\n"


def test_reset_without_a_config_file_still_succeeds(config_file, capsys):
    assert run(capsys, "reset")[0] == 0


def test_env_override_is_reflected_by_show_even_with_no_config_file(config_file, capsys, monkeypatch):
    monkeypatch.setenv("SHUNT_CODE_WRITE_SELF_FIX_RETRIES", "4")
    assert run(capsys, "show")[1] == "self_fix_retries=4 (default: 1)\n"


def test_env_override_takes_precedence_over_a_config_file_value(config_file, capsys, monkeypatch):
    run(capsys, "set", "self-fix-retries", "2")
    monkeypatch.setenv("SHUNT_CODE_WRITE_SELF_FIX_RETRIES", "9")
    assert run(capsys, "show")[1] == "self_fix_retries=9 (default: 1)\n"


def test_missing_subcommand_prints_the_usage(config_file, capsys):
    code, out, err = run(capsys)
    assert (code, out) == (1, "")
    assert err == "shunt: usage: shunt-codewrite-config <show|set|reset> [args...]\n"


def test_unknown_subcommand_is_refused(config_file, capsys):
    assert run(capsys, "frobnicate")[::2] == (1, "shunt: unknown subcommand: frobnicate\n")


def test_shunt_main_dispatches_the_command_and_strips_the_double_dash(config_file):
    env = {**os.environ, "SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE": str(config_file)}
    proc = subprocess.run([sys.executable, "-I", "-B", str(SHUNT_MAIN), cli.COMMAND, "--", "set", "self-fix-retries", "6"],
                          env=env, capture_output=True, text=True, timeout=60, check=False)
    assert (proc.returncode, proc.stdout) == (0, "shunt: self-fix retry count set to 6.\n")
