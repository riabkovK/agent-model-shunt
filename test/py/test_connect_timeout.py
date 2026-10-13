"""The separate connect timeout: a host that never answers is "unreachable", a slow model is "timeout"."""

import errno
import json
import os
import socket
import time

import pytest

from shunt import breaker, env, failover, httpclient
from shunt import transport_reply as reply
from test_failover import fo, model  # noqa: F401 (the failover fixture)

DEAD_PORT_MARK = "/dead/v1"


@pytest.fixture
def dead_connect(monkeypatch):
    """socket.create_connection that gives up like a connect to a sleeping host. Records the timeouts."""
    for name in ("http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("no_proxy", "*")
    real = socket.create_connection
    seen = []

    def fake(address, timeout=None, *args, **kwargs):
        seen.append(timeout)
        if address[1] == 1:  # the dead host in these tests
            time.sleep(min(timeout or 0, 0.05))
            raise TimeoutError("timed out")
        return real(address, timeout, *args, **kwargs)

    monkeypatch.setattr(socket, "create_connection", fake)
    return seen


# ---------------------------------------------------------------- httpclient

def test_connect_timeout_fires_before_the_overall_timeout_and_is_unreachable(dead_connect):
    started = time.monotonic()
    with pytest.raises(httpclient.HttpError) as info:
        httpclient.get("http://127.0.0.1:1/x", timeout=30, connect_timeout=0.2)
    assert info.value.kind == "unreachable"
    assert time.monotonic() - started < 5
    assert dead_connect == [0.2]


def test_a_slow_server_after_connect_is_still_a_timeout(http_server):
    http_server.script("/slow", body={"ok": 1}, delay=3)
    started = time.monotonic()
    with pytest.raises(httpclient.HttpError) as info:
        httpclient.get(http_server.url + "/slow", timeout=0.4, connect_timeout=0.2)
    assert info.value.kind == "timeout"
    assert time.monotonic() - started < 2.5


def test_the_connected_socket_gets_the_overall_timeout(http_server):
    http_server.script("/ok", body={"ok": 1}, delay=0.5)  # slower than the connect timeout, faster than the total
    resp = httpclient.get(http_server.url + "/ok", timeout=5, connect_timeout=0.2)
    assert resp.ok


@pytest.mark.parametrize("connect", [0, None, 5, 30])
def test_connect_timeout_zero_none_or_not_shorter_than_total_leaves_the_total_in_charge(dead_connect, connect):
    with pytest.raises(httpclient.HttpError) as info:
        httpclient.get("http://127.0.0.1:1/x", timeout=2, connect_timeout=connect)
    assert info.value.kind == "timeout"
    assert dead_connect == [2]


@pytest.mark.parametrize("code", [errno.ENETUNREACH, errno.EHOSTUNREACH])
def test_no_route_is_unreachable_and_refused_stays_connect(monkeypatch, code):
    monkeypatch.setenv("no_proxy", "*")
    def fail(*_a, **_k):
        raise OSError(code, "no route")
    monkeypatch.setattr(socket, "create_connection", fail)
    with pytest.raises(httpclient.HttpError) as info:
        httpclient.get("http://127.0.0.1:1/x", timeout=2)
    assert info.value.kind == "unreachable"


def test_a_refused_connection_stays_connect():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    with pytest.raises(httpclient.HttpError) as info:
        httpclient.get(f"http://127.0.0.1:{port}/x", timeout=2, connect_timeout=1)
    assert info.value.kind == "connect"


# ---------------------------------------------------------------- env

def test_connect_timeout_env_defaults_and_parses():
    assert env.connect_timeout({}) == 5
    assert env.connect_timeout({"SHUNT_CONNECT_TIMEOUT": "0"}) == 0
    assert env.connect_timeout({"SHUNT_CONNECT_TIMEOUT": "1.5"}) == 1.5


@pytest.mark.parametrize("bad", ["abc", "-1", "nan", "inf"])
def test_connect_timeout_env_rejects_bad_values(bad):
    with pytest.raises(env.EnvError, match="SHUNT_CONNECT_TIMEOUT"):
        env.connect_timeout({"SHUNT_CONNECT_TIMEOUT": bad})


# ---------------------------------------------------------------- breaker

def test_unreachable_cooldown_resolution_env_over_config_over_default(tmp_path):
    cfg = tmp_path / "bc.json"
    environ = {"SHUNT_BREAKER_CONFIG_FILE": str(cfg)}
    assert breaker.unreachable_cooldown(environ) == 120
    cfg.write_text(json.dumps({"unreachable_cooldown_seconds": 45}))
    assert breaker.unreachable_cooldown(environ) == 45
    assert breaker.unreachable_cooldown({**environ, "SHUNT_BREAKER_UNREACHABLE_COOLDOWN_SECONDS": "7"}) == 7
    assert breaker.unreachable_cooldown({**environ, "SHUNT_BREAKER_UNREACHABLE_COOLDOWN_SECONDS": "x"}) == 45


def test_unreachable_failures_open_the_breaker_for_the_short_cooldown(tmp_path):
    environ = {"SHUNT_BREAKER_STATE_FILE": str(tmp_path / "s.json"), "SHUNT_BREAKER_CONFIG_FILE": str(tmp_path / "c.json"),
               "SHUNT_NOW_EPOCH": "1000", "SHUNT_BREAKER_THRESHOLD": "2"}
    breaker.record_failure(environ, "m", unreachable=True)
    assert not breaker.is_open(environ, "m")
    breaker.record_failure(environ, "m", unreachable=True)
    assert json.loads(breaker.model_state(environ, "m")) == {"failures": 2, "cooldown_until": 1120}
    assert breaker.is_open(environ, "m")


def test_other_failures_keep_the_long_cooldown(tmp_path):
    environ = {"SHUNT_BREAKER_STATE_FILE": str(tmp_path / "s.json"), "SHUNT_BREAKER_CONFIG_FILE": str(tmp_path / "c.json"),
               "SHUNT_NOW_EPOCH": "1000", "SHUNT_BREAKER_THRESHOLD": "1"}
    breaker.record_failure(environ, "m")
    assert json.loads(breaker.model_state(environ, "m"))["cooldown_until"] == 1300


# ---------------------------------------------------------------- failover

def test_an_unreachable_model_fails_fast_and_the_next_one_answers(fo, dead_connect, capsys):  # noqa: F811
    fo.providers(dead={"transport": "http", "base_url": "http://127.0.0.1:1/v1", "key": {"type": "none"}})
    fo.registry(model("dead/m9"), model("acme/m1"))
    fo.environ.update({"SHUNT_CONNECT_TIMEOUT": "0.2", "SHUNT_TIMEOUT_SECONDS": "30",
                       "SHUNT_NOW_EPOCH": "5000", "SHUNT_BREAKER_THRESHOLD": "1"})
    started = time.monotonic()
    found = fo.run()
    assert time.monotonic() - started < 5
    assert found.model_id == "acme/m1"
    err = capsys.readouterr().err
    assert "shunt: dead/m9 unreachable: no connection within 0.2s (or no route" in err
    assert "shunt: dead/m9 failed: unreachable" in err
    assert fo.breaker()["dead/m9"] == {"failures": 1, "cooldown_until": 5120}
    os.unlink(found.path)


def test_a_bad_connect_timeout_env_is_a_config_problem_with_a_clear_line(fo, capsys):  # noqa: F811
    fo.registry(model("acme/m1"))
    fo.environ["SHUNT_CONNECT_TIMEOUT"] = "soon"
    with pytest.raises(failover.Fatal):
        fo.run()
    err = capsys.readouterr().err
    assert "shunt: SHUNT_CONNECT_TIMEOUT must be a number, got 'soon'" in err
    assert not fo.server.requests


def test_failure_reason_text_for_unreachable():
    assert "unreachable" in failover.failure_reason(reply.UNREACHABLE, "", {})
