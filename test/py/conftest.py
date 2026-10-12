"""Shared pytest setup: isolate user dirs per test and run the CLI via subprocess."""

import subprocess
import sys
from pathlib import Path

import pytest

sys.dont_write_bytecode = True  # in-process imports must not leave __pycache__ either

REPO_ROOT = Path(__file__).resolve().parents[2]
PY_DIR = REPO_ROOT / "scripts" / "py"
SHUNT_MAIN = PY_DIR / "shunt_main.py"

sys.path.insert(0, str(PY_DIR))


@pytest.fixture(autouse=True)
def isolated_env(tmp_path, monkeypatch):
    """Keep HOME, XDG and TMPDIR inside tmp_path so no test reaches real user dirs."""
    dirs = {
        "HOME": tmp_path / "home",
        "XDG_CONFIG_HOME": tmp_path / "xdg-config",
        "XDG_CACHE_HOME": tmp_path / "xdg-cache",
        "XDG_STATE_HOME": tmp_path / "xdg-state",
        "XDG_DATA_HOME": tmp_path / "xdg-data",
        "TMPDIR": tmp_path / "tmp",
    }
    for name, path in dirs.items():
        path.mkdir()
        monkeypatch.setenv(name, str(path))
    return dirs


@pytest.fixture
def run_shunt():
    """Run shunt_main.py as `python -I -B` and return the CompletedProcess."""

    def _run(*args, python=sys.executable):
        return subprocess.run(
            [python, "-I", "-B", str(SHUNT_MAIN), *args],
            capture_output=True,
            text=True,
            check=False,
        )

    return _run
