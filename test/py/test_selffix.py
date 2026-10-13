"""Retry count of the code-write self-fix loop (selffix.py)."""

import json
import subprocess
import sys

import pytest

from conftest import SHUNT_MAIN
from shunt import selffix


def config(tmp_path, content):
    path = tmp_path / "cfg.json"
    path.write_text(content if isinstance(content, str) else json.dumps(content))
    return str(path)


def test_default_is_one_without_config_or_env(tmp_path):
    assert selffix.resolve_retries(str(tmp_path / "missing.json"), "") == 1


def test_config_file_overrides_the_default(tmp_path):
    assert selffix.resolve_retries(config(tmp_path, {"self_fix_retries": 4}), "") == 4


def test_zero_is_a_valid_count(tmp_path):
    assert selffix.resolve_retries(config(tmp_path, {"self_fix_retries": 0}), "") == 0


def test_env_overrides_the_config_file(tmp_path):
    assert selffix.resolve_retries(config(tmp_path, {"self_fix_retries": 4}), "7") == 7


def test_string_digits_in_the_config_are_accepted(tmp_path):
    assert selffix.resolve_retries(config(tmp_path, {"self_fix_retries": "3"}), "") == 3


@pytest.mark.parametrize("bad", [-1, 1.5, True, None, [], "abc", "", " 3", "3\n", "1" * 16, "٣"])
def test_invalid_config_values_fall_back_to_the_default(tmp_path, bad):
    assert selffix.resolve_retries(config(tmp_path, {"self_fix_retries": bad}), "") == 1


@pytest.mark.parametrize("bad_env", ["abc", "-1", "1" * 16, "$(id)", "3 ", "2.5"])
def test_invalid_env_keeps_the_config_value(tmp_path, bad_env):
    assert selffix.resolve_retries(config(tmp_path, {"self_fix_retries": 2}), bad_env) == 2


@pytest.mark.parametrize("content", ["not json", "[1, 2]", "", "null", '"x"'])
def test_unusable_config_files_fall_back_to_the_default(tmp_path, content):
    assert selffix.resolve_retries(config(tmp_path, content), "") == 1


def test_leading_zeros_count_as_decimal(tmp_path):
    assert selffix.resolve_retries(str(tmp_path / "none"), "010") == 10


def test_cli_prints_the_count(tmp_path):
    done = subprocess.run([sys.executable, "-I", "-B", str(SHUNT_MAIN), "selffix", "retries",
                           config(tmp_path, {"self_fix_retries": 5}), ""], capture_output=True, text=True)
    assert (done.returncode, done.stdout) == (0, "5\n")
