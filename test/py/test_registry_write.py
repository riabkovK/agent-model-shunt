"""models-write and providers-write: the registry and providers.json writers."""

import json
import os
import stat
import subprocess
import sys
import time

import pytest

from conftest import SHUNT_MAIN
from shunt.lockfile import file_lock

SECRET = "sk-super-secret-value-123"


@pytest.fixture
def reg(tmp_path):
    class Reg:
        models = tmp_path / "cfg" / "models.json"
        providers = tmp_path / "cfg" / "providers.json"

        def env(self, **extra):
            return {**os.environ, "SHUNT_MODELS_FILE": str(self.models),
                    "SHUNT_PROVIDERS_FILE": str(self.providers), **extra}

        def run(self, *args, stdin="", **extra):
            return subprocess.run([sys.executable, "-I", "-B", str(SHUNT_MAIN), *args], input=stdin,
                                  capture_output=True, text=True, check=False, env=self.env(**extra))

        def seed(self, models, active=None):
            self.models.parent.mkdir(parents=True, exist_ok=True)
            self.models.write_text(json.dumps({"version": 1, "active": active, "models": models}))

        def doc(self):
            return json.loads(self.models.read_text())

        def pdoc(self):
            return json.loads(self.providers.read_text())

        def seed_providers(self, entries):
            self.providers.parent.mkdir(parents=True, exist_ok=True)
            self.providers.write_text(json.dumps({"version": 1, "providers": entries}))

    return Reg()


def mw(reg, *args, **kw):
    return reg.run("models-write", *args, **kw)


def pw(reg, *args, **kw):
    return reg.run("providers-write", *args, **kw)


# ---------------------------------------------------------------- put

def test_put_writes_a_pretty_file_with_mode_600_and_no_temp_left(reg):
    result = mw(reg, "put", stdin='{"version":1,"models":[]}')

    assert result.returncode == 0
    assert reg.doc() == {"version": 1, "models": []}
    assert stat.S_IMODE(reg.models.stat().st_mode) == 0o600
    assert [p.name for p in reg.models.parent.iterdir()] == ["models.json"]


@pytest.mark.parametrize("text", ["", "{not json", "null", "false", "NaN"])
def test_put_refuses_invalid_json_and_keeps_the_old_file(reg, text):
    reg.seed([])
    before = reg.models.read_text()

    result = mw(reg, "put", stdin=text)

    assert result.returncode == 1
    assert result.stderr == "shunt: refusing to write an invalid models registry.\n"
    assert reg.models.read_text() == before


def test_providers_put_has_mode_600_and_refuses_invalid(reg):
    ok = pw(reg, "put", stdin='{"version":1,"providers":{}}')
    bad = pw(reg, "put", stdin="nope")

    assert ok.returncode == 0
    assert stat.S_IMODE(reg.providers.stat().st_mode) == 0o600
    assert (bad.returncode, bad.stderr) == (1, "shunt: refusing to write an invalid providers file.\n")


# ---------------------------------------------------------------- models

def test_parse_roles_keeps_order_and_drops_duplicates(reg):
    result = mw(reg, "parse-roles", "--", "code-write,bulk-read,code-write")

    assert result.stdout == "code-write,bulk-read\n"


@pytest.mark.parametrize("arg,message", [
    ("a\nb", "roles must be a single comma-separated line."),
    ("bulk-read,", "empty role in 'bulk-read,'. Roles: bulk-read code-write"),
    ("nope", "unknown role 'nope'. Known roles: bulk-read code-write"),
])
def test_parse_roles_errors(reg, arg, message):
    result = mw(reg, "parse-roles", "--", arg)

    assert (result.returncode, result.stderr) == (1, f"shunt: {message}\n")


def test_add_creates_the_registry_and_prints_the_agent(reg):
    result = mw(reg, "add", "--", "p/Model-1", "bulk-read")

    assert result.stdout == "shunt-bulk-reader-p-model-1\n"
    assert reg.doc() == {"version": 1, "active": None, "models": [
        {"id": "p/Model-1", "agent": "shunt-bulk-reader-p-model-1", "enabled": True, "thinking": False,
         "thinking_options": None, "thinking_off_options": None, "roles": ["bulk-read"]}]}


def test_add_defaults_to_all_roles_and_refuses_a_duplicate(reg):
    mw(reg, "add", "--", "p/m", "")
    again = mw(reg, "add", "--", "p/m", "")

    assert reg.doc()["models"][0]["roles"] == ["bulk-read", "code-write"]
    assert (again.returncode, again.stderr) == (1, "shunt: model 'p/m' is already in the registry.\n")


def test_remove_drops_the_model_and_clears_active(reg):
    reg.seed([{"id": "a"}, {"id": "b"}], active="a")

    mw(reg, "remove", "--", "a")

    assert reg.doc() == {"version": 1, "active": None, "models": [{"id": "b"}]}


def test_remove_keeps_a_different_active_model(reg):
    reg.seed([{"id": "a"}, {"id": "b"}], active="b")

    mw(reg, "remove", "--", "a")

    assert reg.doc()["active"] == "b"


@pytest.mark.parametrize("position,order", [("1", "cab"), ("2", "acb"), ("3", "abc"), ("99", "abc")])
def test_reorder_moves_to_the_one_based_position(reg, position, order):
    reg.seed([{"id": "a"}, {"id": "b"}, {"id": "c"}])

    mw(reg, "reorder", "--", "c", position)

    assert "".join(m["id"] for m in reg.doc()["models"]) == order


def test_activate_sets_active_and_refuses_a_disabled_model(reg):
    reg.seed([{"id": "a"}, {"id": "b", "enabled": False}])

    ok = mw(reg, "activate", "--", "a")
    refused = mw(reg, "activate", "--", "b")

    assert ok.returncode == 0 and reg.doc()["active"] == "a"
    assert refused.stderr == "shunt: model 'b' is disabled. Enable it first: shunt-models enable b\n"


def test_set_enabled_flips_only_the_flag(reg):
    reg.seed([{"id": "a", "enabled": True, "x": 1}], active="a")

    mw(reg, "set-enabled", "--", "false", "a")

    assert reg.doc()["models"][0] == {"id": "a", "enabled": False, "x": 1}
    assert reg.doc()["active"] == "a"


def test_thinking_on_stores_options_and_off_resets_them(reg):
    reg.seed([{"id": "a", "thinking_off_options": {"e": "none"}}])

    mw(reg, "thinking", "--", "a", "on", '{"effort":"high"}')
    on = reg.doc()["models"][0]
    mw(reg, "thinking", "--", "a", "off", "")
    off = reg.doc()["models"][0]

    assert (on["thinking"], on["thinking_options"], on["thinking_off_options"]) == (True, {"effort": "high"}, {"e": "none"})
    assert (off["thinking"], off["thinking_options"], off["thinking_off_options"]) == (False, None, {"e": "none"})


def test_thinking_off_options_set_and_clear(reg):
    reg.seed([{"id": "a"}])

    mw(reg, "thinking", "--", "a", "off", '{"reasoningEffort":"none"}')
    stored = reg.doc()["models"][0]["thinking_off_options"]
    mw(reg, "thinking", "--", "a", "off", "{}")

    assert stored == {"reasoningEffort": "none"}
    assert reg.doc()["models"][0]["thinking_off_options"] is None


@pytest.mark.parametrize("state,options,message", [
    ("on", "{bad", "thinking options must be valid JSON: {bad"),
    ("on", "null", "thinking options must be valid JSON: null"),
    ("off", "{bad", "thinking options must be valid JSON: {bad"),
    ("off", "[1]", "thinking off options must be a JSON object: [1]"),
])
def test_thinking_option_errors_leave_the_file_alone(reg, state, options, message):
    reg.seed([{"id": "a"}])
    before = reg.models.read_text()

    result = mw(reg, "thinking", "--", "a", state, options)

    assert (result.returncode, result.stderr) == (1, f"shunt: {message}\n")
    assert reg.models.read_text() == before


def test_request_body_set_clear_and_role_entries(reg):
    reg.seed([{"id": "a"}])

    set_all = mw(reg, "request-body", "--", "a", "", '{"temperature":0}')
    set_role = mw(reg, "request-body", "--", "a", "bulk-read", '{"top_p":1}')
    mid = reg.doc()["models"][0]
    clear_role = mw(reg, "request-body", "--", "a", "bulk-read", "--clear")
    clear_all = mw(reg, "request-body", "--", "a", "", "--clear")

    assert (set_all.stdout, set_role.stdout, clear_role.stdout, clear_all.stdout) == ("set\n", "set\n", "cleared\n", "cleared\n")
    assert mid == {"id": "a", "request_body": {"temperature": 0}, "role_request_body": {"bulk-read": {"top_p": 1}}}
    assert reg.doc()["models"][0] == {"id": "a"}


def test_request_body_rejects_a_non_object(reg):
    reg.seed([{"id": "a"}])

    result = mw(reg, "request-body", "--", "a", "", "[1]")

    assert (result.returncode, result.stderr) == (1, "shunt: request body must be a JSON object: [1]\n")


def test_roles_replaces_the_list(reg):
    reg.seed([{"id": "a", "roles": ["bulk-read"]}, {"id": "b", "roles": ["bulk-read"]}])

    mw(reg, "roles", "--", "a", "code-write,bulk-read")

    assert [m["roles"] for m in reg.doc()["models"]] == [["code-write", "bulk-read"], ["bulk-read"]]


def test_set_context_stores_an_int_and_refuses_bad_values(reg):
    reg.seed([{"id": "a"}])

    ok = mw(reg, "set-context", "--", "a", "128000")
    bad = mw(reg, "set-context", "--", "a", "0123")

    assert reg.doc()["models"][0]["context_tokens"] == 128000
    assert bad.returncode == 1


def test_oversize_policy_sets_and_clears(reg):
    reg.seed([{"id": "a"}])

    mw(reg, "oversize-policy", "--", "a", "fail")
    first = reg.doc()["models"][0]
    mw(reg, "oversize-policy", "--", "a", "--clear")

    assert first["oversize_policy"] == "fail"
    assert "oversize_policy" not in reg.doc()["models"][0]


def test_a_registry_without_models_is_refused_not_overwritten(reg):
    reg.models.parent.mkdir(parents=True)
    reg.models.write_text('{"version":1}')

    result = mw(reg, "activate", "--", "a")

    assert result.returncode == 1
    assert reg.models.read_text() == '{"version":1}'


def test_missing_registry_is_reported(reg):
    result = mw(reg, "remove", "--", "a")

    assert result.stderr == f"shunt: no models registry at {reg.models}.\n"


def test_models_file_has_mode_600(reg):
    reg.seed([{"id": "a"}])

    mw(reg, "set-enabled", "--", "true", "a")

    assert stat.S_IMODE(reg.models.stat().st_mode) == 0o600


# ---------------------------------------------------------------- providers set

def pset(reg, name, transport="", url="", ktype="", kref="", flags=(), **extra):
    return pw(reg, "set", *flags, "--", name, transport, url, ktype, kref, **extra)


def test_provider_set_creates_a_new_entry_with_key_none(reg):
    result = pset(reg, "acme", "http", "https://a.test/v1")

    assert result.stdout == "transport http, key none\n"
    assert reg.pdoc() == {"version": 1, "providers": {"acme": {
        "transport": "http", "base_url": "https://a.test/v1", "key": {"type": "none"}}}}
    assert stat.S_IMODE(reg.providers.stat().st_mode) == 0o600


def test_provider_set_new_provider_needs_a_transport(reg):
    result = pset(reg, "acme", "", "", "keyring")

    assert (result.returncode, result.stderr) == (1, "shunt: provider 'acme' is new: --transport is required.\n")
    assert not reg.providers.exists()


def test_provider_set_http_needs_a_base_url(reg):
    result = pset(reg, "acme", "http")

    assert result.stderr == ("shunt: provider 'acme': transport http needs a base_url "
                             "(--base-url http://... or https://...).\n")
    assert not reg.providers.exists()


def test_provider_set_keeps_fields_not_given(reg):
    reg.seed_providers({"acme": {"transport": "http", "base_url": "https://a.test", "extra": 1,
                                 "key": {"type": "env", "ref": "ACME_KEY"}}})

    result = pset(reg, "acme", "", "https://b.test")

    assert result.stdout == "transport http, key env\n"
    assert reg.pdoc()["providers"]["acme"] == {"transport": "http", "base_url": "https://b.test", "extra": 1,
                                               "key": {"type": "env", "ref": "ACME_KEY"}}


def test_provider_set_key_type_changes_drop_the_ref_except_plaintext(reg):
    reg.seed_providers({"p": {"transport": "http", "base_url": "https://a.test",
                              "key": {"type": "plaintext", "ref": "stored"}},
                        "q": {"transport": "http", "base_url": "https://a.test",
                              "key": {"type": "plaintext", "ref": "stored"}}})

    pset(reg, "p", "", "", "plaintext")
    pset(reg, "q", "", "", "keyring")
    pset(reg, "q", "", "", "env", "Q_KEY")

    doc = reg.pdoc()["providers"]
    assert doc["p"]["key"] == {"type": "plaintext", "ref": "stored"}
    assert doc["q"]["key"] == {"type": "env", "ref": "Q_KEY"}


def test_provider_set_refuses_an_invalid_file_without_touching_it(reg):
    reg.providers.parent.mkdir(parents=True)
    reg.providers.write_text('{"providers":{"p":{"transport":"bogus"}}}')
    before = reg.providers.read_text()

    result = pset(reg, "p", "http", "https://a.test")

    assert result.returncode == 1 and "p" in result.stderr
    assert reg.providers.read_text() == before


# ---------------------------------------------------------------- plaintext store

def seed_plain(reg, ktype="plaintext"):
    reg.seed_providers({"p": {"transport": "http", "base_url": "https://a.test", "key": {"type": ktype}}})


def test_plaintext_store_keeps_the_key_off_every_output(reg):
    seed_plain(reg)

    result = pw(reg, "plaintext-store", "--", "p", stdin=SECRET + "\nsecond line\n")

    assert result.returncode == 0
    assert reg.pdoc()["providers"]["p"]["key"] == {"type": "plaintext", "ref": SECRET}
    assert SECRET not in result.stdout + result.stderr
    assert stat.S_IMODE(reg.providers.stat().st_mode) == 0o600


def test_plaintext_store_refuses_a_provider_that_is_not_plaintext(reg):
    seed_plain(reg, "env")
    reg.providers.write_text(json.dumps({"version": 1, "providers": {"p": {
        "transport": "http", "base_url": "https://a.test", "key": {"type": "env", "ref": "P_KEY"}}}}))

    result = pw(reg, "plaintext-store", "--", "p", stdin=SECRET + "\n")

    assert result.returncode == 1
    assert result.stderr == "shunt: provider 'p' no longer has a plaintext key type, nothing stored.\n"
    assert SECRET not in reg.providers.read_text()


def test_plaintext_store_with_a_key_that_cannot_be_encoded_leaks_nothing(reg):
    seed_plain(reg)
    secret = b"\xff" + SECRET.encode()

    result = subprocess.run([sys.executable, "-I", "-B", str(SHUNT_MAIN), "providers-write", "plaintext-store", "--", "p"],
                            input=secret + b"\n", capture_output=True, check=False, env=reg.env())

    assert result.returncode == 1
    assert SECRET.encode() not in result.stdout + result.stderr
    assert reg.pdoc()["providers"]["p"]["key"] == {"type": "plaintext"}


# ---------------------------------------------------------------- locking

def test_provider_set_times_out_while_another_process_holds_the_lock(reg):
    seed_plain(reg)
    started = time.monotonic()

    with file_lock(reg.providers, timeout=1):
        result = pset(reg, "p", "http", "https://b.test", SHUNT_PROVIDERS_LOCK_TIMEOUT="0")

    assert (result.returncode, result.stderr) == (1, f"shunt: timed out waiting for the lock on {reg.providers}.\n")
    assert time.monotonic() - started < 5
    assert reg.pdoc()["providers"]["p"]["base_url"] == "https://a.test"


def test_provider_set_waits_for_the_lock_and_then_writes(reg):
    seed_plain(reg)
    proc = None

    with file_lock(reg.providers, timeout=1):
        proc = subprocess.Popen([sys.executable, "-I", "-B", str(SHUNT_MAIN), "providers-write", "set", "--",
                                 "p", "", "https://b.test", "", ""], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, env=reg.env(SHUNT_PROVIDERS_LOCK_TIMEOUT="20"))
        time.sleep(0.4)
        assert proc.poll() is None
    out, _ = proc.communicate(timeout=20)

    assert proc.returncode == 0 and out == "transport http, key plaintext\n"
    assert reg.pdoc()["providers"]["p"]["base_url"] == "https://b.test"


def test_garbage_lock_timeout_is_reported(reg):
    seed_plain(reg)

    result = pset(reg, "p", "", "https://b.test", SHUNT_PROVIDERS_LOCK_TIMEOUT="soon")

    assert result.returncode == 1 and "SHUNT_PROVIDERS_LOCK_TIMEOUT" in result.stderr
