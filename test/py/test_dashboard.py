"""The /model-config dashboard report (dashboard.py), run in process over temp config files."""

import json

import pytest

from shunt import dashboard

KEY = "dash-secret-value-777"


@pytest.fixture
def cfg(tmp_path):
    class Cfg:
        environ = {"HOME": str(tmp_path), "SHUNT_MODELS_FILE": str(tmp_path / "models.json"),
                   "SHUNT_PROVIDERS_FILE": str(tmp_path / "providers.json"),
                   "SHUNT_OPENCODE_CONFIG_HOME": str(tmp_path / "oc"),
                   "SHUNT_BREAKER_STATE_FILE": str(tmp_path / "state.json"),
                   "SHUNT_BREAKER_CONFIG_FILE": str(tmp_path / "bc.json"),
                   "SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE": str(tmp_path / "sf.json"),
                   "SHUNT_PROC_VERSION_FILE": str(tmp_path / "version")}

        @staticmethod
        def models(*models, active=None):
            (tmp_path / "models.json").write_text(json.dumps({"version": 1, "active": active, "models": list(models)}))

        @staticmethod
        def providers(**entries):
            (tmp_path / "providers.json").write_text(json.dumps({"version": 1, "providers": entries}))

        @staticmethod
        def opencode(**entries):
            (tmp_path / "oc").mkdir(exist_ok=True)
            (tmp_path / "oc" / "opencode.json").write_text(json.dumps({"provider": entries}))

        @classmethod
        def report(cls, **extra):
            return dashboard.report({**cls.environ, **extra})

    return Cfg


HTTP = {"transport": "http", "base_url": "https://api.acme.test/v1", "key": {"type": "env", "ref": "ACME_KEY"}}


def test_nothing_configured_is_empty_with_defaults(cfg):
    assert cfg.report() == [
        "registry: missing", "providers_file: missing",
        "breaker threshold=3 default=3 cooldown_seconds=300 default=300 status=enabled",
        "self_fix_retries=1 default=1", "first_choice bulk-read none", "first_choice code-write none",
        "opencode config=absent importable=none", "issue no-models -", "setup: empty"]


def test_a_complete_setup_is_ok_and_never_prints_the_key(cfg):
    cfg.providers(acme=HTTP)
    cfg.models({"id": "acme/m1", "context_tokens": 128000, "thinking": True}, active="acme/m1")
    lines = cfg.report(ACME_KEY=KEY)
    assert "provider acme transport=http base_url=https://api.acme.test/v1 key=env:ACME_KEY key_present=yes" in lines
    assert ("model acme/m1 enabled=yes active=yes roles=bulk-read,code-write thinking=on thinking_off=none "
            "context_tokens=128000 oversize_policy=map_reduce(default) provider_transport=http") in lines
    assert "breaker_state acme/m1 code-write failures=0 open=false" in lines
    assert "first_choice code-write acme/m1" in lines
    assert lines[-1] == "setup: ok"
    assert KEY not in "\n".join(lines)


def test_a_missing_key_and_missing_context_make_the_setup_incomplete(cfg):
    cfg.providers(acme=HTTP)
    cfg.models({"id": "acme/m1"})
    lines = cfg.report()
    assert "issue key-missing acme" in lines and "issue context-missing acme/m1" in lines
    assert lines[-1] == "setup: incomplete"


def test_importable_opencode_providers_skip_those_already_on_http(cfg):
    cfg.models({"id": "oc/m1"}, {"id": "acme/m1"})
    cfg.opencode(oc={"options": {"baseURL": "https://oc.test/v1"}}, acme={"options": {}})
    assert "opencode config=present importable=oc,acme" in cfg.report()
    assert cfg.report()[-1] == "setup: opencode-importable"
    cfg.providers(acme=HTTP)
    lines = cfg.report(ACME_KEY="k")
    assert "opencode config=present importable=oc" in lines


def test_invalid_files_are_reported_not_hidden(cfg, tmp_path):
    (tmp_path / "models.json").write_text("{not json")
    (tmp_path / "providers.json").write_text("[]")
    lines = cfg.report()
    assert lines[:2] == ["registry: invalid", "providers_file: invalid"]
    assert "issue registry-invalid models.json" in lines and "issue providers-invalid providers.json" in lines
    assert lines[-1] == "setup: incomplete"


def test_an_invalid_provider_entry_is_listed_and_flagged(cfg):
    cfg.providers(good=HTTP, bad={"transport": "carrier-pigeon"})
    lines = cfg.report(ACME_KEY="k")
    assert lines[1] == "providers_file: invalid"
    assert "provider bad invalid" in lines and "issue provider-invalid bad" in lines
    assert any(line.endswith("key_present=unknown") for line in lines if line.startswith("provider good"))


def test_the_breaker_status_follows_the_config_and_open_state(cfg, tmp_path):
    cfg.models({"id": "acme/m1"})
    (tmp_path / "bc.json").write_text(json.dumps({"threshold": 999999999, "cooldown_seconds": 60}))
    (tmp_path / "state.json").write_text(json.dumps({"models": {"acme/m1": {"failures": 3, "cooldown_until": 9999999999}}}))
    (tmp_path / "sf.json").write_text(json.dumps({"self_fix_retries": 4}))
    lines = cfg.report()
    assert "breaker threshold=999999999 default=3 cooldown_seconds=60 default=300 status=disabled" in lines
    assert "self_fix_retries=4 default=1" in lines
    assert "breaker threshold=2 default=3 cooldown_seconds=60 default=300 status=enabled" in cfg.report(SHUNT_BREAKER_THRESHOLD="2")
    assert "breaker_state acme/m1 bulk-read failures=3 open=false" in lines
    assert "breaker_state acme/m1 bulk-read failures=3 open=true" in cfg.report(SHUNT_BREAKER_THRESHOLD="2", SHUNT_NOW_EPOCH="1")


def test_a_registry_without_a_bulk_read_model_is_flagged(cfg):
    cfg.models({"id": "acme/m1", "roles": ["code-write"]})
    assert "issue no-bulk-read-model -" in cfg.report()
