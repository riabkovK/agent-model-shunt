"""shunt-breaker-config (breaker_config_cli.py): usage, output lines, exit codes and config writes."""

import json
import os
import subprocess
import sys

import pytest

from conftest import SHUNT_MAIN
from shunt import breaker_config_cli as cli


@pytest.fixture
def world(tmp_path, monkeypatch):
    """Registry, state and config paths inside tmp_path, SHUNT_BREAKER_* overrides cleared."""
    paths = {
        "SHUNT_MODELS_FILE": tmp_path / "models.json",
        "SHUNT_BREAKER_STATE_FILE": tmp_path / "state.json",
        "SHUNT_BREAKER_CONFIG_FILE": tmp_path / "breaker-config.json",
    }
    for name, path in paths.items():
        monkeypatch.setenv(name, str(path))
    for name in ("SHUNT_BREAKER_THRESHOLD", "SHUNT_BREAKER_COOLDOWN_SECONDS", "SHUNT_NOW_EPOCH"):
        monkeypatch.delenv(name, raising=False)
    return paths


def run(capsys, *args):
    code = cli.main(list(args))
    out = capsys.readouterr()
    return code, out.out, out.err


def test_show_reports_hardcoded_defaults_when_no_config_file_exists(world, capsys):
    code, out, _ = run(capsys, "show")
    assert code == 0
    assert "threshold=3 (default: 3)\ncooldown_seconds=300 (default: 300)\n" in out


def test_set_threshold_writes_the_config_file_and_show_reflects_it(world, capsys):
    code, out, _ = run(capsys, "set", "threshold", "5")
    assert (code, out) == (0, "shunt: breaker threshold set to 5.\n")
    assert json.loads(world["SHUNT_BREAKER_CONFIG_FILE"].read_text()) == {"threshold": 5, "cooldown_seconds": 300}
    assert "threshold=5 (default: 3)" in run(capsys, "show")[1]


def test_set_cooldown_writes_the_config_file_and_show_reflects_it(world, capsys):
    code, out, _ = run(capsys, "set", "cooldown", "60")
    assert (code, out) == (0, "shunt: breaker cooldown set to 60s.\n")
    assert "cooldown_seconds=60 (default: 300)" in run(capsys, "show")[1]


def test_set_threshold_preserves_a_previously_set_cooldown(world, capsys):
    run(capsys, "set", "cooldown", "60")
    run(capsys, "set", "threshold", "5")
    out = run(capsys, "show")[1]
    assert "threshold=5 (default: 3)" in out
    assert "cooldown_seconds=60 (default: 300)" in out


@pytest.mark.parametrize("value", ["abc", "0", "-1", "", "1.5", "٣"])
def test_set_threshold_rejects_a_value_that_is_not_a_positive_integer(world, capsys, value):
    code, out, err = run(capsys, "set", "threshold", value)
    assert (code, out) == (1, "")
    assert err == "shunt: threshold must be a positive integer.\n"
    assert not world["SHUNT_BREAKER_CONFIG_FILE"].exists()


@pytest.mark.parametrize("value", ["abc", "-1", "", "2.5"])
def test_set_cooldown_rejects_a_value_that_is_not_a_non_negative_integer(world, capsys, value):
    code, _, err = run(capsys, "set", "cooldown", value)
    assert code == 1
    assert err == "shunt: cooldown must be a non-negative integer.\n"
    assert not world["SHUNT_BREAKER_CONFIG_FILE"].exists()


def test_set_cooldown_accepts_zero(world, capsys):
    assert run(capsys, "set", "cooldown", "0")[:2] == (0, "shunt: breaker cooldown set to 0s.\n")


def test_set_rejects_a_value_over_fifteen_digits_with_a_shunt_line(world, capsys):
    code, out, err = run(capsys, "set", "threshold", "1" * 16)
    assert (code, out) == (1, "")
    assert err.startswith("shunt: threshold must be a plain non-negative integer")


def test_set_with_an_unknown_field_prints_the_usage(world, capsys):
    code, _, err = run(capsys, "set", "colour", "3")
    assert code == 1
    assert err == "shunt: usage: shunt-breaker-config set <threshold|cooldown> <value>\n"


def test_set_refuses_a_corrupt_config_file_and_leaves_it_alone(world, capsys):
    world["SHUNT_BREAKER_CONFIG_FILE"].write_text("not json")
    code, _, err = run(capsys, "set", "threshold", "5")
    assert code == 1
    assert err.startswith("shunt: ")
    assert world["SHUNT_BREAKER_CONFIG_FILE"].read_text() == "not json"


def test_disable_presets_an_unreachable_threshold_that_show_reports(world, capsys):
    code, out, _ = run(capsys, "disable")
    assert (code, out) == (0, "shunt: circuit breaker disabled (threshold set to an unreachable value).\n")
    assert "status: disabled (threshold effectively unreachable)" in run(capsys, "show")[1]


def test_reset_removes_the_config_file_and_restores_defaults(world, capsys):
    run(capsys, "set", "threshold", "9")
    assert world["SHUNT_BREAKER_CONFIG_FILE"].exists()
    code, out, _ = run(capsys, "reset")
    assert (code, out) == (0, "shunt: breaker config reset to hardcoded defaults.\n")
    assert not world["SHUNT_BREAKER_CONFIG_FILE"].exists()
    assert "threshold=3 (default: 3)" in run(capsys, "show")[1]


def test_reset_without_a_config_file_still_succeeds(world, capsys):
    assert run(capsys, "reset")[0] == 0


def test_env_override_is_reflected_by_show_even_with_no_config_file(world, capsys, monkeypatch):
    monkeypatch.setenv("SHUNT_BREAKER_THRESHOLD", "7")
    assert "threshold=7 (default: 3)" in run(capsys, "show")[1]


def test_env_override_with_a_command_substitution_is_ignored(world, capsys, monkeypatch, tmp_path):
    marker = tmp_path / "pwned"
    monkeypatch.setenv("SHUNT_BREAKER_THRESHOLD", f"a[$(touch {marker})]")
    assert "threshold=3 (default: 3)" in run(capsys, "show")[1]
    assert not marker.exists()


def test_show_reports_legacy_mode_when_no_models_registry_exists(world, capsys):
    out = run(capsys, "show")[1]
    assert f"shunt: circuit breaker not applicable (no models registry at {world['SHUNT_MODELS_FILE']}; legacy single-agent mode).\n" in out
    assert "---" not in out


def test_show_lists_the_code_write_breaker_state_next_to_each_models_own(world, capsys):
    world["SHUNT_MODELS_FILE"].write_text(json.dumps(
        {"active": "p/one", "models": [{"id": "p/one", "agent": "a"}, {"id": "p/two", "agent": "b", "roles": ["bulk-read"]}]}))
    world["SHUNT_BREAKER_STATE_FILE"].write_text(json.dumps({"version": 1, "models": {
        "p/one": {"failures": 1, "cooldown_until": 0}, "p/one#code-write": {"failures": 2, "cooldown_until": 0}}}))
    out = run(capsys, "show")[1]
    assert "---\np/one: failures=1 open=false\np/one (code-write): failures=2 open=false\np/two: failures=0 open=false\n" in out
    assert "p/two (code-write)" not in out


def test_missing_subcommand_prints_the_usage(world, capsys):
    code, out, err = run(capsys)
    assert (code, out) == (1, "")
    assert err == "shunt: usage: shunt-breaker-config <show|set|disable|reset> [args...]\n"


def test_unknown_subcommand_is_refused(world, capsys):
    code, _, err = run(capsys, "frobnicate")
    assert (code, err) == (1, "shunt: unknown subcommand: frobnicate\n")


def test_shunt_main_dispatches_the_command_and_strips_the_double_dash(world, tmp_path):
    env = {**os.environ, **{k: str(v) for k, v in world.items()}}
    proc = subprocess.run([sys.executable, "-I", "-B", str(SHUNT_MAIN), cli.COMMAND, "--", "set", "threshold", "4"],
                          env=env, capture_output=True, text=True, timeout=60, check=False)
    assert (proc.returncode, proc.stdout) == (0, "shunt: breaker threshold set to 4.\n")
