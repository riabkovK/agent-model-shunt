"""`migrate`: the OpenCode to HTTP transport migration (dry run, apply, keys, lock, signals)."""

import json
import os
import signal
import stat
import subprocess
import sys
import time

import pytest

from conftest import SHUNT_MAIN
from shunt import migrate
from shunt.providers import ProviderError

SECRET = "sk-super-secret-value-123"


class FakeStdin:
    def __init__(self, text="", tty=False):
        self._lines = text.splitlines(keepends=True)
        self._tty = tty

    def isatty(self):
        return self._tty

    def readline(self):
        return self._lines.pop(0) if self._lines else ""


class Mig:
    """One migration sandbox: registry, opencode.json, providers.json and a fake secret-tool."""

    def __init__(self, tmp_path, monkeypatch, server):
        self.tmp, self.server, self.mp = tmp_path, server, monkeypatch
        self.cfg = tmp_path / "cfg"
        self.oc = tmp_path / "oc"
        self.bin = tmp_path / "bin"
        self.models = self.cfg / "models.json"
        self.providers = self.cfg / "providers.json"
        self.store = tmp_path / "store"
        self.argv = tmp_path / "argv"
        for d in (self.cfg, self.oc, self.bin):
            d.mkdir()
        (tmp_path / "proc-version").write_text("Linux version 6.1\n")
        for name, value in {"SHUNT_MODELS_FILE": self.models, "SHUNT_PROVIDERS_FILE": self.providers,
                            "SHUNT_OPENCODE_CONFIG_HOME": self.oc, "PATH": self.bin,
                            "SHUNT_PROC_VERSION_FILE": tmp_path / "proc-version"}.items():
            monkeypatch.setenv(name, str(value))
        monkeypatch.setenv("SHUNT_MODELS_HINT_CMD", "/x/shunt-models")
        self.write_models()
        self.write_opencode(SECRET)

    def write_models(self, models=None):
        models = models or [{"id": "acme/m1", "agent": "a1", "enabled": True, "thinking": False},
                            {"id": "other/x", "agent": "a2", "enabled": True}]
        self.models.write_text(json.dumps({"version": 1, "active": None, "models": models}))

    def write_opencode(self, key, base=None, extra=None):
        options = {"baseURL": base or self.server.url + "/v1"}
        if key is not None:
            options["apiKey"] = key
        doc = {"provider": {
            "acme": {"options": options, "models": {"m1": {"limit": {"context": 65536}, "options": {"reasoningEffort": "low"}}}},
            "unused": {"options": {"baseURL": "https://unused.test/v1", "apiKey": "sk-unused"}, "models": {}},
            **(extra or {})}}
        (self.oc / "opencode.json").write_text(json.dumps(doc))

    def fake_secret_tool(self, exit_code=0):
        script = self.bin / "secret-tool"
        script.write_text(f'#!/bin/sh\necho "$*" >> "{self.argv}"\n[ "$1" = store ] && /bin/cat > "{self.store}"\nexit {exit_code}\n')
        script.chmod(0o755)

    def set_stdin(self, text="", tty=False):
        self.mp.setattr(sys, "stdin", FakeStdin(text, tty))

    def run(self, *argv, stdin="", tty=False):
        """Run in process. Returns (exit code, error line or "")."""
        self.set_stdin(stdin, tty)
        try:
            return migrate.migrate(argv, dict(os.environ)), ""
        except (migrate.MigrateError, ProviderError) as exc:
            return exc.code, str(exc)

    def pdoc(self):
        return json.loads(self.providers.read_text())

    def mdoc(self):
        return json.loads(self.models.read_text())


@pytest.fixture
def mig(tmp_path, monkeypatch, http_server, isolated_env):
    monkeypatch.setattr(sys, "dont_write_bytecode", True)
    return Mig(tmp_path, monkeypatch, http_server)


def test_dry_run_prints_the_plan_and_changes_nothing(mig, capsys, isolated_env):
    before = mig.models.read_text()

    code, _ = mig.run("--key-storage", "plaintext")

    out = capsys.readouterr()
    assert code == 0
    assert "shunt: migration plan (dry run, nothing is changed)" in out.out
    assert "provider acme: base_url " + mig.server.url + "/v1, transport opencode -> http, key: " \
           "copied to providers.json as plain text (mode 600, never shown)" in out.out
    assert "re-run with --apply to write it" in out.out
    assert SECRET not in out.out + out.err
    assert not mig.providers.exists() and mig.models.read_text() == before
    assert list(isolated_env["TMPDIR"].iterdir()) == []


def test_dry_run_defers_detection_for_a_stored_key(mig, capsys):
    doc = json.loads((mig.oc / "opencode.json").read_text())
    del doc["provider"]["acme"]["models"]["m1"]["limit"]
    (mig.oc / "opencode.json").write_text(json.dumps(doc))

    mig.run("--key-storage", "plaintext")

    out = capsys.readouterr().out
    assert "context_tokens detected at --apply, else the opencode.json limit (not verified)" in out
    assert mig.server.requests == []


def test_apply_with_plaintext_storage_writes_the_files_and_detects_with_the_key(mig, capsys):
    mig.server.script("/v1/models/m1", body={"context_length": 131072})

    code, _ = mig.run("--apply", "--yes", "--key-storage", "plaintext")

    out = capsys.readouterr()
    assert code == 0
    assert mig.pdoc()["providers"]["acme"] == {"transport": "http", "base_url": mig.server.url + "/v1",
                                              "key": {"type": "plaintext", "ref": SECRET}}
    assert stat.S_IMODE(mig.providers.stat().st_mode) == 0o600
    model = mig.mdoc()["models"][0]
    assert model["request_body"] == {"reasoning_effort": "low"} and model["context_tokens"] == 131072
    assert mig.server.requests[0].headers["authorization"] == f"Bearer {SECRET}"
    assert "shunt: migration applied. Check with: /x/shunt-models status" in out.out
    assert "stored in plain text" in out.out
    assert SECRET not in out.out + out.err


def test_apply_backs_up_both_files_with_mode_600(mig, capsys):
    mig.providers.write_text(json.dumps({"version": 1, "providers": {}}))

    mig.run("--apply", "--yes", "--key-storage", "env")

    backups = sorted(p.name for p in mig.cfg.glob("*.bak-*"))
    assert [b.split(".bak-")[0] for b in backups] == ["models.json", "providers.json"]
    assert all(stat.S_IMODE((mig.cfg / b).stat().st_mode) == 0o600 for b in backups)
    assert capsys.readouterr().out.count("shunt: backup: ") == 2


def test_an_env_key_reuses_its_name_and_detects_in_the_dry_run(mig, capsys, monkeypatch):
    mig.write_opencode("{env:ACME_KEY}")
    monkeypatch.setenv("ACME_KEY", SECRET)
    mig.server.script("/v1/models/m1", body={"context_length": 4096})

    mig.run()

    out = capsys.readouterr().out
    assert "key: env ACME_KEY (export it yourself, the key is not copied)" in out
    assert "context_tokens 4096 (detected from the provider)" in out


def test_a_taken_default_env_ref_gets_a_numeric_suffix(mig, capsys):
    mig.providers.write_text(json.dumps({"version": 1, "providers": {"other": {
        "transport": "http", "base_url": "https://o.test", "key": {"type": "env", "ref": "SHUNT_ACME_KEY"}}}}))

    mig.run("--apply", "--yes", "--key-storage", "env")

    assert mig.pdoc()["providers"]["acme"]["key"] == {"type": "env", "ref": "SHUNT_ACME_KEY_2"}
    assert "the default env ref is taken by another provider, so this one gets SHUNT_ACME_KEY_2" in capsys.readouterr().out


def test_keyring_storage_gives_the_key_on_stdin_only(mig, capsys):
    mig.fake_secret_tool()

    code, _ = mig.run("--apply", "--yes", "--key-storage", "keyring")

    out = capsys.readouterr()
    assert code == 0
    assert mig.store.read_text() == SECRET + "\n"
    assert SECRET not in mig.argv.read_text() + out.out + out.err
    assert mig.pdoc()["providers"]["acme"]["key"] == {"type": "keyring"}


def test_a_failed_keyring_store_leaves_the_provider_pending(mig, capsys):
    mig.fake_secret_tool(exit_code=1)

    code, _ = mig.run("--apply", "--yes", "--key-storage", "keyring")

    err = capsys.readouterr().err
    assert code == 0
    assert "could not store the key of 'acme' in the keyring, leaving it pending." in err
    assert mig.pdoc()["providers"]["acme"]["transport"] == "opencode"
    assert SECRET not in err


def test_keyring_without_a_backend_is_treated_as_skip(mig, capsys):
    mig.run("--key-storage", "keyring")

    captured = capsys.readouterr()
    assert "no keyring backend found, treating the key of 'acme' as skip." in captured.err
    assert "opencode (stays, key pending)" in captured.out
    assert "skipped: run `! /x/shunt-models key set acme` then re-run" in captured.out


def test_without_a_tty_and_a_flag_the_key_is_skipped(mig, capsys):
    mig.run()

    assert "no tty and no --key-storage: treating it as skip." in capsys.readouterr().err


def test_with_a_tty_the_dry_run_asks_at_apply_time(mig, capsys):
    mig.run(tty=True)

    assert "key to copy, storage is asked at --apply" in capsys.readouterr().out


def test_apply_asks_for_the_storage_on_the_tty(mig, capsys):
    code, _ = mig.run("--apply", "--yes", stdin="plaintext\n", tty=True)

    assert code == 0
    assert "Key storage for 'acme' (keyring env plaintext skip, default env): " in capsys.readouterr().err
    assert mig.pdoc()["providers"]["acme"]["key"]["ref"] == SECRET


def test_an_unknown_storage_answer_skips_the_key(mig, capsys):
    mig.run("--apply", "--yes", stdin="nonsense\n", tty=True)

    assert "'nonsense' is not a storage choice, skipping the key of 'acme'." in capsys.readouterr().err
    assert mig.pdoc()["providers"]["acme"]["transport"] == "opencode"


def test_declining_the_prompt_changes_nothing(mig, capsys):
    code, _ = mig.run("--apply", "--key-storage", "env", stdin="n\n", tty=True)

    out = capsys.readouterr()
    assert code == 0 and "shunt: aborted, nothing changed." in out.out
    assert "Proceed? [y/N] " in out.err
    assert not mig.providers.exists()


def test_accepting_the_prompt_applies(mig):
    code, _ = mig.run("--apply", "--key-storage", "env", stdin="yes\n", tty=True)

    assert code == 0 and mig.pdoc()["providers"]["acme"]["key"]["type"] == "env"


def test_apply_without_a_terminal_or_yes_is_refused(mig):
    code, message = mig.run("--apply", "--key-storage", "env")

    assert code == 1 and message.startswith("refusing to apply without a terminal or --yes.")
    assert not mig.providers.exists()


@pytest.mark.parametrize("argv,message", [
    (("--key-storage", "bogus"), "--key-storage takes one of: keyring env plaintext skip."),
    (("--key-storage",), "--key-storage takes one of: keyring env plaintext skip."),
    (("--nope",), "usage: shunt-models --migrate-from-opencode [--apply [--yes]] [--key-storage keyring|env|plaintext|skip]"),
])
def test_bad_arguments_are_reported(mig, argv, message):
    assert mig.run(*argv) == (1, message)


def test_missing_inputs_are_reported(mig):
    mig.models.unlink()
    assert mig.run() == (1, f"no models registry at {mig.models}.")
    mig.write_models()
    (mig.oc / "opencode.json").unlink()
    assert mig.run() == (1, f"no {mig.oc}/opencode.json to migrate from.")


def test_a_file_key_is_expanded_trimmed_and_never_shown(mig, capsys, isolated_env):
    (isolated_env["HOME"] / "k").write_text(SECRET + "\n\n")
    mig.write_opencode("{file:~/k}")

    mig.run("--apply", "--yes", "--key-storage", "plaintext")

    out = capsys.readouterr()
    assert mig.pdoc()["providers"]["acme"]["key"]["ref"] == SECRET
    assert "read from the apiKey file ~/k (never shown), then copied to providers.json" in out.out
    assert SECRET not in out.out + out.err


def test_an_unreadable_key_file_keeps_the_provider_on_opencode(mig, capsys):
    mig.write_opencode("{file:missing.key}")

    mig.run("--key-storage", "plaintext")

    out = capsys.readouterr().out
    assert "skipped, the apiKey file missing.key is not readable or is empty, so the key cannot be copied, " \
           "the provider stays on opencode" in out


def test_a_key_in_auth_json_is_copied(mig, capsys, isolated_env):
    auth = isolated_env["XDG_DATA_HOME"] / "opencode" / "auth.json"
    auth.parent.mkdir()
    auth.write_text(json.dumps({"acme": {"type": "api", "key": f"  {SECRET}  "}}))
    mig.write_opencode(None)

    mig.run("--apply", "--yes", "--key-storage", "plaintext")

    assert SECRET not in capsys.readouterr().out
    assert mig.pdoc()["providers"]["acme"]["key"]["ref"] == SECRET


def test_no_key_anywhere_migrates_with_key_type_none(mig):
    mig.write_opencode(None)

    mig.run("--apply", "--yes")

    assert mig.pdoc()["providers"]["acme"]["key"] == {"type": "none"}


def test_a_provider_already_on_http_has_nothing_to_do(mig, capsys):
    mig.providers.write_text(json.dumps({"version": 1, "providers": {"acme": {
        "transport": "http", "base_url": "https://a.test", "key": {"type": "none"}}}}))
    mig.write_models([{"id": "acme/m1", "agent": "a1", "enabled": True, "request_body": {"x": 1}, "context_tokens": 5}])

    code, _ = mig.run()

    out = capsys.readouterr().out
    assert code == 0 and "provider acme: already on the http transport, nothing to do for the provider" in out
    assert "shunt: nothing to migrate, nothing to do." in out


@pytest.mark.parametrize("base,reason", [
    ("ftp://a.test", "provider 'acme': base_url scheme must be http:// or https:// (config problem, no request sent)."),
    ("https://u:p@a.test", "provider 'acme': base_url is malformed or has credentials in it (config problem, no request sent)."),
])
def test_an_unusable_base_url_skips_the_provider(mig, capsys, base, reason):
    mig.write_opencode(SECRET, base=base)

    mig.run("--key-storage", "plaintext")

    assert f"provider acme: skipped, {reason}" in capsys.readouterr().out


def test_a_scheme_less_base_url_gets_https(mig):
    mig.write_opencode(None, base="api.acme.test/v1")

    mig.run("--apply", "--yes")

    assert mig.pdoc()["providers"]["acme"]["base_url"] == "https://api.acme.test/v1"


def test_an_invalid_provider_name_is_skipped(mig, capsys):
    mig.write_models([{"id": "bad name/m", "agent": "a", "enabled": True}])
    mig.write_opencode(None, extra={"bad name": {"options": {"baseURL": "https://b.test"}}})

    mig.run()

    assert "provider bad name: skipped, the provider name has characters other than" in capsys.readouterr().out


def test_a_non_string_api_key_adds_a_note_to_the_reason(mig, capsys):
    mig.write_opencode(None, base="ftp://a.test")
    doc = json.loads((mig.oc / "opencode.json").read_text())
    doc["provider"]["acme"]["options"]["apiKey"] = 42
    (mig.oc / "opencode.json").write_text(json.dumps(doc))

    mig.run()

    assert "(config problem, no request sent). the apiKey in opencode.json is not a string, " \
           "so it is not imported as a key" in capsys.readouterr().out


def test_the_opencode_limit_is_the_fallback_when_detection_finds_nothing(mig, capsys):
    mig.run("--key-storage", "env")

    assert "context_tokens 65536 (from opencode.json, not verified)" in capsys.readouterr().out


def test_models_with_a_request_body_or_context_are_left_alone(mig):
    mig.write_models([{"id": "acme/m1", "agent": "a1", "enabled": True, "request_body": {"x": 1}, "context_tokens": 7}])

    mig.run("--apply", "--yes", "--key-storage", "env")

    model = mig.mdoc()["models"][0]
    assert model["request_body"] == {"x": 1} and model["context_tokens"] == 7


def test_apply_fails_when_another_process_holds_the_providers_lock(mig, capsys, monkeypatch):
    monkeypatch.setenv("SHUNT_PROVIDERS_LOCK_TIMEOUT", "0")
    holder = subprocess.Popen(
        [sys.executable, "-I", "-B", "-c",
         "import fcntl,sys,time\nf=open(sys.argv[1]+'.lock','a')\nfcntl.flock(f,fcntl.LOCK_EX)\n"
         "print('ready',flush=True)\ntime.sleep(30)", str(mig.providers)],
        stdout=subprocess.PIPE, text=True)
    try:
        assert holder.stdout.readline().strip() == "ready"

        code, message = mig.run("--apply", "--yes", "--key-storage", "env")
    finally:
        holder.kill()
        holder.wait()

    assert code == 1 and message == f"could not lock {mig.providers}."
    assert f"timed out waiting for the lock on {mig.providers}." in capsys.readouterr().err
    assert not mig.providers.exists()


def test_a_missing_temp_dir_is_reported(mig, monkeypatch, tmp_path):
    monkeypatch.setenv("TMPDIR", str(tmp_path / "nowhere"))

    assert mig.run() == (1, f"cannot create a temp file in {tmp_path / 'nowhere'}.")


def test_killing_a_dry_run_during_detection_leaves_no_key_in_tmpdir(mig, isolated_env, monkeypatch):
    mig.providers.write_text(json.dumps({"version": 1, "providers": {"acme": {
        "transport": "http", "base_url": mig.server.url + "/v1", "key": {"type": "plaintext", "ref": SECRET}}}}))
    mig.server.script("/v1/models/m1", body={"context_length": 1}, delay=30)
    proc = subprocess.Popen([sys.executable, "-I", "-B", str(SHUNT_MAIN), "migrate", "--"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, env=dict(os.environ))
    try:
        deadline = time.monotonic() + 10
        while not mig.server.requests and time.monotonic() < deadline:
            time.sleep(0.05)
        assert mig.server.requests, "the detection request never arrived"
        proc.send_signal(signal.SIGTERM)
        code = proc.wait(timeout=10)
    finally:
        proc.kill()

    leftovers = [p for p in isolated_env["TMPDIR"].iterdir() if SECRET in p.read_text()]
    assert code == 143 and leftovers == []


def test_the_command_line_exits_with_the_error_status(mig, run_shunt):
    result = run_shunt("migrate", "--", "--bogus")

    assert result.returncode == 1
    assert result.stderr.startswith("shunt: usage: shunt-models --migrate-from-opencode")
    assert result.stdout == ""
