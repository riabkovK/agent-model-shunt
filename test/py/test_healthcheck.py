"""The optional provider healthcheck: GET {base_url}/models before the chat request."""

import json
import os
import socket
import stat

import pytest

from shunt import dashboard, env, healthcheck, providers
from shunt import transport_reply as reply
from test_failover import BAD_ROUTE, KEY, ROUTE, fo, model  # noqa: F401 (the failover fixture)

MODELS = "/v1/models"
BAD_MODELS = "/bad/v1/models"


def gets(server):
    return [r for r in server.requests if r.method == "GET"]


def posts(server):
    return [r for r in server.requests if r.method == "POST"]


def write_providers(fo, **flags):
    """providers.json with `healthcheck` set per provider name (acme, bad) as given."""
    base = fo.server.url
    doc = {name: {"transport": "http", "base_url": f"{base}{path}", "key": {"type": "env", "ref": "ACME_KEY"},
                  **({"healthcheck": flags[name]} if name in flags else {})}
           for name, path in (("acme", "/v1"), ("bad", "/bad/v1"))}
    (fo.path / "providers.json").write_text(json.dumps({"version": 1, "providers": doc}))


@pytest.fixture
def hc(fo):  # noqa: F811
    fo.server.script(MODELS, body={"data": []})
    fo.registry(model("acme/m1"))
    write_providers(fo, acme=True)
    fo.environ["SHUNT_NOW_EPOCH"] = "1000"
    return fo


def cache_file():
    return env.healthcheck_cache_file(os.environ)


# ---------------------------------------------------------------- the check

def test_a_healthy_provider_is_asked_with_the_key_and_the_chat_request_follows(hc, capsys):
    found = hc.run()
    assert found.model_id == "acme/m1"
    asked = gets(hc.server)
    assert [r.path for r in asked] == [MODELS]
    assert asked[0].headers["authorization"] == f"Bearer {KEY}"
    assert len(posts(hc.server)) == 1
    assert hc.server.requests.index(asked[0]) < hc.server.requests.index(posts(hc.server)[0])
    os.unlink(found.path)


def test_a_404_on_models_still_counts_as_healthy(hc):
    hc.server.script(MODELS, status=404, body="nope")
    os.unlink(hc.run().path)
    assert len(posts(hc.server)) == 1


def test_a_503_aborts_as_unreachable_and_failover_moves_on(hc, capsys):
    hc.server.script(BAD_MODELS, status=503, body="down")
    hc.registry(model("bad/m2"), model("acme/m1"))
    write_providers(hc, acme=True, bad=True)
    hc.environ["SHUNT_BREAKER_THRESHOLD"] = "1"
    found = hc.run()
    assert found.model_id == "acme/m1"
    err = capsys.readouterr().err
    assert "shunt: bad/m2 healthcheck failed: HTTP 503" in err
    assert not [r for r in posts(hc.server) if r.path == BAD_ROUTE]
    assert hc.breaker()["bad/m2"] == {"failures": 1, "cooldown_until": 1120}
    os.unlink(found.path)


def test_a_failed_connect_aborts_and_the_next_model_answers(hc, capsys):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    write_providers(hc, acme=True)
    doc = json.loads((hc.path / "providers.json").read_text())
    doc["providers"]["bad"].update(base_url=f"http://127.0.0.1:{port}/v1", healthcheck=True)
    (hc.path / "providers.json").write_text(json.dumps(doc))
    hc.registry(model("bad/m2"), model("acme/m1"))
    found = hc.run()
    assert found.model_id == "acme/m1"
    assert "shunt: bad/m2 healthcheck failed: connect error" in capsys.readouterr().err
    os.unlink(found.path)


def test_a_slow_answer_fails_the_check_by_timeout(hc, capsys):
    hc.server.script(MODELS, body={}, delay=3)
    hc.environ["SHUNT_HEALTHCHECK_TIMEOUT"] = "0.3"
    status, _ = failover_status(hc)
    assert status == reply.UNREACHABLE
    assert "shunt: acme/m1 healthcheck failed: no answer in time" in capsys.readouterr().err
    assert not posts(hc.server)


def failover_status(hc):
    from shunt import models, transport_http
    agent = models.slug("acme/m1")
    return transport_http.call_status(lambda: transport_http.http_call(agent, "q", [], hc.environ))


def test_healthcheck_off_sends_no_get(hc):
    write_providers(hc, acme=False)
    os.unlink(hc.run().path)
    assert not gets(hc.server)


def test_a_provider_without_the_field_sends_no_get(hc):
    write_providers(hc)
    os.unlink(hc.run().path)
    assert not gets(hc.server)


def test_timeout_zero_disables_the_check(hc):
    hc.environ["SHUNT_HEALTHCHECK_TIMEOUT"] = "0"
    os.unlink(hc.run().path)
    assert not gets(hc.server)


def test_the_check_runs_once_for_a_chunked_attempt(hc, tmp_path):
    from shunt import models, transport_http
    attempt = transport_http._Attempt(transport_http._setup(models.slug("acme/m1"), hc.environ, None), hc.environ,
                                      transport_http.Deadline(hc.environ))
    attempt.ask(b"one")
    attempt.ask(b"two")
    assert len(gets(hc.server)) == 1
    assert len(posts(hc.server)) == 2


# ---------------------------------------------------------------- the cache

def test_a_healthy_answer_is_cached_and_skips_the_next_get(hc):
    os.unlink(hc.run().path)
    os.unlink(hc.run().path)
    assert len(gets(hc.server)) == 1
    assert len(posts(hc.server)) == 2


def test_the_cache_expires_after_the_ttl_without_sleeping(hc):
    os.unlink(hc.run().path)
    hc.environ["SHUNT_NOW_EPOCH"] = "1059"
    os.unlink(hc.run().path)
    assert len(gets(hc.server)) == 1
    hc.environ["SHUNT_NOW_EPOCH"] = "1060"
    os.unlink(hc.run().path)
    assert len(gets(hc.server)) == 2


def test_ttl_zero_means_no_cache_and_no_file(hc):
    hc.environ["SHUNT_HEALTHCHECK_TTL"] = "0"
    os.unlink(hc.run().path)
    os.unlink(hc.run().path)
    assert len(gets(hc.server)) == 2
    assert not cache_file().exists()


def test_failures_are_not_cached(hc):
    hc.server.script(MODELS, status=500)
    assert failover_status(hc)[0] == reply.UNREACHABLE
    assert not cache_file().exists()
    hc.server.script(MODELS, status=200)
    hc.environ["SHUNT_NOW_EPOCH"] = "1001"
    assert failover_status(hc)[0] == 0
    assert len(gets(hc.server)) == 2


def test_a_changed_base_url_misses_the_cache(hc):
    os.unlink(hc.run().path)
    hc.server.script("/other/models", body={})
    doc = json.loads((hc.path / "providers.json").read_text())
    doc["providers"]["acme"]["base_url"] = hc.server.url + "/other"
    (hc.path / "providers.json").write_text(json.dumps(doc))
    hc.server.script("/other/chat/completions", body=json.loads(json.dumps({
        "choices": [{"message": {"content": "hi"}, "finish_reason": "stop"}]})))
    os.unlink(hc.run().path)
    assert [r.path for r in gets(hc.server)] == [MODELS, "/other/models"]


def test_the_cache_file_is_private_and_holds_no_key(hc, capsys):
    os.unlink(hc.run().path)
    path = cache_file()
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    text = path.read_text()
    assert KEY not in text
    doc = json.loads(text)
    assert doc["entries"] == [{"provider": "acme", "base_url": hc.server.url + "/v1", "at": 1000}]
    assert KEY not in capsys.readouterr().err
    assert not [p for p in path.parent.iterdir() if p.name != "healthcheck.json"]


def test_a_symlinked_cache_is_neither_read_nor_written(hc, tmp_path):
    target = tmp_path / "elsewhere.json"
    target.write_text(json.dumps({"version": 1, "entries": [
        {"provider": "acme", "base_url": hc.server.url + "/v1", "at": 1000}]}))
    path = cache_file()
    path.parent.mkdir(parents=True)
    path.symlink_to(target)
    before = target.read_text()
    os.unlink(hc.run().path)
    assert len(gets(hc.server)) == 1  # the link's content was not trusted
    assert target.read_text() == before
    assert path.is_symlink()


@pytest.mark.parametrize("junk", ["not json", "[]", '{"entries": 5}', '{"entries": [{"provider": 1}, 7]}', "\xff"])
def test_corrupt_cache_content_is_ignored(hc, junk):
    path = cache_file()
    path.parent.mkdir(parents=True)
    path.write_text(junk, encoding="latin-1")
    os.unlink(hc.run().path)
    assert len(gets(hc.server)) == 1
    assert json.loads(path.read_text())["entries"][0]["provider"] == "acme"


def test_a_cache_that_cannot_be_written_is_not_fatal(hc):
    cache_file().parent.parent.mkdir(parents=True, exist_ok=True)
    cache_file().parent.write_text("a file where the cache dir should be")
    os.unlink(hc.run().path)


def test_a_fifo_cache_is_ignored_without_blocking(hc):
    path = cache_file()
    path.parent.mkdir(parents=True)
    os.mkfifo(path)
    assert healthcheck._load(path) == []


# ---------------------------------------------------------------- deadline

def test_the_check_runs_inside_the_total_deadline(hc, monkeypatch):
    seen = []
    monkeypatch.setattr(healthcheck, "probe", lambda url, headers, timeout, connect: seen.append(timeout))
    hc.environ.update({"SHUNT_TIMEOUT_SECONDS": "30", "SHUNT_TOTAL_TIMEOUT_SECONDS": "2"})
    os.unlink(hc.run().path)
    assert seen == [2.0]


# ---------------------------------------------------------------- env and config

@pytest.mark.parametrize("name,fn", [("SHUNT_HEALTHCHECK_TIMEOUT", env.healthcheck_timeout),
                                     ("SHUNT_HEALTHCHECK_TTL", env.healthcheck_ttl)])
def test_env_values_are_validated(name, fn):
    assert fn({name: "0"}) == 0
    assert fn({name: "1.5"}) == 1.5
    for bad in ("abc", "-1", "nan", "inf"):
        with pytest.raises(env.EnvError, match=name):
            fn({name: bad})


def test_env_defaults():
    assert env.healthcheck_timeout({}) == 3
    assert env.healthcheck_ttl({}) == 60


@pytest.mark.parametrize("name", ["SHUNT_HEALTHCHECK_TIMEOUT", "SHUNT_HEALTHCHECK_TTL"])
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


def test_a_slow_check_cut_by_the_total_deadline_is_a_deadline_stop(hc, monkeypatch, capsys):
    monkeypatch.setattr(healthcheck, "probe", lambda *a: healthcheck.NO_ANSWER)
    hc.environ.update({"SHUNT_TIMEOUT_SECONDS": "30", "SHUNT_TOTAL_TIMEOUT_SECONDS": "1"})
    assert failover_status(hc)[0] == reply.DEADLINE
    assert not posts(hc.server)
