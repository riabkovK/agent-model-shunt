import json
import os
import re
import stat
import subprocess
import sys

import pytest

from conftest import REPO_ROOT, SHUNT_MAIN
from shunt import providers
from shunt.lockfile import file_lock

SECRET = "sk-super-secret-value-123"


@pytest.fixture
def prov(tmp_path):
    """A providers.json in tmp_path, a fake bin dir for keyring CLIs, and a CLI runner."""

    class Prov:
        file = tmp_path / "providers.json"
        bin = tmp_path / "fakebin"
        argv_log = tmp_path / "argv.log"
        store = tmp_path / "store"
        proc_version = tmp_path / "proc-version"
        tmp = tmp_path / "authtmp"
        env = {}

        def write(self, doc):
            self.file.write_text(json.dumps(doc) if not isinstance(doc, str) else doc)

        def fake(self, name, lookup_fails=False):
            """A CLI that logs its argv and keeps stdin in a file. It never echoes stdin."""
            self.bin.mkdir(exist_ok=True)
            tool = self.bin / name
            tool.write_text(
                "#!/bin/bash\n"
                'printf "%s\\n" "$0 $*" >>"$FAKE_ARGV"\n'
                'case "$*" in\n'
                "  *store*|*add-generic-password*|*\" -w \"*)\n"
                '    while IFS= read -r line || [ -n "$line" ]; do printf "%s\\n" "$line"; done >"$FAKE_STORE" ;;\n'
                "  *)\n"
                '    [ -f "$FAKE_STORE" ] || exit 1\n'
                '    while IFS= read -r line || [ -n "$line" ]; do printf "%s\\n" "$line"; done <"$FAKE_STORE" ;;\n'
                "esac\n"
            )
            tool.chmod(0o755)

        def cli(self, *args, stdin="", extra_env=None, path=None):
            env = {
                "HOME": os.environ["HOME"],
                "PATH": path if path is not None else str(self.bin),
                "TMPDIR": str(self.tmp),
                "SHUNT_PROVIDERS_FILE": str(self.file),
                "SHUNT_PROC_VERSION_FILE": str(self.proc_version),
                "FAKE_ARGV": str(self.argv_log),
                "FAKE_STORE": str(self.store),
                **(extra_env or {}),
            }
            return subprocess.run([sys.executable, "-I", "-B", str(SHUNT_MAIN), "providers", *args],
                                  input=stdin, capture_output=True, text=True, env=env, check=False)

        def argv(self):
            return self.argv_log.read_text() if self.argv_log.exists() else ""

    p = Prov()
    p.tmp.mkdir()
    p.proc_version.write_text("Linux version 6.1 (gcc)\n")
    return p


def doc(**providers_):
    return {"version": 1, "providers": providers_}


# ---------------------------------------------------------------- validate

def test_validate_accepts_a_missing_file(prov):
    r = prov.cli("validate")
    assert (r.returncode, r.stdout, r.stderr) == (0, "", "")


def test_validate_accepts_a_valid_file(prov):
    prov.write(doc(p={"transport": "http", "base_url": "https://x/v1", "key": {"type": "none"}}, q={}))
    assert prov.cli("validate").returncode == 0


@pytest.mark.parametrize("text", ["not json", "", "[]", '{"providers":[]}', '{"providers":null}', "null"])
def test_validate_reports_invalid_json_or_missing_providers(prov, text):
    prov.write(text)
    r = prov.cli("validate")
    assert r.returncode == 1
    assert r.stderr == f'shunt: {prov.file} is invalid JSON or has no "providers" object.\n'
    assert "Traceback" not in r.stderr


@pytest.mark.parametrize("entry,message", [
    (5, 'provider "p": entry is not an object'),
    ({"transport": 3}, 'provider "p": transport is not a string'),
    ({"transport": "grpc"}, 'provider "p": unknown transport "grpc" (allowed: http opencode)'),
    ({"base_url": 3}, 'provider "p": base_url is not a string'),
    ({"base_url": "https://u:pw@host/x"}, 'provider "p": base_url has credentials (user:password@) in it'),
    ({"key": "abc"}, 'provider "p": key is not an object (expected {"type":"...","ref":"..."})'),
    ({"key": {"type": 3}}, 'provider "p": key type is not a string'),
    ({"key": {"type": "vault"}}, 'provider "p": unknown key type "vault" (allowed: keyring env plaintext none)'),
    ({"key": {"type": "env", "ref": 3}}, 'provider "p": key ref is not a string'),
    ({"key": {"type": "env", "ref": "1BAD"}}, 'provider "p": env key ref is not a valid environment variable name'),
])
def test_validate_names_the_first_problem(prov, entry, message):
    prov.write(doc(p=entry))
    r = prov.cli("validate")
    assert r.returncode == 1
    assert r.stderr == f"shunt: {prov.file}: {message}\n"


def test_validate_refuses_a_bad_provider_name(prov):
    prov.write(doc(**{"bad name": {}}))
    r = prov.cli("validate")
    assert r.returncode == 1
    assert 'provider "bad name": provider name has characters other than' in r.stderr
    assert "Please edit providers.json to remove or rename that entry" in r.stderr


def test_validate_rejects_a_name_with_a_trailing_newline(prov):
    prov.write(json.dumps(doc(**{"ok\n": {}})))
    assert prov.cli("validate").returncode == 1


def test_validate_with_key_false_reports_could_not_validate(prov):
    prov.write(doc(p={"key": False}))
    r = prov.cli("validate")
    assert r.returncode == 1
    assert r.stderr == f"shunt: {prov.file} could not be validated.\n"


def test_validate_never_prints_a_key_ref(prov):
    prov.write(doc(p={"key": {"type": "plaintext", "ref": SECRET, "extra": 1}, "transport": "grpc"}))
    r = prov.cli("validate")
    assert SECRET not in r.stdout + r.stderr


def test_validate_does_not_take_the_providers_lock(prov):
    prov.write(doc(p={}))
    with file_lock(prov.file):
        r = prov.cli("validate")
        assert r.returncode == 0
        assert prov.cli("field", "transport", "--", "p").stdout == "opencode\n"


# ---------------------------------------------------------------- list-lines

def test_list_lines_formats_rows_and_marks_invalid_entries(prov):
    prov.write(doc(
        a={"transport": "http", "base_url": "https://a/v1", "key": {"type": "env", "ref": "A_KEY"}},
        b={},
        c={"transport": "http", "key": {"type": "plaintext", "ref": SECRET}},
        d={"transport": "grpc"},
    ))
    r = prov.cli("list-lines")
    assert r.returncode == 0
    assert r.stdout.split("\n")[:-1] == [
        "a\thttp\thttps://a/v1\tenv:A_KEY",
        "b\topencode\t-\tnone",
        "c\thttp\t-\tplaintext",
        'd\tinvalid: provider "d": unknown transport "grpc" (allowed: http opencode)',
    ]
    assert SECRET not in r.stdout + r.stderr


def test_list_lines_keeps_an_empty_base_url_empty(prov):
    prov.write(doc(a={"base_url": ""}))
    assert prov.cli("list-lines").stdout == "a\topencode\t\tnone\n"


def test_list_lines_on_a_bad_file_fails_without_a_traceback(prov):
    prov.write("{")
    r = prov.cli("list-lines")
    assert r.returncode != 0
    assert "Traceback" not in r.stderr


# ---------------------------------------------------------------- base-url-check

@pytest.mark.parametrize("url,code", [
    ("https://api.x.test/v1", 0),
    ("http://localhost:8080", 0),
    ("api.x.test/v1", 3),
    ("ftp://x", 2),
    ("ws://x/y", 2),
    ("https://", 1),
    ("https:///v1", 1),
    ("", 1),
    ("https://u:p@host", 1),
    ("https://host/a b", 1),
    ("https://host/\x1b", 1),
    ("https://host\t/x", 1),
    ("https://host/p@q", 0),
    ("host?x=a@b", 3),
])
def test_base_url_check_codes(url, code):
    assert providers.base_url_check(url) == code


def test_base_url_check_cli_exit_code_and_no_output(prov):
    r = prov.cli("base-url-check", "--", "ftp://x")
    assert (r.returncode, r.stdout, r.stderr) == (2, "", "")


# ---------------------------------------------------------------- field getters

def test_fields_default_when_the_file_or_the_provider_is_absent(prov):
    for name, default in (("transport", "opencode"), ("base-url", ""), ("key-type", "none"), ("key-ref", "")):
        assert prov.cli("field", name, "--", "p").stdout == default + "\n"
    prov.write(doc(other={}))
    assert prov.cli("field", "transport", "--", "p").stdout == "opencode\n"


def test_fields_read_the_provider(prov):
    prov.write(doc(p={"transport": "http", "base_url": "https://x/v1", "key": {"type": "env", "ref": "MY_KEY"}}))
    out = {n: prov.cli("field", n, "--", "p").stdout for n in ("transport", "base-url", "key-type", "key-ref")}
    assert out == {"transport": "http\n", "base-url": "https://x/v1\n", "key-type": "env\n", "key-ref": "MY_KEY\n"}


def test_field_fails_with_the_validation_message(prov):
    prov.write(doc(p={"transport": "grpc"}))
    r = prov.cli("field", "transport", "--", "p")
    assert r.returncode == 1
    assert 'unknown transport "grpc"' in r.stderr and r.stdout == ""


def test_field_accepts_a_provider_starting_with_a_dash(prov):
    prov.write(doc(**{"-x": {"transport": "http"}}))
    assert prov.cli("field", "transport", "--", "-x").returncode == 1  # invalid name, but parsed as a name


# ---------------------------------------------------------------- keyring backend

def test_backend_prefers_secret_tool_then_security_then_kwallet(prov):
    assert prov.cli("keyring-backend").stdout == ""
    prov.fake("kwallet-query")
    assert prov.cli("keyring-backend").stdout == "kwallet-query\n"
    prov.fake("security")
    assert prov.cli("keyring-backend").stdout == "security\n"
    prov.fake("secret-tool")
    assert prov.cli("keyring-backend").stdout == "secret-tool\n"


def test_backend_is_empty_under_wsl(prov):
    prov.fake("secret-tool")
    prov.proc_version.write_text("Linux version 5.15 microsoft-standard-WSL2\n")
    r = prov.cli("keyring-backend")
    assert (r.returncode, r.stdout) == (0, "")


# ---------------------------------------------------------------- keyring store and get

@pytest.mark.parametrize("tool", ["secret-tool", "kwallet-query"])
def test_store_and_get_round_trip_keep_the_key_out_of_argv_and_stderr(prov, tool):
    prov.fake(tool)
    stored = prov.cli("keyring-store", "--", "p", stdin=SECRET + "\n")
    got = prov.cli("keyring-get", "--", "p")
    assert (stored.returncode, stored.stdout, stored.stderr) == (0, "", "")
    assert got.stdout == SECRET + "\n"
    assert SECRET not in prov.argv()
    assert SECRET not in stored.stderr + got.stderr
    assert "account p" in prov.argv() or "-w p kdewallet" in prov.argv()


def test_secret_tool_store_argv_shape(prov):
    prov.fake("secret-tool")
    prov.cli("keyring-store", "--", "acme", stdin=SECRET + "\n")
    line = prov.argv().strip()
    assert line.endswith("store --label=agent-model-shunt acme service agent-model-shunt account acme")
    assert prov.store.read_text() == SECRET + "\n"


def test_security_store_keeps_the_documented_argv_limitation(prov):
    prov.fake("security")
    r = prov.cli("keyring-store", "--", "p", stdin=SECRET + "\n")
    assert r.returncode == 0
    assert "add-generic-password -U -s agent-model-shunt/p -a agent-model-shunt -w " + SECRET in prov.argv()
    assert SECRET not in r.stderr and SECRET not in r.stdout


def test_store_without_a_backend_fails_without_reading_stdin(prov):
    r = prov.cli("keyring-store", "--", "p", stdin=SECRET + "\n")
    assert (r.returncode, r.stderr) == (1, "shunt: no keyring backend available.\n")


def test_store_reports_a_failing_tool_without_the_key(prov):
    prov.bin.mkdir()
    tool = prov.bin / "secret-tool"
    tool.write_text("#!/bin/bash\nexit 3\n")
    tool.chmod(0o755)
    r = prov.cli("keyring-store", "--", "p", stdin=SECRET + "\n")
    assert (r.returncode, r.stderr) == (1, "shunt: storing the key in secret-tool failed.\n")


def test_get_returns_1_for_a_missing_entry_and_without_a_backend(prov):
    assert prov.cli("keyring-get", "--", "p").returncode == 1
    prov.fake("secret-tool")
    r = prov.cli("keyring-get", "--", "p")
    assert (r.returncode, r.stdout, r.stderr) == (1, "", "")


# ---------------------------------------------------------------- key-resolve

def test_resolve_none_prints_nothing(prov):
    prov.write(doc(p={"key": {"type": "none"}}))
    r = prov.cli("key-resolve", "--", "p")
    assert (r.returncode, r.stdout, r.stderr) == (0, "", "")
    assert prov.cli("key-resolve", "--", "unknown").stdout == ""


def test_resolve_env_reads_the_exported_variable(prov):
    prov.write(doc(p={"key": {"type": "env", "ref": "MY_KEY_VAR"}}))
    r = prov.cli("key-resolve", "--", "p", extra_env={"MY_KEY_VAR": SECRET})
    assert (r.returncode, r.stdout, r.stderr) == (0, SECRET + "\n", "")


def test_resolve_env_unset_names_the_variable_only(prov):
    prov.write(doc(p={"key": {"type": "env", "ref": "MY_KEY_VAR"}}))
    r = prov.cli("key-resolve", "--", "p")
    assert (r.returncode, r.stdout) == (1, "")
    assert r.stderr == "shunt: provider 'p': environment variable MY_KEY_VAR is unset or empty.\n"


def test_resolve_env_ref_with_a_trailing_newline_is_stripped_like_bash(prov):
    prov.write(json.dumps(doc(p={"key": {"type": "env", "ref": "MY_KEY\n"}})))
    r = prov.cli("key-resolve", "--", "p", extra_env={"MY_KEY": SECRET})
    assert (r.returncode, r.stdout) == (0, SECRET + "\n")


def test_resolve_plaintext_blank_ref_is_an_error_not_a_silent_no_auth(prov):
    prov.write(json.dumps(doc(p={"key": {"type": "plaintext", "ref": "\n"}})))
    r = prov.cli("key-resolve", "--", "p")
    assert (r.returncode, r.stdout) == (1, "")
    assert "no plaintext key stored" in r.stderr


def test_lone_surrogate_key_gives_no_traceback_and_no_leftover_file(prov):
    prov.write(json.dumps(doc(p={"key": {"type": "plaintext", "ref": "ab\ud800cd"}})))
    r = prov.cli("key-resolve", "--", "p")
    assert "Traceback" not in r.stderr
    assert list(prov.tmp.iterdir()) == []


def test_resolve_plaintext(prov):
    prov.write(doc(p={"key": {"type": "plaintext", "ref": SECRET}}))
    assert prov.cli("key-resolve", "--", "p").stdout == SECRET + "\n"
    prov.write(doc(p={"key": {"type": "plaintext"}}))
    r = prov.cli("key-resolve", "--", "p")
    assert r.returncode == 1
    assert r.stderr == "shunt: provider 'p': no plaintext key stored. Run: shunt-models key set p\n"


def test_resolve_keyring_and_the_missing_entry_hint(prov):
    prov.write(doc(**{"my.p": {"key": {"type": "keyring"}}}))
    prov.fake("secret-tool")
    r = prov.cli("key-resolve", "--", "my.p")
    assert r.returncode == 1
    assert r.stderr == "shunt: provider 'my.p': no key found in the keyring. Run: shunt-models key set my.p\n"
    prov.cli("keyring-store", "--", "my.p", stdin=SECRET + "\n")
    r = prov.cli("key-resolve", "--", "my.p")
    assert (r.returncode, r.stdout, r.stderr) == (0, SECRET + "\n", "")
    assert SECRET not in prov.argv()


def test_resolve_with_an_invalid_file_fails_with_its_message(prov):
    prov.write(doc(p={"transport": "grpc", "key": {"type": "plaintext", "ref": SECRET}}))
    r = prov.cli("key-resolve", "--", "p")
    assert r.returncode == 1 and r.stdout == ""
    assert SECRET not in r.stderr


def test_resolve_keyring_does_not_pass_the_key_to_children_env(prov):
    """The fake tool dumps its environment: the key must not be in it."""
    prov.write(doc(p={"key": {"type": "keyring"}}))
    prov.bin.mkdir()
    dump = prov.bin.parent / "env.dump"
    tool = prov.bin / "secret-tool"
    tool.write_text(f'#!/bin/bash\nenv >"{dump}"\necho "{SECRET}"\n')
    tool.chmod(0o755)
    assert prov.cli("key-resolve", "--", "p").stdout == SECRET + "\n"
    assert SECRET not in dump.read_text()


# ---------------------------------------------------------------- bearer key

def _bearer(prov, extra_env=None):
    environ = {"TMPDIR": str(prov.tmp), **(extra_env or {})}
    return providers.bearer_key(str(prov.file), "p", environ, str(prov.proc_version))


def test_bearer_key_for_type_none_is_none(prov):
    prov.write(doc(p={"key": {"type": "none"}}))
    assert _bearer(prov) is None


@pytest.mark.parametrize("bad", ["abc\nX-Evil: 1", "abc\rX-Evil: 1", "abc\r"])
def test_bearer_key_refuses_a_key_with_a_line_break(prov, bad):
    prov.write(doc(p={"key": {"type": "env", "ref": "BAD_KEY"}}))
    with pytest.raises(providers.ProviderError) as info:
        _bearer(prov, {"BAD_KEY": bad})
    assert str(info.value) == "provider 'p': the key contains a line break."
    assert info.value.code == 1


def test_bearer_key_strips_trailing_newlines_like_command_substitution(prov):
    prov.write(doc(p={"key": {"type": "env", "ref": "K"}}))
    assert _bearer(prov, {"K": SECRET + "\n\n"}) == SECRET


# ---------------------------------------------------------------- bash twin constants

def test_name_regex_matches_the_bash_variable():
    text = (REPO_ROOT / "scripts" / "lib" / "providers.sh").read_text()
    regex = re.search(r"^SHUNT_PROVIDER_NAME_REGEX='(.*?)'", text, re.M).group(1)
    assert regex == "^" + providers._NAME_RE.pattern + "$"


@pytest.mark.parametrize("text,expected", [
    ("abc", "abc"), ("a b", "a\\ b"), ("", "''"), ("a\nb", "$'a\\nb'"), ("a;b", "a\\;b"),
])
def test_bash_quote_matches_printf_q(text, expected):
    assert providers._bash_quote(text) == expected
