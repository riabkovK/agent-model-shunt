import os
import stat
import subprocess
import sys
import time

import pytest

from shunt.lockfile import LockTimeout, file_lock

HOLDER = """
import sys
sys.path.insert(0, sys.argv[1])
from shunt.lockfile import file_lock
with file_lock(sys.argv[2], timeout=5):
    print("held", flush=True)
    sys.stdin.readline()
"""


@pytest.fixture
def holder(tmp_path):
    from conftest import PY_DIR

    procs = []

    def start(target):
        p = subprocess.Popen(
            [sys.executable, "-I", "-B", "-c", HOLDER, str(PY_DIR), str(target)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        procs.append(p)
        assert p.stdout.readline().strip() == "held"
        return p

    yield start
    for p in procs:
        p.stdin.close()
        p.wait(timeout=10)


def test_lock_creates_dot_lock_sibling_with_bash_mode(tmp_path):
    target = tmp_path / "providers.json"
    old = os.umask(0o022)
    try:
        with file_lock(target):
            pass
    finally:
        os.umask(old)

    lock = tmp_path / "providers.json.lock"
    assert lock.exists()
    assert stat.S_IMODE(lock.stat().st_mode) == 0o644


def test_lock_creates_missing_parent_dir(tmp_path):
    with file_lock(tmp_path / "sub" / "f.json"):
        pass

    assert (tmp_path / "sub" / "f.json.lock").exists()


def test_lock_released_after_block_and_after_exception(tmp_path):
    target = tmp_path / "f.json"
    with pytest.raises(RuntimeError):
        with file_lock(target):
            raise RuntimeError("x")

    with file_lock(target, timeout=0):
        pass


def test_nested_lock_in_same_process_does_not_deadlock(tmp_path):
    target = tmp_path / "f.json"

    with file_lock(target, timeout=0.3):
        with file_lock(target, timeout=0.3):
            pass
        # still held after the inner block exits
        assert target.with_name("f.json.lock").exists()


def test_timeout_when_another_process_holds_lock(tmp_path, holder):
    target = tmp_path / "f.json"
    holder(target)

    start = time.monotonic()
    with pytest.raises(LockTimeout) as exc:
        with file_lock(target, timeout=0.3):
            pytest.fail("must not acquire")

    assert 0.25 <= time.monotonic() - start < 3
    assert str(target) in str(exc.value)


def test_acquires_after_holder_releases(tmp_path, holder):
    target = tmp_path / "f.json"
    p = holder(target)
    p.stdin.write("\n")
    p.stdin.flush()
    p.wait(timeout=10)

    with file_lock(target, timeout=2):
        pass


def test_lock_not_inherited_state_is_cleared_after_timeout(tmp_path, holder):
    target = tmp_path / "f.json"
    p = holder(target)
    with pytest.raises(LockTimeout):
        with file_lock(target, timeout=0.1):
            pass
    p.stdin.write("\n")
    p.stdin.flush()
    p.wait(timeout=10)

    with file_lock(target, timeout=2):
        pass


def test_nested_lock_via_relative_and_absolute_path_does_not_deadlock(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)

    with file_lock(tmp_path / "f.json", timeout=0.3):
        with file_lock("f.json", timeout=0.3):
            pass
