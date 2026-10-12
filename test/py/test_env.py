"""env.py mirrors how scripts/lib/*.sh resolve paths today (same precedence and defaults)."""

from pathlib import Path

from shunt import env as senv


def test_config_dir_uses_home_dot_config_and_ignores_xdg():
    # bash hardcodes $HOME/.config/agent-model-shunt for registries, XDG is not consulted
    e = {"HOME": "/h", "XDG_CONFIG_HOME": "/x"}

    assert senv.config_dir(e) == Path("/h/.config/agent-model-shunt")


def test_cache_dir_uses_home_dot_cache():
    assert senv.cache_dir({"HOME": "/h", "XDG_CACHE_HOME": "/x"}) == Path("/h/.cache/agent-model-shunt")


def test_file_overrides_win_over_defaults():
    e = {
        "HOME": "/h",
        "SHUNT_PROVIDERS_FILE": "/p.json",
        "SHUNT_MODELS_FILE": "/m.json",
        "SHUNT_BREAKER_STATE_FILE": "/b.json",
        "SHUNT_BREAKER_CONFIG_FILE": "/bc.json",
        "SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE": "/sf.json",
        "SHUNT_AGENTS_DIR": "/agents",
        "SHUNT_ISOLATED_CONFIG_DIR": "/iso",
        "SHUNT_OPENCODE_CONFIG_HOME": "/oc",
    }

    assert senv.providers_file(e) == Path("/p.json")
    assert senv.models_file(e) == Path("/m.json")
    assert senv.breaker_state_file(e) == Path("/b.json")
    assert senv.breaker_config_file(e) == Path("/bc.json")
    assert senv.self_fix_config_file(e) == Path("/sf.json")
    assert senv.agents_dir(e) == Path("/agents")
    assert senv.isolated_config_dir(e) == Path("/iso")
    assert senv.opencode_config_home(e) == Path("/oc")


def test_file_defaults_live_under_config_and_cache():
    e = {"HOME": "/h"}

    assert senv.providers_file(e) == Path("/h/.config/agent-model-shunt/providers.json")
    assert senv.models_file(e) == Path("/h/.config/agent-model-shunt/models.json")
    assert senv.agents_dir(e) == Path("/h/.config/agent-model-shunt/agents")
    assert senv.breaker_config_file(e) == Path("/h/.config/agent-model-shunt/breaker-config.json")
    assert senv.self_fix_config_file(e) == Path(
        "/h/.config/agent-model-shunt/code-write-self-fix-config.json"
    )
    assert senv.breaker_state_file(e) == Path("/h/.cache/agent-model-shunt/breaker-state.json")
    assert senv.isolated_config_dir(e) == Path("/h/.cache/agent-model-shunt/opencode-config")
    assert senv.opencode_config_home(e) == Path("/h/.config/opencode")


def test_empty_override_falls_back_like_bash_colon_dash():
    e = {"HOME": "/h", "SHUNT_PROVIDERS_FILE": ""}

    assert senv.providers_file(e) == Path("/h/.config/agent-model-shunt/providers.json")


def test_orchestrator_dir_precedence():
    assert senv.orchestrator_dir({"HOME": "/h", "SHUNT_ORCHESTRATOR_DIR": "/o"}) == Path("/o")
    assert senv.orchestrator_dir({"HOME": "/h", "XDG_CONFIG_HOME": "/x"}) == Path(
        "/x/agent-model-shunt/orchestrator.d"
    )
    assert senv.orchestrator_dir({"HOME": "/h", "XDG_CONFIG_HOME": ""}) == Path(
        "/h/.config/agent-model-shunt/orchestrator.d"
    )


def test_opencode_auth_json_uses_xdg_data_home():
    assert senv.opencode_auth_json({"HOME": "/h", "XDG_DATA_HOME": "/d"}) == Path("/d/opencode/auth.json")
    assert senv.opencode_auth_json({"HOME": "/h"}) == Path("/h/.local/share/opencode/auth.json")


def test_tmp_dir_defaults_to_slash_tmp():
    assert senv.tmp_dir({"TMPDIR": "/t"}) == Path("/t")
    assert senv.tmp_dir({}) == Path("/tmp")
    assert senv.tmp_dir({"TMPDIR": ""}) == Path("/tmp")


def test_providers_lock_timeout_default_and_override():
    assert senv.providers_lock_timeout({}) == 10.0
    assert senv.providers_lock_timeout({"SHUNT_PROVIDERS_LOCK_TIMEOUT": "3"}) == 3.0


def test_providers_lock_timeout_rejects_garbage():
    import pytest

    with pytest.raises(senv.EnvError):
        senv.providers_lock_timeout({"SHUNT_PROVIDERS_LOCK_TIMEOUT": "abc"})


def test_defaults_read_process_environment(isolated_env):
    assert senv.config_dir() == isolated_env["HOME"] / ".config" / "agent-model-shunt"
    assert senv.tmp_dir() == isolated_env["TMPDIR"]


def test_providers_lock_timeout_rejects_nan_and_inf():
    import pytest

    for bad in ("nan", "inf", "-1"):
        with pytest.raises(senv.EnvError):
            senv.providers_lock_timeout({"SHUNT_PROVIDERS_LOCK_TIMEOUT": bad})
