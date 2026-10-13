"""`provider set` and the migration write the healthcheck flag (on for new providers)."""

import json

import pytest

from shunt import providers_write
from shunt.migrate_plan import make_entry


def _set(path, name="acme", healthcheck="", transport="http"):
    return providers_write.set_provider(str(path), name, transport, "https://api.acme.test/v1", "none", "", healthcheck)


def _entry(path, name="acme"):
    return json.loads(path.read_text())["providers"][name]


def test_a_new_provider_gets_the_healthcheck_on(tmp_path):
    path = tmp_path / "providers.json"
    _set(path)
    assert _entry(path)["healthcheck"] is True


@pytest.mark.parametrize(("flag", "expected"), [("on", True), ("off", False)])
def test_an_explicit_flag_is_written_for_a_new_provider(tmp_path, flag, expected):
    path = tmp_path / "providers.json"
    _set(path, healthcheck=flag)
    assert _entry(path)["healthcheck"] is expected


def test_updating_without_the_flag_keeps_the_value(tmp_path):
    path = tmp_path / "providers.json"
    _set(path, healthcheck="off")
    providers_write.set_provider(str(path), "acme", "", "https://other.test/v1", "", "")
    assert _entry(path)["healthcheck"] is False


def test_updating_an_entry_without_the_field_keeps_it_absent(tmp_path):
    path = tmp_path / "providers.json"
    path.write_text(json.dumps({"version": 1, "providers": {"acme": {
        "transport": "http", "base_url": "https://a.test/v1", "key": {"type": "none"}}}}))
    providers_write.set_provider(str(path), "acme", "", "https://other.test/v1", "", "")
    assert "healthcheck" not in _entry(path)


def test_the_flag_changes_an_existing_provider(tmp_path):
    path = tmp_path / "providers.json"
    _set(path)
    providers_write.set_provider(str(path), "acme", "", "", "", "", "off")
    assert _entry(path)["healthcheck"] is False


@pytest.mark.parametrize("storage", ["keyring", "plaintext", "env", "none", "skip"])
def test_migration_entries_have_the_healthcheck_on(storage):
    assert make_entry(storage, "https://a.test/v1", "REF")["healthcheck"] is True
