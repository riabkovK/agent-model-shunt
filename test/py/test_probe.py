"""probe: the answers the shell scripts used to get from jq."""

import json
import sys

import pytest

from shunt import probe


@pytest.fixture
def files(tmp_path, monkeypatch):
    monkeypatch.setenv("SHUNT_MODELS_FILE", str(tmp_path / "models.json"))
    monkeypatch.setenv("SHUNT_PROVIDERS_FILE", str(tmp_path / "providers.json"))
    monkeypatch.setenv("SHUNT_OPENCODE_CONFIG_HOME", str(tmp_path))
    return tmp_path


def ask(question, arg="", capsys=None):
    import argparse
    code = probe.run(argparse.Namespace(question=question, arg=arg))
    return code, capsys.readouterr().out if capsys else ""


def test_model_questions_over_a_registry(files, capsys):
    (files / "models.json").write_text(json.dumps({"active": "p/b", "models": [
        {"id": "p/a", "enabled": False, "roles": ["code-write"], "agent": "ag", "thinking": True},
        {"id": "p/b", "thinking_off_options": {}}]}))
    assert ask("model-ids", "", capsys) == (0, "p/a\np/b\n")
    assert ask("active", "", capsys) == (0, "p/b\n")
    assert ask("model-count", "", capsys) == (0, "2\n")
    assert ask("any-enabled")[0] == 0
    assert ask("role-ids", "code-write", capsys) == (0, "p/a\np/b\n")
    assert ask("role-ids", "bulk-read", capsys) == (0, "p/b\n")
    assert ask("has-model", "p/a")[0] == 0 and ask("has-model", "p/z")[0] == 1
    assert ask("status-rows", "", capsys)[1] == (
        "p/a\tag\tdisabled\tthinking=true\tthinking_off=none\troles=code-write\t\n"
        "p/b\tnull\tenabled\tthinking=null\tthinking_off=set\troles=bulk-read,code-write\tactive\n")


def test_a_missing_or_malformed_registry_answers_no(files):
    assert ask("has-models-array")[0] == 1 and ask("model-ids")[0] == 1
    (files / "models.json").write_text('{"models": {}}')
    assert ask("has-models-array")[0] == 1


def test_provider_questions(files, capsys):
    (files / "providers.json").write_text(json.dumps({"providers": {"acme": {"transport": "http"}, "off": None}}))
    (files / "opencode.json").write_text(json.dumps({"provider": {"oc": {}, "nope": None}}))
    assert ask("providers-object")[0] == 0 and ask("providers-empty")[0] == 1
    assert ask("provider-exists", "acme")[0] == 0 and ask("provider-exists", "off")[0] == 1
    assert ask("opencode-provider", "oc")[0] == 0 and ask("opencode-provider", "nope")[0] == 1
    assert ask("provider-name-refusal", "x y", capsys)[1] == (
        "shunt: invalid provider name (use letters, digits, dot, dash, underscore).\n")
    (files / "providers.json").write_text(json.dumps({"providers": {"bad name\n": {}}}))
    assert ask("provider-name-refusal", "bad name\n", capsys)[1].startswith(
        f'shunt: invalid provider name: {files}/providers.json has an entry named "bad name\\n", which')


def test_json_object_reads_stdin(monkeypatch):
    import io
    for text, code in (('{"a": 1}\n', 0), ("[1]\n", 1), ("nope", 1)):
        monkeypatch.setattr(sys, "stdin", io.StringIO(text))
        assert ask("json-object")[0] == code
