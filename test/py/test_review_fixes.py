"""Fixes of review 4-6: json reads, locks on the writers, short bodies, broken pipe and Ctrl-C."""

import os
import socket
import subprocess
import sys
import threading

import pytest

from conftest import PY_DIR
from shunt import context_detect, httpclient, jsonio, migrate, models_write, providers, providers_write
from shunt.lockfile import file_lock


# ---------------------------------------------------------------- read_json

def test_read_json_refuses_a_fifo_without_blocking(tmp_path):
    os.mkfifo(tmp_path / "f.json")
    with pytest.raises(jsonio.JsonReadError) as info:
        jsonio.read_json(tmp_path / "f.json")
    assert str(info.value).startswith(f"cannot read {tmp_path}/f.json: ")


def test_read_json_refuses_a_file_over_the_cap(tmp_path, monkeypatch):
    monkeypatch.setattr(jsonio, "MAX_JSON_BYTES", 16)
    (tmp_path / "big.json").write_text('{"a": "' + "x" * 32 + '"}')
    (tmp_path / "ok.json").write_text('{"a": 1}')
    with pytest.raises(jsonio.JsonReadError, match="cannot read .*big.json"):
        jsonio.read_json(tmp_path / "big.json")
    assert jsonio.read_json(tmp_path / "ok.json") == {"a": 1}


# ---------------------------------------------------------------- writer locks

def _hold_then_run(path, args, stdin=""):
    env = {**os.environ, "SHUNT_MODELS_FILE": str(path), "SHUNT_PROVIDERS_FILE": str(path),
           "SHUNT_PROVIDERS_LOCK_TIMEOUT": "0.3"}
    with file_lock(path, 1):
        return subprocess.run([sys.executable, "-I", "-B", str(PY_DIR / "shunt_main.py"), *args], input=stdin,
                              capture_output=True, text=True, check=False, env=env)


@pytest.mark.parametrize("args", [("models-write", "put"), ("models-write", "remove", "x"), ("providers-write", "put")])
def test_the_writers_wait_for_the_lock_and_time_out(tmp_path, args):
    path = tmp_path / "file.json"
    path.write_text("{}")

    result = _hold_then_run(path, args, stdin="{}")

    assert result.returncode == 1
    assert f"shunt: timed out waiting for the lock on {path}." in result.stderr
    assert path.read_text() == "{}"


def test_a_models_write_takes_the_lock_and_leaves_the_registry_valid(tmp_path):
    path = tmp_path / "models.json"
    env = {**os.environ, "SHUNT_MODELS_FILE": str(path)}
    result = subprocess.run([sys.executable, "-I", "-B", str(PY_DIR / "shunt_main.py"), "models-write", "add", "a/b", ""],
                            capture_output=True, text=True, check=False, env=env)
    assert result.returncode == 0 and (tmp_path / "models.json.lock").exists()


# ---------------------------------------------------------------- short body

def _short_body_server():
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)

    def serve():
        conn, _ = listener.accept()
        conn.recv(4096)
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nshort")
        conn.close()
        listener.close()

    threading.Thread(target=serve, daemon=True).start()
    return f"http://127.0.0.1:{listener.getsockname()[1]}/"


def test_a_body_shorter_than_content_length_is_a_receive_error():
    with pytest.raises(httpclient.HttpError) as info:
        httpclient.get(_short_body_server(), timeout=5)
    assert info.value.kind == "recv"


def test_a_complete_body_with_content_length_is_fine(http_server):
    http_server.script("/ok", body="hello")
    assert httpclient.get(http_server.url + "/ok", timeout=5).body == b"hello"


# ---------------------------------------------------------------- broken pipe and Ctrl-C

def _boom(*_a, **_k):
    raise BrokenPipeError(32, "Broken pipe")


def _args(**kw):
    import argparse
    return argparse.Namespace(**kw)


def test_a_broken_pipe_is_not_swallowed_by_the_oserror_clauses(monkeypatch):
    monkeypatch.setattr(models_write, "_dispatch", _boom)
    monkeypatch.setattr(providers_write, "_dispatch", _boom)
    monkeypatch.setattr(providers, "_dispatch", _boom)
    monkeypatch.setattr(migrate, "migrate", _boom)
    for module, args in ((models_write, _args()), (providers_write, _args()), (providers, _args()),
                         (migrate, _args(args=[]))):
        with pytest.raises(BrokenPipeError):
            module.run(args)


def test_a_broken_pipe_in_context_detection_is_not_swallowed(monkeypatch):
    monkeypatch.setattr(providers, "field", _boom)
    with pytest.raises(BrokenPipeError):
        context_detect.detect("acme/m1", dict(os.environ))


def _run_main_with(exc_name):
    code = (f"import sys\nsys.dont_write_bytecode = True\nsys.path.insert(0, {str(PY_DIR)!r})\n"
            f"import shunt_main, shunt.cli\n"
            f"def boom(argv):\n    raise {exc_name}\n"
            f"shunt.cli.main = boom\nsys.exit(shunt_main.run())\n")
    return subprocess.run([sys.executable, "-I", "-B", "-c", code], capture_output=True, text=True, check=False)


def test_shunt_main_maps_a_broken_pipe_to_141():
    result = _run_main_with("BrokenPipeError(32, 'Broken pipe')")
    assert result.returncode == 141 and result.stderr == ""


def test_shunt_main_returns_130_quietly_on_ctrl_c():
    result = _run_main_with("KeyboardInterrupt()")
    assert result.returncode == 130 and result.stderr == "" and result.stdout == ""
