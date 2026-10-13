"""shunt-key-dialog through the real scripts/shunt-key-dialog launcher, with dialog tools stubbed on PATH.

The secret rules (key never in argv, output or xtrace, file mode 600) must hold across the process
boundary, so most tests run the launcher itself. Home, XDG and TMPDIR are isolated by conftest. No
real keyring is touched: `secret-tool` is a stub too.
"""

import json
import os
import shutil
import stat
import subprocess

import pytest

from conftest import REPO_ROOT

from shunt import key_dialog

LAUNCHER = str(REPO_ROOT / "scripts" / "shunt-key-dialog")
MODELS_BIN = str(REPO_ROOT / "scripts" / "shunt-models")
SECRET = "sk-test-SECRET-1234567890"
GAVE_UP = "__SHUNT_DIALOG_GAVE_UP__"

DIALOG_STUB = """#!/bin/bash
echo "$0 $*" >>"$STUB_ARGV_LOG"
printf '%s' "${STUB_KEY:-}"
exit "${STUB_RC:-0}"
"""
SECRET_TOOL_STUB = """#!/bin/bash
echo "$0 $*" >>"$STUB_ARGV_LOG"
case "$1" in
  store) cat >"$STUB_STORE_FILE" ;;
  lookup) cat "$STUB_STORE_FILE" ;;
esac
"""


def provider_entry(key):
    return {"transport": "http", "base_url": "https://x.test/v1", "key": key}


@pytest.fixture
def world(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for tool in ("zenity", "kdialog", "osascript"):
        stub = bin_dir / tool
        stub.write_text(DIALOG_STUB)
        stub.chmod(0o755)
    providers = tmp_path / "providers.json"
    providers.write_text(json.dumps({"version": 1, "providers": {
        "plain": provider_entry({"type": "plaintext"}),
        "envp": provider_entry({"type": "env", "ref": "ENVP_KEY"}),
        "nokey": provider_entry({"type": "none"}),
        "kr": provider_entry({"type": "keyring"}),
    }}))
    (tmp_path / "proc-version").write_text("Linux version 6.1\n")
    argv_log = tmp_path / "argv.log"
    argv_log.write_text("")
    env = {name: value for name, value in os.environ.items()
           if not name.startswith(("SHUNT_", "SSH_", "STUB_")) and name not in ("DISPLAY", "WAYLAND_DISPLAY", "BASH_ENV", "ENV")}
    env.update({
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "SHUNT_PROVIDERS_FILE": str(providers),
        "SHUNT_PROC_VERSION_FILE": str(tmp_path / "proc-version"),
        "SHUNT_PYTHON": os.environ.get("SHUNT_PYTHON", "python3"),
        "SHUNT_KEY_DIALOG": "zenity",
        "STUB_ARGV_LOG": str(argv_log),
        "STUB_KEY": SECRET,
        "STUB_RC": "0",
    })
    return tmp_path, env


def run(world, *args, **overrides):
    _tmp, env = world
    env = {**env, **overrides}
    return subprocess.run([LAUNCHER, *args], capture_output=True, text=True, env=env, check=False)


def stored_key(world, name="plain"):
    doc = json.loads(world[0].joinpath("providers.json").read_text())
    return doc["providers"][name].get("key", {}).get("ref", "")


def argv_log(world):
    return (world[0] / "argv.log").read_text()


# ---------------------------------------------------------------- success and the secret rules

def test_success_stores_the_key_and_the_output_never_contains_it(world):
    result = run(world, "plain")
    assert result.returncode == 0
    assert stored_key(world) == SECRET
    assert "yes (type plaintext)" in result.stdout
    assert SECRET not in result.stdout + result.stderr


def test_plaintext_key_gets_the_warning_on_stdout_and_mode_600(world):
    result = run(world, "plain")
    path = world[1]["SHUNT_PROVIDERS_FILE"]
    assert f"shunt: warning: the key is stored in plain text in {path} (mode 600)" in result.stdout
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600


def test_the_key_never_appears_in_a_dialog_or_script_argument(world):
    run(world, "plain")
    log = argv_log(world)
    assert SECRET not in log
    assert "--password" in log and "--timeout=120" in log and "plain" in log


def test_timeout_override_reaches_the_dialog(world):
    run(world, "plain", SHUNT_KEY_DIALOG_TIMEOUT="7")
    assert "--timeout=7" in argv_log(world)


@pytest.mark.parametrize("bad", ["0", "abc", "-5", "07", "1.5", ""])
def test_an_invalid_timeout_falls_back_to_120(world, bad):
    run(world, "plain", SHUNT_KEY_DIALOG_TIMEOUT=bad)
    assert "--timeout=120" in argv_log(world)


def test_kdialog_and_osascript_overrides_store_the_key(world):
    assert run(world, "plain", SHUNT_KEY_DIALOG="kdialog").returncode == 0
    assert stored_key(world) == SECRET
    assert run(world, "plain", SHUNT_KEY_DIALOG="osascript", STUB_KEY="second-key").returncode == 0
    assert stored_key(world) == "second-key"
    log = argv_log(world)
    assert "kdialog" in log and "--title Model Shunt: plain --password Enter the API key for provider plain" in log
    assert "giving up after" in log and "-- Enter the API key for provider plain Model Shunt: plain 120" in log


def test_dialog_stderr_is_discarded_and_stdout_carries_the_key(world):
    stub = world[0] / "bin" / "zenity"
    stub.write_text("#!/bin/bash\necho 'gtk noise' >&2\nprintf '%s' \"$STUB_KEY\"\n")
    result = run(world, "plain")
    assert result.returncode == 0
    assert "gtk noise" not in result.stderr
    assert stored_key(world) == SECRET


def test_a_bash_env_that_turns_on_xtrace_does_not_leak_the_key(world):
    bash_env = world[0] / "bash-env"
    bash_env.write_text("set -x\n")
    result = run(world, "plain", BASH_ENV=str(bash_env), ENV=str(bash_env))
    assert result.returncode == 0
    assert SECRET not in result.stdout + result.stderr


# ---------------------------------------------------------------- cancel, empty, timeout

@pytest.mark.parametrize("stub_key,rc", [("", "1"), (SECRET, "1"), ("", "0")])
def test_cancel_or_empty_input_exits_3_and_stores_nothing(world, stub_key, rc):
    result = run(world, "plain", STUB_KEY=stub_key, STUB_RC=rc)
    assert result.returncode == 3
    assert "no key entered" in result.stderr
    assert stored_key(world) == ""


def test_a_dialog_timeout_exits_4_and_stores_nothing(world):
    result = run(world, "plain", STUB_KEY="", STUB_RC="5")
    assert result.returncode == 4
    assert "timed out after 120s" in result.stderr
    assert stored_key(world) == ""


def test_a_kdialog_timeout_exit_124_is_a_timeout(world):
    timeout = world[0] / "bin" / "timeout"
    timeout.write_text("#!/bin/bash\nexit 124\n")
    timeout.chmod(0o755)
    result = run(world, "plain", SHUNT_KEY_DIALOG="kdialog")
    assert result.returncode == 4


def test_an_osascript_dialog_that_gave_up_exits_4_not_3(world):
    result = run(world, "plain", STUB_KEY=GAVE_UP, SHUNT_KEY_DIALOG="osascript")
    assert result.returncode == 4
    assert "timed out" in result.stderr
    assert stored_key(world) == ""


def test_an_osascript_dialog_the_user_cancelled_exits_3(world):
    assert run(world, "plain", STUB_KEY="", STUB_RC="1", SHUNT_KEY_DIALOG="osascript").returncode == 3


# ---------------------------------------------------------------- dialog choice

def test_no_dialog_exits_5_and_prints_the_absolute_fallback_line(world):
    result = run(world, "plain", SHUNT_KEY_DIALOG="none")
    assert result.returncode == 5
    assert f"! {REPO_ROOT}/scripts/shunt-models key set plain" in result.stdout
    assert stored_key(world) == ""


def test_the_fallback_line_quotes_the_provider_name(world):
    result = run(world, "plain", SHUNT_KEY_DIALOG="none")
    assert result.stdout.splitlines()[-1].endswith(" key set plain")


def test_auto_mode_without_a_display_finds_no_dialog(world):
    result = run(world, "plain", SHUNT_KEY_DIALOG="")
    assert result.returncode == 5
    assert argv_log(world) == ""


def test_auto_mode_with_display_picks_zenity(world):
    if os.uname().sysname != "Linux":
        pytest.skip("Linux only")
    assert run(world, "plain", SHUNT_KEY_DIALOG="", DISPLAY=":0").returncode == 0
    assert "zenity" in argv_log(world)
    assert stored_key(world) == SECRET


def test_auto_mode_with_wayland_picks_kdialog_when_zenity_is_missing(world):
    if os.uname().sysname != "Linux":
        pytest.skip("Linux only")
    (world[0] / "bin" / "zenity").unlink()
    if shutil.which("zenity", path=world[1]["PATH"]) or not shutil.which("timeout"):
        pytest.skip("host has a real zenity or no timeout")
    assert run(world, "plain", SHUNT_KEY_DIALOG="", WAYLAND_DISPLAY="w0").returncode == 0
    assert "kdialog" in argv_log(world)


@pytest.mark.parametrize("var", ["SSH_CONNECTION", "SSH_TTY"])
def test_auto_mode_over_ssh_opens_no_gui_dialog(world, var):
    if os.uname().sysname != "Linux":
        pytest.skip("Linux only")
    result = run(world, "plain", SHUNT_KEY_DIALOG="", DISPLAY=":0", **{var: "x"})
    assert result.returncode == 5
    assert "key set plain" in result.stdout
    assert "SSH" in result.stderr and "SHUNT_KEY_DIALOG=zenity" in result.stderr
    assert argv_log(world) == ""


def test_kdialog_without_a_timeout_binary_is_not_used(world):
    minimal = world[0] / "minbin"
    minimal.mkdir()
    (minimal / "python3").symlink_to(shutil.which(world[1]["SHUNT_PYTHON"]))
    (minimal / "kdialog").symlink_to(world[0] / "bin" / "kdialog")
    result = run(world, "plain", SHUNT_KEY_DIALOG="kdialog", PATH=str(minimal))
    assert result.returncode == 5
    assert argv_log(world) == ""


def test_pick_dialog_chooses_osascript_on_macos(world, monkeypatch):
    monkeypatch.setattr(key_dialog, "_is_darwin", lambda: True)
    monkeypatch.setenv("PATH", world[1]["PATH"])
    assert key_dialog.pick_dialog({"DISPLAY": ":0"}) == "osascript"
    monkeypatch.setenv("PATH", str(world[0]))
    assert key_dialog.pick_dialog({}) == "none"


def test_the_macos_keychain_note_is_printed_for_a_keyring_provider(world, monkeypatch, capfd):
    tmp, env = world
    tool = tmp / "bin" / "secret-tool"
    tool.write_text(SECRET_TOOL_STUB)
    tool.chmod(0o755)
    for name, value in {**env, "STUB_STORE_FILE": str(tmp / "stored")}.items():
        monkeypatch.setenv(name, value)
    monkeypatch.setattr(key_dialog, "_is_darwin", lambda: True)
    assert key_dialog.main(["kr"]) == 0
    out = capfd.readouterr().out
    assert "on macOS the keychain tool receives the key as a command argument" in out
    assert SECRET not in out


# ---------------------------------------------------------------- refusals and usage

@pytest.mark.parametrize("name", ["envp", "nokey", "ghost"])
def test_providers_without_a_typed_key_are_refused_with_exit_1(world, name):
    result = run(world, name)
    assert result.returncode == 1
    assert argv_log(world) == ""


def test_the_refusal_messages(world):
    assert "uses an env key. Nothing to enter" in run(world, "envp").stderr
    assert "has key type none. There is no key to enter." in run(world, "nokey").stderr
    ghost = run(world, "ghost").stderr
    assert "provider 'ghost' is not in" in ghost and "provider set" in ghost


def test_a_missing_providers_file_refuses_with_exit_1(world):
    os.unlink(world[1]["SHUNT_PROVIDERS_FILE"])
    result = run(world, "plain")
    assert result.returncode == 1
    assert "is not in" in result.stderr


@pytest.mark.parametrize("args", [(), ("a", "b"), ("",)])
def test_a_missing_or_extra_provider_argument_is_a_usage_error(world, args):
    result = run(world, *args)
    assert result.returncode == 2
    assert result.stderr.strip() == "usage: shunt-key-dialog <provider>"


@pytest.mark.parametrize("name", ["a;rm -rf x", "$(id)", "a b", "-x", "a`id`", "ok\n"])
def test_a_hostile_provider_name_is_refused_before_any_dialog(world, name):
    result = run(world, name)
    assert result.returncode == 1
    assert "invalid provider name" in result.stderr
    assert argv_log(world) == ""


def test_an_existing_entry_with_a_rejected_name_says_to_edit_providers_json(world):
    path = world[1]["SHUNT_PROVIDERS_FILE"]
    with open(path, "w") as handle:
        json.dump({"version": 1, "providers": {"_old": provider_entry({"type": "plaintext"})}}, handle)
    result = run(world, "_old")
    assert result.returncode == 1
    assert "edit providers.json" in result.stderr
    assert argv_log(world) == ""


def test_an_unusable_providers_file_fails_with_its_message(world):
    with open(world[1]["SHUNT_PROVIDERS_FILE"], "w") as handle:
        handle.write('{"version":1,"providers":{"plain":{"transport":"http","key":{"type":"bogus"}}}}')
    result = run(world, "plain")
    assert result.returncode != 0
    assert result.stderr.startswith("shunt: ")
    assert argv_log(world) == ""


# ---------------------------------------------------------------- key cleaning

@pytest.mark.parametrize("typed", [
    f'"{SECRET}"', f"'{SECRET}'", f' \t "{SECRET}" \r', f"  {SECRET}\t", f"{SECRET}\n\n",
])
def test_whitespace_and_one_pair_of_wrapping_quotes_are_stripped(world, typed):
    result = run(world, "plain", STUB_KEY=typed)
    assert result.returncode == 0
    assert stored_key(world) == SECRET
    assert SECRET not in result.stdout + result.stderr


@pytest.mark.parametrize("typed", ["ab\"cd'ef", "\"abc'", "'abc\"", '"'])
def test_internal_and_unmatched_quotes_are_preserved(world, typed):
    assert run(world, "plain", STUB_KEY=typed).returncode == 0
    assert stored_key(world) == typed


@pytest.mark.parametrize("typed", ["  \t ", '""', "''", ' "" '])
def test_a_key_of_only_whitespace_or_empty_quotes_counts_as_no_key(world, typed):
    result = run(world, "plain", STUB_KEY=typed)
    assert result.returncode == 3
    assert stored_key(world) == ""


def test_a_pasted_key_with_a_line_break_is_refused_and_nothing_is_stored(world):
    result = run(world, "plain", STUB_KEY="sk-first\nsk-second")
    assert result.returncode == 3
    assert "line break" in result.stderr
    assert "sk-first" not in result.stderr
    assert stored_key(world) == ""


def test_clean_key_unit():
    assert key_dialog.clean_key(b' "abc" ') == "abc"
    assert key_dialog.clean_key(b"\xff\xfe") == "\udcff\udcfe"  # bytes survive, no decode error


# ---------------------------------------------------------------- storing

def test_a_failing_store_passes_the_shunt_models_error_through_without_the_key(world):
    (world[0] / "proc-version").write_text("Linux version 5 microsoft\n")
    result = run(world, "kr")
    assert result.returncode == 6
    assert "no keyring backend" in result.stderr
    assert "storing the key for 'kr' failed. Check: " in result.stderr
    assert SECRET not in result.stdout + result.stderr


def test_a_keyring_provider_is_stored_through_secret_tool_stdin_only(world):
    tmp, _env = world
    tool = tmp / "bin" / "secret-tool"
    tool.write_text(SECRET_TOOL_STUB)
    tool.chmod(0o755)
    result = run(world, "kr", STUB_STORE_FILE=str(tmp / "stored"))
    assert result.returncode == 0
    assert (tmp / "stored").read_text() == SECRET + "\n"
    assert "yes (type keyring)" in result.stdout
    assert SECRET not in argv_log(world) + result.stdout + result.stderr
    assert "warning" not in result.stdout


def test_the_launcher_drops_bash_env_and_env_for_its_python(world):
    tmp, env = world
    spy = tmp / "bin" / "py-spy"
    spy.write_text(f'#!/bin/bash\necho "${{BASH_ENV:-unset}} ${{ENV:-unset}}" >>"{tmp}/spy"\nexec "$(command -v python3)" "$@"\n')
    spy.chmod(0o755)
    run(world, "plain", SHUNT_PYTHON=str(spy), BASH_ENV="/dev/null", ENV="/dev/null")
    lines = (tmp / "spy").read_text().splitlines()
    assert lines and set(lines) == {"unset unset"}
