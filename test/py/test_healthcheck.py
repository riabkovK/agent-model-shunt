"""The optional provider healthcheck: the status cache, the gate on the request path and the background probe."""

import json
import os
import re
import socket
import stat
import subprocess
import sys
import time

import pytest

from shunt import breaker, dashboard, env, failover, healthcheck, healthcheck_bg, hooks, providers
from shunt import transport_reply as reply
from test_failover import BAD_ROUTE, KEY, ROUTE, fo, model  # noqa: F401 (the failover fixture)

MODELS = "/v1/models"
BAD_MODELS = "/bad/v1/models"


def gets(server):
    return [r for r in server.requests if r.method == "GET"]


def is_probe(request):
    return json.loads(request.body).get("max_tokens") == 1 and "ping" in request.body.decode()


def posts(server):
    """The real chat requests, without the healthcheck's one token probes."""
    return [r for r in server.requests if r.method == "POST" and not is_probe(r)]


def probes(server):
    return [r for r in server.requests if r.method == "POST" and is_probe(r)]


def listing(*ids):
    return {"data": [{"id": i, "object": "model"} for i in ids]}


def write_providers(fo, **flags):
    """providers.json with `healthcheck` set per provider name (acme, bad) as given."""
    base = fo.server.url
    doc = {name: {"transport": "http", "base_url": f"{base}{path}", "key": {"type": "env", "ref": "ACME_KEY"},
                  **({"healthcheck": flags[name]} if name in flags else {})}
           for name, path in (("acme", "/v1"), ("bad", "/bad/v1"))}
    (fo.path / "providers.json").write_text(json.dumps({"version": 1, "providers": doc}))


@pytest.fixture
def hc(fo, monkeypatch):  # noqa: F811
    """Healthcheck on for acme. No child is ever started: `hc.launched` records what would have run."""
    fo.server.script(MODELS, body=listing("m1"))
    fo.registry(model("acme/m1"))
    write_providers(fo, acme=True)
    fo.environ["SHUNT_NOW_EPOCH"] = "1000"
    fo.launched = []
    fo.launches = []

    def record(environ, pairs):
        fo.launched.extend(pairs)
        fo.launches.append(list(pairs))
    monkeypatch.setattr(healthcheck_bg, "_launch", record)
    return fo


def cache_file():
    return env.healthcheck_cache_file(os.environ)


# ---------------------------------------------------------------- helpers

def failover_status(hc):
    from shunt import models, transport_http
    agent = models.slug("acme/m1")
    return transport_http.call_status(lambda: transport_http.http_call(agent, "q", [], hc.environ))


def probe_now(hc, provider="acme", model="m1"):
    """The background probe, run in this process."""
    healthcheck_bg.refresh(provider, model, hc.environ)


def entries():
    path = cache_file()
    return json.loads(path.read_text())["entries"] if path.exists() else []


def status_of(model="m1"):
    return [e["status"] for e in entries() if e["model"] == model]


def seed(hc, status, at=1000, model="m1", provider="acme", path="/v1"):
    cache_file().parent.mkdir(parents=True, exist_ok=True)
    entry = {"provider": provider, "base_url": hc.server.url + path, "model": model, "at": at}
    if status:
        entry["status"] = status
    cache_file().write_text(json.dumps({"version": 1, "entries": [entry]}))


def closed_port_url():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return f"http://127.0.0.1:{sock.getsockname()[1]}/v1"


# ---------------------------------------------------------------- the gate on the request path

def test_an_unknown_status_goes_on_with_the_real_call_and_starts_one_probe(hc):
    found = hc.run()
    assert found.model_id == "acme/m1"
    assert len(posts(hc.server)) == 1
    assert not gets(hc.server)  # the probe never ran on the request path
    assert hc.launched == [("acme", "m1")]
    os.unlink(found.path)


def test_the_hot_path_does_not_wait_for_a_slow_models_list(hc):
    hc.server.script(MODELS, body={}, delay=3)
    started = time.monotonic()
    os.unlink(hc.run().path)
    assert time.monotonic() - started < 2
    assert not gets(hc.server)


def test_a_fresh_healthy_status_starts_no_probe(hc):
    seed(hc, "healthy", at=1000)
    hc.environ["SHUNT_NOW_EPOCH"] = "1599"
    os.unlink(hc.run().path)
    assert hc.launched == []


def test_a_healthy_status_older_than_the_ttl_starts_a_probe_and_the_call_goes_on(hc):
    seed(hc, "healthy", at=1000)
    hc.environ["SHUNT_NOW_EPOCH"] = "1600"
    os.unlink(hc.run().path)
    assert hc.launched == [("acme", "m1")]
    assert len(posts(hc.server)) == 1


def test_an_entry_without_a_status_counts_as_healthy(hc):
    seed(hc, None, at=1000)
    os.unlink(hc.run().path)
    assert hc.launched == []


def test_a_fresh_unhealthy_status_fails_over_at_once(hc, capsys):
    hc.registry(model("bad/m2"), model("acme/m1"))
    write_providers(hc, acme=True, bad=True)
    seed(hc, "unhealthy", at=1000, model="m2", provider="bad", path="/bad/v1")
    hc.environ["SHUNT_BREAKER_THRESHOLD"] = "1"
    started = time.monotonic()
    found = hc.run()
    assert time.monotonic() - started < 2
    assert found.model_id == "acme/m1"
    err = capsys.readouterr().err
    assert re.search(r"shunt: bad/m2 skipped: unhealthy at the last healthcheck, next check in \d+ s\n", err)
    assert "shunt: bad/m2 failed: skipped by the healthcheck (unhealthy at the last check)\n" in err
    assert "unreachable" not in err
    assert not [r for r in hc.server.requests if r.path.startswith("/bad")]
    assert ("bad", "m2") not in hc.launched
    assert "bad/m2" not in hc.breaker()  # the healthcheck status replaces the breaker pause
    os.unlink(found.path)


def test_an_unhealthy_model_is_used_again_right_after_the_retry_time(hc):
    seed(hc, "unhealthy", at=1000)
    hc.environ["SHUNT_BREAKER_THRESHOLD"] = "1"
    hc.environ["SHUNT_NOW_EPOCH"] = "1029"
    with pytest.raises(failover.Fatal):
        hc.run()
    assert not posts(hc.server)
    assert "acme/m1" not in hc.breaker()
    hc.environ["SHUNT_NOW_EPOCH"] = "1030"
    found = hc.run()  # the real call is the recheck, and a probe starts too
    assert found.model_id == "acme/m1"
    assert hc.launched == [("acme", "m1")]
    assert status_of() == ["healthy"]
    os.unlink(found.path)


def test_retry_zero_never_fails_over_on_the_status(hc):
    seed(hc, "unhealthy", at=1000)
    hc.environ["SHUNT_HEALTHCHECK_RETRY"] = "0"
    os.unlink(hc.run().path)
    assert len(posts(hc.server)) == 1


def test_a_second_call_while_a_probe_runs_starts_no_second_probe(hc):
    os.unlink(hc.run().path)
    os.unlink(hc.run().path)
    assert hc.launched == [("acme", "m1")]
    assert len(list(cache_file().parent.glob(".healthcheck-*.lock"))) == 1


def test_a_stale_lock_is_replaced(hc):
    healthcheck_bg.spawn(hc.environ, "acme", hc.server.url + "/v1", "m1")
    lock = next(cache_file().parent.glob(".healthcheck-*.lock"))
    old = time.time() - 3600
    os.utime(lock, (old, old))
    healthcheck_bg.spawn(hc.environ, "acme", hc.server.url + "/v1", "m1")
    assert len(hc.launched) == 2


def test_a_spawn_error_is_swallowed_and_frees_the_lock(hc, monkeypatch):
    def broken(environ, pairs):
        raise OSError("no fork")
    monkeypatch.setattr(healthcheck_bg, "_launch", broken)
    os.unlink(hc.run().path)
    assert not list(cache_file().parent.glob(".healthcheck-*.lock"))


def test_the_child_gets_no_key_in_argv(hc, monkeypatch):
    seen = {}

    class FakePopen:
        def __init__(self, argv, **kwargs):
            seen.update(argv=argv, kwargs=kwargs)

    monkeypatch.undo()  # drop the recorder: the real _launch with a fake Popen
    monkeypatch.setattr(subprocess, "Popen", FakePopen)
    os.unlink(hc.run().path)
    argv = seen["argv"]
    assert argv[:3] == [sys.executable, "-I", "-B"] and argv[4:] == ["healthcheck-refresh", "--", "acme", "m1"]
    assert not any(KEY in part for part in argv)
    kwargs = seen["kwargs"]
    assert kwargs["start_new_session"] is True and kwargs["close_fds"] is True
    assert kwargs["stdin"] == kwargs["stdout"] == kwargs["stderr"] == subprocess.DEVNULL


def test_the_gate_runs_once_for_a_chunked_attempt(hc, monkeypatch):
    from shunt import models, transport_http
    calls = []
    monkeypatch.setattr(healthcheck_bg, "gate", lambda *a: calls.append(a) or None)
    attempt = transport_http._Attempt(transport_http._setup(models.slug("acme/m1"), hc.environ, None), hc.environ,
                                      transport_http.Deadline(hc.environ))
    attempt.ask(b"one")
    attempt.ask(b"two")
    assert len(calls) == 1
    assert len(posts(hc.server)) == 2


def test_healthcheck_off_touches_no_cache_and_starts_no_probe(hc):
    write_providers(hc, acme=False)
    os.unlink(hc.run().path)
    assert hc.launched == [] and not cache_file().exists()


def test_a_provider_without_the_field_starts_no_probe(hc):
    write_providers(hc)
    os.unlink(hc.run().path)
    assert hc.launched == [] and not cache_file().exists()


def test_timeout_zero_disables_the_check(hc):
    hc.environ["SHUNT_HEALTHCHECK_TIMEOUT"] = "0"
    seed(hc, "unhealthy", at=1000)
    os.unlink(hc.run().path)
    assert hc.launched == []


def test_inline_mode_runs_the_probe_in_process(hc):
    hc.environ["SHUNT_HEALTHCHECK_INLINE"] = "1"
    os.unlink(hc.run().path)
    assert hc.launched == []
    assert len(gets(hc.server)) == 1 and len(probes(hc.server)) == 1
    assert status_of() == ["healthy"]


# ---------------------------------------------------------------- the real call updates the status

def test_a_real_success_marks_healthy_and_refreshes_the_time(hc):
    seed(hc, "healthy", at=900)
    os.unlink(hc.run().path)
    assert entries()[0]["status"] == "healthy" and entries()[0]["at"] == 1000


def test_a_real_success_marks_an_unhealthy_model_healthy(hc):
    seed(hc, "unhealthy", at=900)  # older than the retry time, so the call goes on
    os.unlink(hc.run().path)
    assert status_of() == ["healthy"]


def point_acme_at_closed_port(hc):
    doc = json.loads((hc.path / "providers.json").read_text())
    url = closed_port_url()
    doc["providers"]["acme"]["base_url"] = url
    (hc.path / "providers.json").write_text(json.dumps(doc))
    return url


def test_a_real_call_connect_failure_leaves_the_status_and_starts_a_probe(hc):
    point_acme_at_closed_port(hc)
    hc.environ["SHUNT_BREAKER_THRESHOLD"] = "1"
    assert failover_status(hc)[0] == reply.UNREACHABLE
    assert not cache_file().exists()  # the probe, not the real call, sets the status
    assert hc.launched == [("acme", "m1")]  # one probe: the gate's, which holds the lock


def test_a_connect_failure_starts_a_probe_even_when_the_status_is_fresh(hc):
    url = point_acme_at_closed_port(hc)
    cache_file().parent.mkdir(parents=True, exist_ok=True)
    cache_file().write_text(json.dumps({"version": 1, "entries": [
        {"provider": "acme", "base_url": url, "model": "m1", "at": 1000, "status": "healthy"}]}))
    assert failover_status(hc)[0] == reply.UNREACHABLE
    assert hc.launched == [("acme", "m1")]
    assert status_of() == ["healthy"]


def test_a_connect_failure_with_the_probe_inline_ends_unhealthy_without_a_breaker_pause(hc):
    url = point_acme_at_closed_port(hc)
    hc.environ["SHUNT_HEALTHCHECK_INLINE"] = "1"
    hc.environ["SHUNT_BREAKER_THRESHOLD"] = "1"
    assert failover_status(hc)[0] == reply.UNREACHABLE
    assert entries()[0]["status"] == "unhealthy" and entries()[0]["base_url"] == url
    with pytest.raises(failover.Fatal):
        hc.run()
    assert "acme/m1" not in hc.breaker()


def test_a_provider_without_healthcheck_keeps_the_breaker_pause(hc):
    write_providers(hc, acme=False)
    doc = json.loads((hc.path / "providers.json").read_text())
    doc["providers"]["acme"]["base_url"] = closed_port_url()
    (hc.path / "providers.json").write_text(json.dumps(doc))
    hc.environ["SHUNT_BREAKER_THRESHOLD"] = "1"
    with pytest.raises(failover.Fatal):
        hc.run()
    assert hc.breaker()["acme/m1"]["cooldown_until"] == 1300
    assert not cache_file().exists()


def test_other_errors_do_not_change_the_status(hc):
    seed(hc, "healthy", at=900)
    hc.server.script(ROUTE, status=401, body={"error": "no"})
    assert failover_status(hc)[0] == reply.AUTH
    hc.server.script(ROUTE, status=400, body={"error": "bad"})
    assert failover_status(hc)[0] == reply.ERROR
    hc.server.script(ROUTE, body={}, delay=3)
    hc.environ["SHUNT_TIMEOUT_SECONDS"] = "0.3"
    assert failover_status(hc)[0] == reply.TIMEOUT
    assert entries()[0]["status"] == "healthy" and entries()[0]["at"] == 900


@pytest.mark.parametrize("code", [404, 500, 503])
def test_a_broken_model_route_marks_unhealthy_without_a_breaker_pause(hc, code):
    hc.server.script(ROUTE, status=code, body={"error": "x"})
    hc.environ["SHUNT_BREAKER_THRESHOLD"] = "1"
    assert failover_status(hc)[0] == reply.UNREACHABLE
    assert status_of() == ["unhealthy"]
    with pytest.raises(failover.Fatal):
        hc.run()
    assert "acme/m1" not in hc.breaker()


def test_a_404_without_a_healthcheck_stays_a_plain_error(hc):
    write_providers(hc, acme=False)
    hc.server.script(ROUTE, status=404, body={"error": "x"})
    assert failover_status(hc)[0] == reply.ERROR


def test_a_real_success_clears_an_open_breaker(hc):
    breaker.write_state(hc.environ, "acme/m1#code-write", 5, 99999)
    assert failover_status(hc)[0] == 0
    assert not breaker.is_open(hc.environ, "acme/m1#code-write")


def test_a_probe_that_returns_early_still_frees_the_lock(hc):
    write_providers(hc, acme=False)
    healthcheck_bg.spawn(hc.environ, "acme", hc.server.url + "/v1", "m1")
    assert hc.launched == [("acme", "m1")]
    probe_now(hc)  # the child of that spawn: the flag is off now
    assert not list(cache_file().parent.glob(".healthcheck-*.lock"))


def test_a_lock_from_the_future_is_stale(hc):
    healthcheck_bg.spawn(hc.environ, "acme", hc.server.url + "/v1", "m1")
    lock = next(cache_file().parent.glob(".healthcheck-*.lock"))
    future = time.time() + 3600
    os.utime(lock, (future, future))
    healthcheck_bg.spawn(hc.environ, "acme", hc.server.url + "/v1", "m1")
    assert len(hc.launches) == 2


def test_the_child_stops_at_its_cap_even_when_the_probe_hangs(hc):
    hc.server.script(MODELS, body={}, delay=30)
    hc.environ.update({"SHUNT_HEALTHCHECK_TIMEOUT": "60", "SHUNT_HEALTHCHECK_MODEL_TIMEOUT": "0",
                       "SHUNT_CONNECT_TIMEOUT": "0"})
    monkey_cap = subprocess.run(
        [sys.executable, "-I", "-B", "-c",
         "import sys; sys.path.insert(0, sys.argv[1]); from shunt import healthcheck_bg as h; "
         "h.CAP_GRACE_SECONDS = -59.0; import os; "
         "sys.argv = ['x', 'healthcheck-refresh', '--', 'acme', 'm1']; "
         "from shunt.cli import main; sys.exit(main(sys.argv[1:]))", str(healthcheck_bg.MAIN_SCRIPT.parent)],
        env=hc.environ, capture_output=True, timeout=20, check=False)
    assert monkey_cap.returncode == 0
    assert not list(cache_file().parent.glob(".healthcheck-*.lock"))


# ---------------------------------------------------------------- the background probe

def test_a_good_probe_marks_healthy(hc):
    probe_now(hc)
    assert status_of() == ["healthy"]
    assert [r.path for r in gets(hc.server)] == [MODELS]
    assert gets(hc.server)[0].headers["authorization"] == f"Bearer {KEY}"
    assert len(probes(hc.server)) == 1 and not posts(hc.server)


def flaky_get(monkeypatch, failures, kind="unreachable"):
    """httpclient.get fails `failures` times as a connect failure, then works. Returns the call counter."""
    real, calls = healthcheck.httpclient.get, []

    def get(*args, **kwargs):
        calls.append(1)
        if len(calls) <= failures:
            raise healthcheck.httpclient.HttpError(kind)
        return real(*args, **kwargs)
    monkeypatch.setattr(healthcheck.httpclient, "get", get)
    return calls


def test_a_probe_connects_on_the_third_attempt_and_is_healthy(hc, monkeypatch):
    calls = flaky_get(monkeypatch, 2)
    probe_now(hc)
    assert len(calls) == 3 and status_of() == ["healthy"]


def test_a_probe_with_three_connect_failures_is_unhealthy(hc, monkeypatch):
    calls = flaky_get(monkeypatch, 3)
    probe_now(hc)
    assert len(calls) == healthcheck.PROBE_CONNECT_RETRIES + 1 == 3
    assert status_of() == ["unhealthy"]


def test_a_probe_retries_a_refused_connection(hc, monkeypatch):
    calls = flaky_get(monkeypatch, 2, kind="connect")
    probe_now(hc)
    assert len(calls) == 3 and status_of() == ["healthy"]


def test_a_probe_does_not_retry_a_timeout(hc, monkeypatch):
    calls = flaky_get(monkeypatch, 1, kind="timeout")
    probe_now(hc)
    assert len(calls) == 1 and status_of() == ["unhealthy"]


def test_a_probe_does_not_retry_a_401(hc):
    hc.server.script(MODELS, status=401, body={"error": "no"})
    probe_now(hc)
    assert len(gets(hc.server)) == 1


def test_the_completion_step_retries_a_connect_failure_too(hc, monkeypatch):
    real, calls = healthcheck.httpclient.post_json, []

    def post(*args, **kwargs):
        calls.append(1)
        if len(calls) <= 2:
            raise healthcheck.httpclient.HttpError("unreachable")
        return real(*args, **kwargs)
    monkeypatch.setattr(healthcheck.httpclient, "post_json", post)
    probe_now(hc)
    assert len(calls) == 3 and status_of() == ["healthy"]


def test_the_time_cap_fits_three_connects_in_each_step(hc):
    environ = {"SHUNT_HEALTHCHECK_TIMEOUT": "4", "SHUNT_HEALTHCHECK_MODEL_TIMEOUT": "10",
               "SHUNT_CONNECT_TIMEOUT": "5"}
    assert healthcheck_bg.time_cap(environ) == 4 + 10 + 2 * (1 + healthcheck.PROBE_CONNECT_RETRIES) * 5 + healthcheck_bg.CAP_GRACE_SECONDS


def test_a_503_marks_unhealthy(hc):
    hc.server.script(MODELS, status=503, body="down")
    probe_now(hc)
    assert status_of() == ["unhealthy"]
    assert not probes(hc.server)


def test_a_failed_connect_marks_unhealthy(hc):
    doc = json.loads((hc.path / "providers.json").read_text())
    doc["providers"]["acme"]["base_url"] = closed_port_url()
    (hc.path / "providers.json").write_text(json.dumps(doc))
    probe_now(hc)
    assert status_of() == ["unhealthy"]


def test_a_slow_models_list_marks_unhealthy_by_timeout(hc):
    hc.server.script(MODELS, body={}, delay=3)
    hc.environ["SHUNT_HEALTHCHECK_TIMEOUT"] = "0.3"
    probe_now(hc)
    assert status_of() == ["unhealthy"]


def test_a_404_on_models_then_a_working_completion_is_healthy(hc):
    hc.server.script(MODELS, status=404, body=listing("other"))
    probe_now(hc)
    assert status_of() == ["healthy"] and len(probes(hc.server)) == 1


def test_a_model_missing_from_the_list_is_unhealthy_and_no_completion_follows(hc):
    hc.server.script(MODELS, body=listing("other"))
    probe_now(hc)
    assert status_of() == ["unhealthy"]
    assert not probes(hc.server)


@pytest.mark.parametrize("body", ["not json", "[]", '{"data": 5}', '{"data": [1, 2]}', "{}"])
def test_an_unreadable_list_does_not_fail_the_step(hc, body):
    hc.server.script(MODELS, body=body)
    probe_now(hc)
    assert len(probes(hc.server)) == 1 and status_of() == ["healthy"]


def test_the_probe_body_asks_for_one_token_without_streaming_and_carries_the_key(hc):
    probe_now(hc)
    sent = probes(hc.server)[0]
    assert json.loads(sent.body) == {"model": "m1", "messages": [{"role": "user", "content": "ping"}],
                                     "max_tokens": 1, "stream": False}
    assert sent.path == ROUTE
    assert sent.headers["authorization"] == f"Bearer {KEY}"


@pytest.mark.parametrize("status", [200, 201, 400, 422, 401, 403, 429])
def test_these_completion_statuses_are_healthy(hc, status):
    hc.server.script(ROUTE, status=status, body={"choices": [{"message": {"content": "hi"}, "finish_reason": "stop"}]}
                     if status < 300 else {"error": "x"})
    assert healthcheck.probe_model(hc.server.url + ROUTE, "m1", {}, 5, 5) is None


@pytest.mark.parametrize("status", [404, 500, 502, 503])
def test_these_completion_statuses_are_unhealthy(hc, status):
    hc.server.script(ROUTE, status=status, body={"error": "SECRET-BODY"})
    assert healthcheck.probe_model(hc.server.url + ROUTE, "m1", {"Authorization": f"Bearer {KEY}"}, 5, 5) \
        == f"model HTTP {status}"


def test_a_slow_completion_marks_unhealthy_by_the_model_timeout(hc):
    hc.server.script(ROUTE, body={}, delay=3)
    hc.environ["SHUNT_HEALTHCHECK_MODEL_TIMEOUT"] = "0.3"
    probe_now(hc)
    assert status_of() == ["unhealthy"]


def test_model_timeout_zero_skips_the_completion_step(hc):
    hc.environ["SHUNT_HEALTHCHECK_MODEL_TIMEOUT"] = "0"
    probe_now(hc)
    assert not probes(hc.server) and status_of() == ["healthy"]


def test_a_probe_for_a_provider_without_healthcheck_does_nothing(hc):
    write_providers(hc, acme=False)
    probe_now(hc)
    assert not hc.server.requests and not cache_file().exists()


def test_an_unknown_provider_or_a_missing_key_leaves_the_status_alone(hc):
    probe_now(hc, provider="nobody")
    del hc.environ["ACME_KEY"]
    probe_now(hc)
    assert not cache_file().exists()


def test_a_good_probe_clears_an_open_breaker(hc):
    breaker.write_state(hc.environ, "acme/m1", 5, 99999)
    breaker.write_state(hc.environ, "acme/m1#code-write", 5, 99999)
    assert breaker.is_open(hc.environ, "acme/m1")
    probe_now(hc)
    assert not breaker.is_open(hc.environ, "acme/m1")
    assert not breaker.is_open(hc.environ, "acme/m1#code-write")


def test_a_bad_probe_leaves_the_breaker_alone(hc):
    breaker.write_state(hc.environ, "acme/m1", 5, 99999)
    hc.server.script(MODELS, status=503, body="down")
    probe_now(hc)
    assert breaker.is_open(hc.environ, "acme/m1")


def test_the_refresh_command_exits_zero_and_frees_its_lock(hc):
    healthcheck_bg.spawn(hc.environ, "acme", hc.server.url + "/v1", "m1")  # takes the lock, the child frees it
    main = hooks_main_path()
    done = subprocess.run([sys.executable, "-I", "-B", main, "healthcheck-refresh", "--", "acme", "m1"],
                          env=hc.environ, capture_output=True, timeout=60, check=False)
    assert done.returncode == 0 and done.stdout == b"" and done.stderr == b""
    assert status_of() == ["healthy"]
    assert not list(cache_file().parent.glob(".healthcheck-*.lock"))


def hooks_main_path():
    return str(healthcheck_bg.MAIN_SCRIPT)


def test_the_refresh_command_exits_zero_for_an_unknown_provider(hc):
    done = subprocess.run([sys.executable, "-I", "-B", hooks_main_path(), "healthcheck-refresh", "--", "nobody", "x"],
                          env=hc.environ, capture_output=True, timeout=60, check=False)
    assert done.returncode == 0


# ---------------------------------------------------------------- session warm-up

def warm_hook(hc, monkeypatch):
    for name, value in hc.environ.items():
        monkeypatch.setenv(name, value)
    started = time.monotonic()
    out = hooks.session_start(os.environ)
    return out, time.monotonic() - started


def test_warm_up_probes_only_enabled_models_of_healthcheck_providers(hc, monkeypatch):
    write_providers(hc, acme=True, bad=False)
    hc.registry(model("acme/m1"), model("acme/m2"), model("bad/m3"), model("acme/m4", enabled=False))
    out, _ = warm_hook(hc, monkeypatch)
    assert sorted(hc.launched) == [("acme", "m1"), ("acme", "m2")]
    assert len(hc.launches) == 1  # one child for all of them
    assert "Shunt delegation" in out


def test_warm_up_skips_models_with_a_known_status(hc, monkeypatch):
    seed(hc, "healthy", at=1000)
    warm_hook(hc, monkeypatch)
    assert hc.launched == []


def test_the_hook_output_is_the_same_with_and_without_warm_up(hc, monkeypatch):
    with_warm, _ = warm_hook(hc, monkeypatch)
    monkeypatch.setattr(healthcheck_bg, "warm_up", lambda environ: None)
    without, _ = warm_hook(hc, monkeypatch)
    assert with_warm == without and with_warm


def test_the_hook_still_exits_zero_quickly_when_the_spawn_breaks(hc, monkeypatch, capsys):
    def broken(environ, pairs):
        raise OSError("no fork")
    monkeypatch.setattr(healthcheck_bg, "_launch", broken)
    for name, value in hc.environ.items():
        monkeypatch.setenv(name, value)
    started = time.monotonic()
    assert hooks.main(["session-start"]) == 0
    assert time.monotonic() - started < 2
    assert "Shunt delegation" in capsys.readouterr().out


def test_no_warm_up_when_the_timeout_is_zero(hc, monkeypatch):
    hc.environ["SHUNT_HEALTHCHECK_TIMEOUT"] = "0"
    warm_hook(hc, monkeypatch)
    assert hc.launched == []


# ---------------------------------------------------------------- the cache

def test_the_cache_key_includes_the_model_and_the_base_url(hc):
    seed(hc, "healthy", at=1000)
    cache = cache_file()
    assert healthcheck.lookup(cache, "acme", hc.server.url + "/v1", "m1", 1005) == ("healthy", 5)
    assert healthcheck.lookup(cache, "acme", hc.server.url + "/v1", "m2", 1005) is None
    assert healthcheck.lookup(cache, "acme", hc.server.url + "/other", "m1", 1005) is None


def test_a_clock_that_went_back_is_stale(hc):
    seed(hc, "healthy", at=2000)
    assert healthcheck.lookup(cache_file(), "acme", hc.server.url + "/v1", "m1", 1000) == ("healthy", -1)
    assert healthcheck.verdict(("healthy", -1), 600, 30) == (False, True)
    assert healthcheck.verdict(("unhealthy", -1), 600, 30) == (False, True)


def test_the_cache_file_is_private_and_holds_no_key(hc):
    os.unlink(hc.run().path)
    path = cache_file()
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert KEY not in path.read_text()
    assert entries() == [{"provider": "acme", "base_url": hc.server.url + "/v1", "model": "m1",
                          "status": "healthy", "at": 1000}]
    assert not [p for p in path.parent.iterdir() if p.name not in ("healthcheck.json",) and not p.name.endswith(".lock")]


def test_a_symlinked_cache_is_neither_read_nor_written(hc, tmp_path):
    target = tmp_path / "elsewhere.json"
    target.write_text(json.dumps({"version": 1, "entries": [
        {"provider": "acme", "base_url": hc.server.url + "/v1", "model": "m1", "status": "unhealthy", "at": 1000}]}))
    path = cache_file()
    path.parent.mkdir(parents=True)
    path.symlink_to(target)
    before = target.read_text()
    os.unlink(hc.run().path)  # the link's "unhealthy" was not trusted
    assert target.read_text() == before
    assert path.is_symlink()


@pytest.mark.parametrize("junk", ["not json", "[]", '{"entries": 5}', '{"entries": [{"provider": 1}, 7]}', "\xff"])
def test_corrupt_cache_content_is_ignored(hc, junk):
    path = cache_file()
    path.parent.mkdir(parents=True)
    path.write_text(junk, encoding="latin-1")
    os.unlink(hc.run().path)
    assert hc.launched == [("acme", "m1")]
    assert entries()[0]["provider"] == "acme"


def test_a_cache_that_cannot_be_written_is_not_fatal(hc):
    cache_file().parent.parent.mkdir(parents=True, exist_ok=True)
    cache_file().parent.write_text("a file where the cache dir should be")
    os.unlink(hc.run().path)


def test_a_fifo_cache_is_ignored_without_blocking(hc):
    path = cache_file()
    path.parent.mkdir(parents=True)
    os.mkfifo(path)
    assert healthcheck._load(path) == []


# ---------------------------------------------------------------- env and config

@pytest.mark.parametrize("name,fn", [("SHUNT_HEALTHCHECK_TIMEOUT", env.healthcheck_timeout),
                                     ("SHUNT_HEALTHCHECK_TTL", env.healthcheck_ttl),
                                     ("SHUNT_HEALTHCHECK_RETRY", env.healthcheck_retry),
                                     ("SHUNT_HEALTHCHECK_MODEL_TIMEOUT", env.healthcheck_model_timeout)])
def test_env_values_are_validated(name, fn):
    assert fn({name: "0"}) == 0
    assert fn({name: "1.5"}) == 1.5
    for bad in ("abc", "-1", "nan", "inf"):
        with pytest.raises(env.EnvError, match=name):
            fn({name: bad})


def test_env_defaults():
    assert env.healthcheck_timeout({}) == 3
    assert env.healthcheck_ttl({}) == 600
    assert env.healthcheck_retry({}) == 30
    assert env.healthcheck_model_timeout({}) == 30
    assert not env.healthcheck_inline({}) and env.healthcheck_inline({"SHUNT_HEALTHCHECK_INLINE": "1"})


@pytest.mark.parametrize("name", ["SHUNT_HEALTHCHECK_TIMEOUT", "SHUNT_HEALTHCHECK_TTL", "SHUNT_HEALTHCHECK_RETRY"])
def test_a_bad_env_value_is_a_config_problem_before_the_chat_request(hc, capsys, name):
    hc.environ[name] = "soon"
    assert failover_status(hc)[0] == reply.CONFIG
    assert f"shunt: {name} must be a number, got 'soon'" in capsys.readouterr().err
    assert not posts(hc.server)


def test_a_non_boolean_healthcheck_field_is_rejected(tmp_path):
    path = tmp_path / "p.json"
    path.write_text(json.dumps({"providers": {"a": {"transport": "http", "base_url": "http://x/v1",
                                                    "healthcheck": "yes"}}}))
    with pytest.raises(providers.ProviderError, match='provider "a": healthcheck is not a boolean'):
        providers.validate(str(path))


def test_the_field_reads_back_and_the_dashboard_shows_it(tmp_path):
    path = tmp_path / "p.json"
    path.write_text(json.dumps({"providers": {
        "a": {"transport": "http", "base_url": "http://x/v1", "healthcheck": True},
        "b": {"transport": "http", "base_url": "http://y/v1"}}}))
    assert providers.field(str(path), "a", "healthcheck") == "true"
    assert providers.field(str(path), "b", "healthcheck") == "false"
    assert dashboard._healthcheck_state(str(path), "a") == "on"
    assert dashboard._healthcheck_state(str(path), "b") == "off"
