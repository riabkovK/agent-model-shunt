"""Circuit breaker port: state reads, locked writes, config writes and the CLI."""

import json
import multiprocessing
import os
import stat
import subprocess
import sys

import pytest

from conftest import SHUNT_MAIN
from shunt import breaker


@pytest.fixture
def bk(tmp_path):
    state = tmp_path / "cache" / "state.json"
    config = tmp_path / "config" / "breaker-config.json"
    environ = {
        "SHUNT_BREAKER_STATE_FILE": str(state),
        "SHUNT_BREAKER_CONFIG_FILE": str(config),
        "SHUNT_NOW_EPOCH": "1000",
        "HOME": str(tmp_path / "home"),
    }
    return state, config, environ


def run_cli(environ, *args):
    full = {**os.environ, **environ}
    return subprocess.run([sys.executable, "-I", "-B", str(SHUNT_MAIN), "breaker", *args],
                          env=full, capture_output=True, text=True, timeout=60)


def raw_state(path, models):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"version": 1, "models": models}))


# ---------------------------------------------------------------- values and limits

@pytest.mark.parametrize("value,expected", [
    ("7", 7), ("007", 7), (7, 7), (7.0, 7), ("-1", 9), (-1, 9), (1.5, 9), ("a[$(x)]", 9),
    ("1234567890123456", 9), (10**15, 9), (True, 9), (None, 9), ({}, 9), ("", 9), ("5\n", 9),
])
def test_uint_or_accepts_only_plain_whole_numbers(value, expected):
    assert breaker.uint_or(value, 9) == expected


def test_limits_prefer_env_then_config_then_default(bk):
    _, config, environ = bk
    assert breaker.limits(environ) == (3, 300)
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps({"threshold": 5, "cooldown_seconds": "60"}))
    assert breaker.limits(environ) == (5, 60)
    assert breaker.limits({**environ, "SHUNT_BREAKER_THRESHOLD": "2", "SHUNT_BREAKER_COOLDOWN_SECONDS": "x"}) == (2, 60)


def test_limits_skip_a_corrupt_config(bk):
    _, config, environ = bk
    config.parent.mkdir(parents=True)
    config.write_text("{nope")
    assert breaker.limits(environ) == (3, 300)


def test_now_uses_the_epoch_override_only_when_plain_digits(bk):
    _, _, environ = bk
    assert breaker.now(environ) == 1000
    assert breaker.now({**environ, "SHUNT_NOW_EPOCH": "a[$(touch x)]"}) > 10**9


# ---------------------------------------------------------------- reads

def test_status_of_a_model_without_state_is_closed(bk):
    _, _, environ = bk
    assert breaker.status(environ, "p/m") == "failures=0 open=false"
    assert breaker.model_state(environ, "p/m") == "null"


def test_model_state_prints_compact_json(bk):
    state, _, environ = bk
    raw_state(state, {"p/m": {"failures": 2, "cooldown_until": 5}})
    assert breaker.model_state(environ, "p/m") == '{"failures":2,"cooldown_until":5}'


def test_breaker_is_open_only_within_the_cooldown(bk):
    state, _, environ = bk
    raw_state(state, {"p/m": {"failures": 3, "cooldown_until": 1001}})
    assert breaker.is_open(environ, "p/m")
    assert not breaker.is_open({**environ, "SHUNT_NOW_EPOCH": "1001"}, "p/m")
    assert breaker.status(environ, "p/m") == "failures=3 open=true"


@pytest.mark.parametrize("content", ["", "{not json", "[]", '"x"', '{"models": []}', '{"models": {"p/m": "x"}}',
                                     '{"models": {"p/m": {"failures": -1, "cooldown_until": 1.5}}}',
                                     '{"models": {"p/m": {"failures": "9", "cooldown_until": "9999"}}}'])
def test_corrupt_or_odd_state_reads_as_closed_and_is_not_touched(bk, content):
    state, _, environ = bk
    state.parent.mkdir(parents=True)
    state.write_text(content)
    assert not breaker.is_open(environ, "p/m")
    assert breaker.any_closed(environ, ["p/m"])
    assert state.read_text() == content


def test_any_closed_needs_one_closed_id_and_fails_for_no_ids(bk):
    state, _, environ = bk
    raw_state(state, {"a": {"failures": 3, "cooldown_until": 2000}, "b": {"failures": 3, "cooldown_until": 2000}})
    assert not breaker.any_closed(environ, ["a", "b"])
    assert breaker.any_closed(environ, ["a", "b", "c"])
    assert not breaker.any_closed(environ, [])


# ---------------------------------------------------------------- writes

def test_record_failure_opens_the_breaker_at_the_threshold(bk):
    state, _, environ = bk
    for _ in range(3):
        breaker.record_failure(environ, "p/m")
    doc = json.loads(state.read_text())
    assert doc == {"version": 1, "models": {"p/m": {"failures": 3, "cooldown_until": 1300}}}
    assert breaker.is_open(environ, "p/m")


def test_record_failure_below_the_threshold_keeps_the_cooldown_at_zero(bk):
    state, _, environ = bk
    breaker.record_failure(environ, "p/m")
    assert json.loads(state.read_text())["models"]["p/m"] == {"failures": 1, "cooldown_until": 0}


def test_record_success_resets_the_entry_and_keeps_other_models(bk):
    state, _, environ = bk
    raw_state(state, {"p/m": {"failures": 3, "cooldown_until": 5000}, "q": {"failures": 1, "cooldown_until": 0}})
    breaker.write_state(environ, "p/m", 0, 0)
    models = json.loads(state.read_text())["models"]
    assert models == {"p/m": {"failures": 0, "cooldown_until": 0}, "q": {"failures": 1, "cooldown_until": 0}}


def test_state_file_has_mode_600_and_no_temp_files_remain(bk):
    state, _, environ = bk
    breaker.record_failure(environ, "p/m")
    assert stat.S_IMODE(state.stat().st_mode) == 0o600
    assert sorted(p.name for p in state.parent.iterdir()) == [state.name, state.name + ".lock"]


@pytest.mark.parametrize("content", ["", "{broken", "[1]", '{"models": 3}'])
def test_a_write_heals_a_corrupt_state_file(bk, content):
    state, _, environ = bk
    state.parent.mkdir(parents=True)
    state.write_text(content)
    breaker.record_failure(environ, "p/m")
    assert json.loads(state.read_text())["models"] == {"p/m": {"failures": 1, "cooldown_until": 0}}


def test_clear_state_drops_the_plain_and_role_keys_only(bk):
    state, _, environ = bk
    entry = {"failures": 1, "cooldown_until": 0}
    raw_state(state, {"p/m": entry, "p/m#code-write": entry, "p/mm": entry, "q": entry})
    breaker.clear_state(environ, "p/m")
    assert sorted(json.loads(state.read_text())["models"]) == ["p/mm", "q"]


def test_clear_state_without_a_file_is_a_noop(bk):
    state, _, environ = bk
    breaker.clear_state(environ, "p/m")
    assert not state.exists()


def test_clear_state_of_a_file_without_models_keeps_it_as_is(bk):
    state, _, environ = bk
    state.parent.mkdir(parents=True)
    state.write_text('{"version": 1}')
    breaker.clear_state(environ, "p/m")
    assert json.loads(state.read_text()) == {"version": 1}


def test_clear_state_of_a_corrupt_file_is_an_error(bk):
    state, _, environ = bk
    state.parent.mkdir(parents=True)
    state.write_text("{broken")
    result = run_cli(environ, "clear-state", "--", "p/m")
    assert result.returncode == 1
    assert result.stderr.startswith("shunt:")
    assert "Traceback" not in result.stderr


# ---------------------------------------------------------------- concurrency

def _record(args):
    environ, count = args
    os.environ.update(environ)
    for _ in range(count):
        breaker.record_failure(os.environ, "p/m")


def test_concurrent_record_failure_loses_no_update(bk):
    state, _, environ = bk
    workers, each = 4, 10
    with multiprocessing.get_context("fork").Pool(workers) as pool:
        pool.map(_record, [(environ, each)] * workers)
    assert json.loads(state.read_text())["models"]["p/m"]["failures"] == workers * each


def test_two_concurrent_cli_record_failure_calls_both_count(bk):
    state, _, environ = bk
    full = {**os.environ, **environ}
    cmd = [sys.executable, "-I", "-B", str(SHUNT_MAIN), "breaker", "record-failure", "--", "p/m"]
    procs = [subprocess.Popen(cmd, env=full) for _ in range(2)]
    assert [p.wait(timeout=60) for p in procs] == [0, 0]
    assert json.loads(state.read_text())["models"]["p/m"]["failures"] == 2


def test_a_held_lock_makes_a_write_time_out_with_a_shunt_line(bk):
    state, _, environ = bk
    from shunt.lockfile import file_lock
    with file_lock(state):
        proc = subprocess.run(
            [sys.executable, "-I", "-B", str(SHUNT_MAIN), "breaker", "record-failure", "--", "p/m"],
            env={**os.environ, **environ, "SHUNT_PROVIDERS_LOCK_TIMEOUT": "0.2"},
            capture_output=True, text=True, timeout=60)
    assert proc.returncode == 1
    assert proc.stderr == f"shunt: timed out waiting for the lock on {state}.\n"


def test_a_held_lock_does_not_block_reads(bk):
    state, _, environ = bk
    from shunt.lockfile import file_lock
    raw_state(state, {"p/m": {"failures": 3, "cooldown_until": 5000}})
    with file_lock(state):
        assert breaker.is_open(environ, "p/m")


# ---------------------------------------------------------------- config writes

def test_config_threshold_sets_the_default_cooldown(bk):
    _, config, environ = bk
    assert run_cli(environ, "config-threshold", "--", "5").returncode == 0
    assert json.loads(config.read_text()) == {"threshold": 5, "cooldown_seconds": 300}
    assert stat.S_IMODE(config.stat().st_mode) == 0o600


def test_config_cooldown_keeps_an_existing_threshold(bk):
    _, config, environ = bk
    config.parent.mkdir(parents=True)
    config.write_text('{"threshold": 7, "extra": true}')
    assert run_cli(environ, "config-cooldown", "--", "0").returncode == 0
    assert json.loads(config.read_text()) == {"threshold": 7, "extra": True, "cooldown_seconds": 0}


def test_config_disable_sets_an_unreachable_threshold(bk):
    _, config, environ = bk
    assert run_cli(environ, "config-disable").returncode == 0
    assert json.loads(config.read_text())["threshold"] == breaker.DISABLED_THRESHOLD


def test_config_write_refuses_a_corrupt_or_non_object_config(bk):
    _, config, environ = bk
    config.parent.mkdir(parents=True)
    for content in ("{broken", "[1]"):
        config.write_text(content)
        result = run_cli(environ, "config-threshold", "--", "5")
        assert result.returncode == 1 and result.stderr.startswith("shunt:")
        assert config.read_text() == content


def test_config_write_refuses_a_non_numeric_value(bk):
    _, config, environ = bk
    result = run_cli(environ, "config-threshold", "--", "abc")
    assert result.returncode == 1 and result.stderr.startswith("shunt:")
    assert not config.exists()


# ---------------------------------------------------------------- cli

def test_cli_round_trip_and_exit_codes(bk):
    _, _, environ = bk
    for _ in range(3):
        assert run_cli(environ, "record-failure", "--", "-odd/id").returncode == 0
    assert run_cli(environ, "is-open", "--", "-odd/id").returncode == 0
    assert run_cli(environ, "is-open", "--", "other").returncode == 1
    assert run_cli(environ, "status", "--", "-odd/id").stdout == "failures=3 open=true\n"
    assert run_cli(environ, "any-closed", "--", "-odd/id").returncode == 1
    assert run_cli(environ, "any-closed", "--", "-odd/id", "other").returncode == 0
    assert run_cli(environ, "any-closed", "--").returncode == 1
    assert run_cli(environ, "record-success", "--", "-odd/id").returncode == 0
    assert run_cli(environ, "status", "--", "-odd/id").stdout == "failures=0 open=false\n"


def test_cli_write_state_rejects_non_integers_without_a_traceback(bk):
    state, _, environ = bk
    result = run_cli(environ, "write-state", "--", "p/m", "1e3", "0")
    assert result.returncode == 1
    assert result.stderr.startswith("shunt:") and "Traceback" not in result.stderr
    assert not state.exists()


def test_cli_never_prints_environment_values(bk):
    _, _, environ = bk
    result = run_cli({**environ, "SHUNT_PROVIDERS_LOCK_TIMEOUT": "SECRET-bad"}, "record-failure", "--", "p/m")
    assert result.returncode == 1
    assert "Traceback" not in result.stderr
    assert "SECRET-bad" not in result.stderr + result.stdout


def test_a_failed_write_leaves_a_broken_state_file_as_it_was(bk):
    # A symlink in place of the lock file is refused, so the write fails before it touches the state file.
    state, _, environ = bk
    state.parent.mkdir(parents=True)
    state.write_text("not json {")
    os.symlink("/dev/null", str(state) + ".lock")
    result = run_cli(environ, "record-failure", "--", "p/m")
    assert result.returncode == 1
    assert state.read_text() == "not json {"
    assert sorted(p.name for p in state.parent.iterdir()) == [state.name, state.name + ".lock"]
