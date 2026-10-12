"""The stdlib HTTP client against the scripted local server (no network)."""

import socket
import time

import pytest

from shunt import httpclient
from shunt.httpclient import HttpError

SECRET = "sk-super-secret-value-123"


def _closed_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def test_get_returns_status_headers_and_body(http_server):
    http_server.script("/v1/models", body={"ok": True}, headers={"X-Thing": "1"})
    resp = httpclient.get(http_server.url + "/v1/models", timeout=5)
    assert (resp.status, resp.ok) == (200, True)
    assert resp.body == b'{"ok": true}'
    assert resp.headers["x-thing"] == "1"


def test_request_headers_reach_the_server(http_server):
    http_server.script("/p")
    httpclient.get(http_server.url + "/p", headers={"Authorization": f"Bearer {SECRET}"}, timeout=5)
    sent = http_server.requests[0]
    assert sent.method == "GET"
    assert sent.headers["authorization"] == f"Bearer {SECRET}"
    assert sent.headers["accept"] == "*/*"


def test_non_ascii_header_value_is_sent_as_utf8(http_server):
    http_server.script("/p")
    httpclient.get(http_server.url + "/p", headers={"X-Name": "café"}, timeout=5)
    assert http_server.requests[0].headers["x-name"].encode("latin-1").decode("utf-8") == "café"


def test_post_json_sends_a_compact_json_body(http_server):
    http_server.script("/api/show", body={"a": 1})
    resp = httpclient.post_json(http_server.url + "/api/show", {"model": "m1"}, timeout=5)
    sent = http_server.requests[0]
    assert resp.status == 200
    assert (sent.method, sent.body) == ("POST", b'{"model":"m1"}')
    assert sent.headers["content-type"] == "application/json"


@pytest.mark.parametrize("status", [401, 403, 404, 500])
def test_non_2xx_is_an_answer_not_an_error(http_server, status):
    http_server.script("/x", status=status, body="nope")
    resp = httpclient.get(http_server.url + "/x", timeout=5)
    assert (resp.status, resp.ok, resp.body) == (status, False, b"nope")


def test_redirects_are_not_followed(http_server):
    http_server.script("/a", status=302, headers={"Location": "/b"})
    http_server.script("/b", body="moved")
    resp = httpclient.get(http_server.url + "/a", timeout=5)
    assert resp.status == 302
    assert [r.path for r in http_server.requests] == ["/a"]


def test_connection_refused_maps_to_curl_exit_7():
    with pytest.raises(HttpError) as info:
        httpclient.get(f"http://127.0.0.1:{_closed_port()}/x", timeout=5)
    assert (info.value.kind, info.value.curl_exit) == ("connect", 7)


def test_timeout_maps_to_curl_exit_28_and_is_prompt(http_server):
    http_server.script("/slow", delay=5)
    started = time.monotonic()
    with pytest.raises(HttpError) as info:
        httpclient.get(http_server.url + "/slow", timeout=0.4)
    assert (info.value.kind, info.value.curl_exit) == ("timeout", 28)
    assert time.monotonic() - started < 3


def test_a_slow_body_is_cut_off_by_the_total_timeout(http_server):
    http_server.script("/drip", body=b"x" * 200, drip=0.1)
    started = time.monotonic()
    with pytest.raises(HttpError) as info:
        httpclient.get(http_server.url + "/drip", timeout=0.5)
    assert info.value.kind == "timeout"
    assert time.monotonic() - started < 3


def test_a_dropped_connection_maps_to_curl_exit_52(http_server):
    http_server.script("/drop", drop=True)
    with pytest.raises(HttpError) as info:
        httpclient.get(http_server.url + "/drop", timeout=5)
    assert (info.value.kind, info.value.curl_exit) == ("empty_reply", 52)


def test_unresolvable_host_maps_to_curl_exit_6():
    with pytest.raises(HttpError) as info:
        httpclient.get("http://no-such-host.invalid/x", timeout=10)
    assert (info.value.kind, info.value.curl_exit) == ("dns", 6)


def test_tls_to_a_plain_http_port_maps_to_curl_exit_35(http_server):
    with pytest.raises(HttpError) as info:
        httpclient.get(http_server.url.replace("http://", "https://") + "/x", timeout=5)
    assert (info.value.kind, info.value.curl_exit) == ("tls", 35)


@pytest.mark.parametrize("url", ["file:///etc/passwd", "ftp://127.0.0.1/x", "gopher://127.0.0.1/"])
def test_only_http_and_https_are_spoken(url):
    with pytest.raises(HttpError) as info:
        httpclient.get(url, timeout=5)
    assert (info.value.kind, info.value.curl_exit) == ("scheme", 1)


def test_a_declared_length_over_the_cap_is_refused_before_reading(http_server):
    http_server.script("/big", body=b"x" * 2000)
    with pytest.raises(HttpError) as info:
        httpclient.get(http_server.url + "/big", timeout=5, max_bytes=1000)
    assert (info.value.kind, info.value.curl_exit) == ("too_large", 63)


def test_a_chunked_body_over_the_cap_is_refused_while_reading(http_server):
    http_server.script("/big", body=b"x" * 2000, chunked=True)
    with pytest.raises(HttpError) as info:
        httpclient.get(http_server.url + "/big", timeout=5, max_bytes=1000)
    assert info.value.kind == "too_large"


def test_a_body_of_exactly_the_cap_is_accepted(http_server):
    http_server.script("/ok", body=b"x" * 1000)
    assert len(httpclient.get(http_server.url + "/ok", timeout=5, max_bytes=1000).body) == 1000


def test_the_cap_applies_to_error_answers_too(http_server):
    http_server.script("/e", status=500, body=b"x" * 2000)
    with pytest.raises(HttpError) as info:
        httpclient.get(http_server.url + "/e", timeout=5, max_bytes=1000)
    assert info.value.kind == "too_large"


@pytest.mark.parametrize("raw,expected", [
    ("1000", 1000), ("", 16777216), ("0", 16777216), ("-5", 16777216),
    ("12abc", 16777216), ("0100", 16777216), ("1" + "0" * 15, 16777216),
])
def test_max_response_bytes_reads_the_env_value(raw, expected):
    env = {"SHUNT_HTTP_MAX_RESPONSE_BYTES": raw} if raw else {}
    assert httpclient.max_response_bytes(env) == expected


def test_proxy_environment_is_honoured_like_curl(http_server, monkeypatch):
    http_server.script("/x", body="direct")
    monkeypatch.setenv("http_proxy", f"http://127.0.0.1:{_closed_port()}")
    monkeypatch.setenv("no_proxy", "")
    monkeypatch.setenv("NO_PROXY", "")
    with pytest.raises(HttpError) as info:
        httpclient.get(http_server.url + "/x", timeout=5)
    assert info.value.kind == "connect"
    assert http_server.requests == []


class TestSecretsStayOutOfErrors:
    def test_an_illegal_header_value_does_not_leak_into_the_error(self, http_server):
        with pytest.raises(HttpError) as info:
            httpclient.get(http_server.url + "/x", headers={"Authorization": f"Bearer {SECRET}\nX: y"}, timeout=5)
        err = info.value
        assert err.kind == "invalid"
        assert SECRET not in str(err) + repr(err) + repr(err.args)
        assert err.__context__ is None and err.__cause__ is None

    def test_a_lone_surrogate_in_a_header_does_not_leak(self, http_server):
        with pytest.raises(HttpError) as info:
            httpclient.get(http_server.url + "/x", headers={"Authorization": f"Bearer {SECRET}\ud800"}, timeout=5)
        assert SECRET not in str(info.value) + repr(info.value)
        assert info.value.__context__ is None

    def test_a_connection_error_does_not_leak_the_header(self):
        with pytest.raises(HttpError) as info:
            httpclient.get(f"http://127.0.0.1:{_closed_port()}/x", headers={"Authorization": f"Bearer {SECRET}"},
                           timeout=5)
        assert SECRET not in str(info.value) + repr(info.value)
        assert info.value.__context__ is None

    def test_the_response_repr_has_no_request_headers(self, http_server):
        http_server.script("/x", status=401, body="denied")
        resp = httpclient.get(http_server.url + "/x", headers={"Authorization": f"Bearer {SECRET}"}, timeout=5)
        assert SECRET not in repr(resp)
