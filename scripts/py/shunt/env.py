"""Path and environment resolution, mirroring scripts/lib/*.sh exactly.

Every function takes an env mapping (default os.environ) so tests can pass a
plain dict. Like bash `${VAR:-default}`, an empty value counts as unset.
Note the bash quirks kept on purpose: the registries live under
$HOME/.config and $HOME/.cache (XDG_CONFIG_HOME and XDG_CACHE_HOME are not
consulted), only the orchestrator fragment dir honours XDG_CONFIG_HOME and
only the OpenCode auth file honours XDG_DATA_HOME.
"""

import math
import os
from collections.abc import Mapping
from pathlib import Path

APP_DIR_NAME = "agent-model-shunt"
DEFAULT_PROVIDERS_LOCK_TIMEOUT = 10.0
DEFAULT_CONNECT_TIMEOUT = 5.0


class EnvError(ValueError):
    """An environment variable holds a value that cannot be used."""


def _get(env: Mapping[str, str] | None, name: str, default: str) -> str:
    source = os.environ if env is None else env
    return source.get(name) or default


def home(env: Mapping[str, str] | None = None) -> Path:
    return Path(_get(env, "HOME", ""))


def config_dir(env: Mapping[str, str] | None = None) -> Path:
    return home(env) / ".config" / APP_DIR_NAME


def cache_dir(env: Mapping[str, str] | None = None) -> Path:
    return home(env) / ".cache" / APP_DIR_NAME


def _override(env: Mapping[str, str] | None, name: str, default: Path) -> Path:
    return Path(_get(env, name, str(default)))


def models_file_text(env: Mapping[str, str] | None = None) -> str:
    """SHUNT_MODELS_FILE exactly as set (messages echo it unnormalised), else the default path."""
    return _get(env, "SHUNT_MODELS_FILE", str(config_dir(env) / "models.json"))


def providers_file_text(env: Mapping[str, str] | None = None) -> str:
    """SHUNT_PROVIDERS_FILE exactly as set (messages echo it unnormalised), else the default path."""
    return _get(env, "SHUNT_PROVIDERS_FILE", str(config_dir(env) / "providers.json"))


def proc_version_file_text(env: Mapping[str, str] | None = None) -> str:
    return _get(env, "SHUNT_PROC_VERSION_FILE", "/proc/version")


def providers_file(env: Mapping[str, str] | None = None) -> Path:
    return _override(env, "SHUNT_PROVIDERS_FILE", config_dir(env) / "providers.json")


def models_file(env: Mapping[str, str] | None = None) -> Path:
    return _override(env, "SHUNT_MODELS_FILE", config_dir(env) / "models.json")


def agents_dir(env: Mapping[str, str] | None = None) -> Path:
    return _override(env, "SHUNT_AGENTS_DIR", config_dir(env) / "agents")


def breaker_state_file(env: Mapping[str, str] | None = None) -> Path:
    return _override(env, "SHUNT_BREAKER_STATE_FILE", cache_dir(env) / "breaker-state.json")


def breaker_config_file(env: Mapping[str, str] | None = None) -> Path:
    return _override(env, "SHUNT_BREAKER_CONFIG_FILE", config_dir(env) / "breaker-config.json")


def self_fix_config_file(env: Mapping[str, str] | None = None) -> Path:
    return _override(
        env,
        "SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE",
        config_dir(env) / "code-write-self-fix-config.json",
    )


def opencode_config_home(env: Mapping[str, str] | None = None) -> Path:
    return _override(env, "SHUNT_OPENCODE_CONFIG_HOME", home(env) / ".config" / "opencode")


def isolated_config_dir(env: Mapping[str, str] | None = None) -> Path:
    return _override(env, "SHUNT_ISOLATED_CONFIG_DIR", cache_dir(env) / "opencode-config")


def orchestrator_dir(env: Mapping[str, str] | None = None) -> Path:
    xdg_config = Path(_get(env, "XDG_CONFIG_HOME", str(home(env) / ".config")))
    return _override(env, "SHUNT_ORCHESTRATOR_DIR", xdg_config / APP_DIR_NAME / "orchestrator.d")


def opencode_auth_json(env: Mapping[str, str] | None = None) -> Path:
    data_home = Path(_get(env, "XDG_DATA_HOME", str(home(env) / ".local" / "share")))
    return data_home / "opencode" / "auth.json"


def tmp_dir(env: Mapping[str, str] | None = None) -> Path:
    return Path(_get(env, "TMPDIR", "/tmp"))


def providers_lock_timeout(env: Mapping[str, str] | None = None) -> float:
    raw = _get(env, "SHUNT_PROVIDERS_LOCK_TIMEOUT", "")
    if not raw:
        return DEFAULT_PROVIDERS_LOCK_TIMEOUT
    try:
        value = float(raw)
    except ValueError:
        raise EnvError(f"SHUNT_PROVIDERS_LOCK_TIMEOUT must be a number, got {raw!r}") from None
    if not math.isfinite(value) or value < 0:
        raise EnvError(f"SHUNT_PROVIDERS_LOCK_TIMEOUT must be a finite non-negative number, got {raw!r}")
    return value


def connect_timeout(env: Mapping[str, str] | None = None) -> float:
    """SHUNT_CONNECT_TIMEOUT in seconds: how long a connect may take. 0 means only the overall timeout applies."""
    raw = _get(env, "SHUNT_CONNECT_TIMEOUT", "")
    if not raw:
        return DEFAULT_CONNECT_TIMEOUT
    try:
        value = float(raw)
    except ValueError:
        raise EnvError(f"SHUNT_CONNECT_TIMEOUT must be a number, got {raw!r}") from None
    if not math.isfinite(value) or value < 0:
        raise EnvError(f"SHUNT_CONNECT_TIMEOUT must be a finite non-negative number, got {raw!r}")
    return value
