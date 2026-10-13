"""The total deadline of one model attempt (port of transport-http-deadline.sh)."""

import json
import time

import pytest

from conftest import CHUNK_AGENT, CHUNK_KEY, CHUNK_ROUTE, CHUNK_REPLY
from shunt import deadline, httpclient, transport_http
from shunt import transport_reply as reply


class FakeClock:
    """Seconds, moved by hand or by `advance` after each request."""

    def __init__(self, monkeypatch):
        self.now = 0
        self.advance = 0
        monkeypatch.setattr(deadline, "TICKS_PER_SECOND", 1)
        monkeypatch.setattr(deadline, "now_ticks", lambda: self.now)
        real = httpclient.post_json
        self.limits = []

        def post_json(url, payload, **kwargs):
            self.limits.append(kwargs.get("timeout"))
            try:
                return real(url, payload, **kwargs)
            finally:
                self.now += self.advance

        monkeypatch.setattr(httpclient, "post_json", post_json)


@pytest.fixture
def clock(monkeypatch):
    return FakeClock(monkeypatch)


def status_of(world, capsys, *files, question="q", **env):
    try:
        transport_http.http_call(CHUNK_AGENT, question, list(files), {**world.environ, **env})
    except transport_http._Stop as stop:
        return stop.status, capsys.readouterr().err
    return 0, capsys.readouterr().err


@pytest.mark.parametrize("raw,expected", [
    ("300", 300), ("0", 0), ("2.5", 3), ("2.0", 2), ("5.", 5), (".5", 1), ("007", 7), ("0.0", 0),
    ("999999999", 999999999), ("1000000000", 0), ("00000000000000000005", 5),
    ("", None), (".", None), ("-1", None), ("abc", None), ("1.2.3", None), ("1e3", None), (" 5", None),
    ("٣", None),
])
def test_per_limit_rounds_up_and_zero_means_no_limit(raw, expected):
    assert deadline.per_limit(raw) == expected


def test_the_default_total_is_three_times_the_per_request_limit():
    assert deadline.Deadline({"SHUNT_TIMEOUT_SECONDS": "10"}).total == 30
    assert deadline.Deadline({"SHUNT_TIMEOUT_SECONDS": "2.5"}).total == 9
    assert deadline.Deadline({}).total == 900  # the 300 s default


def test_no_per_request_limit_means_no_default_total():
    assert deadline.Deadline({"SHUNT_TIMEOUT_SECONDS": "0"}).total == 0
    assert deadline.Deadline({"SHUNT_TIMEOUT_SECONDS": "1000000000"}).total == 0


def test_a_ten_digit_timeout_keeps_an_explicit_total():
    result = deadline.Deadline({"SHUNT_TIMEOUT_SECONDS": "99999999999", "SHUNT_TOTAL_TIMEOUT_SECONDS": "10"})
    assert result.total == 10


@pytest.mark.parametrize("value", ["0", "-1", "1.5", "abc", "1234567890", "1e3", " 5", "5 "])
def test_an_invalid_total_is_a_config_error(value):
    with pytest.raises(deadline.DeadlineError, match="must be a positive whole number") as err:
        deadline.Deadline({"SHUNT_TOTAL_TIMEOUT_SECONDS": value})
    assert "at most 9 digits" in str(err.value)


def test_an_invalid_timeout_is_a_config_error_that_shows_a_cleaned_value():
    with pytest.raises(deadline.DeadlineError) as err:
        deadline.Deadline({"SHUNT_TIMEOUT_SECONDS": "a\x1b[31mb" + "z" * 100})
    text = str(err.value)
    assert "\x1b" not in text and "config problem, no request sent" in text
    assert text.count("z") == 40 - len("a[31mb")


def test_a_non_ascii_digit_in_the_total_is_refused():
    with pytest.raises(deadline.DeadlineError):
        deadline.Deadline({"SHUNT_TOTAL_TIMEOUT_SECONDS": "٣"})


@pytest.mark.parametrize("env,elapsed,expected", [
    ({"SHUNT_TIMEOUT_SECONDS": "300"}, 0, (300.0, False)),
    ({"SHUNT_TIMEOUT_SECONDS": "12", "SHUNT_TOTAL_TIMEOUT_SECONDS": "30"}, 0, (12.0, False)),
    ({"SHUNT_TIMEOUT_SECONDS": "12", "SHUNT_TOTAL_TIMEOUT_SECONDS": "30"}, 25, (5.0, True)),
    ({"SHUNT_TIMEOUT_SECONDS": "0", "SHUNT_TOTAL_TIMEOUT_SECONDS": "10"}, 0, (10.0, True)),
    ({"SHUNT_TIMEOUT_SECONDS": "99999999999", "SHUNT_TOTAL_TIMEOUT_SECONDS": "10"}, 3, (7.0, True)),
    ({"SHUNT_TIMEOUT_SECONDS": "2.5", "SHUNT_TOTAL_TIMEOUT_SECONDS": "2"}, 0, (2.0, True)),
    ({"SHUNT_TIMEOUT_SECONDS": "2.5", "SHUNT_TOTAL_TIMEOUT_SECONDS": "100"}, 0, (2.5, False)),
    ({"SHUNT_TIMEOUT_SECONDS": "0"}, 50, (None, False)),
    ({"SHUNT_TOTAL_TIMEOUT_SECONDS": "1"}, 0, (1.0, True)),
])
def test_request_time(clock, env, elapsed, expected):
    run = deadline.Deadline(env)
    clock.now = elapsed
    window = run.request_time()
    assert (window.max_time, window.capped) == expected


def test_request_time_is_none_once_the_total_is_used_up(clock):
    run = deadline.Deadline({"SHUNT_TOTAL_TIMEOUT_SECONDS": "10"})
    clock.now = 10
    assert run.request_time() is None


def test_the_note_names_the_model_and_the_chunk_progress(capsys):
    run = deadline.Deadline({"SHUNT_TOTAL_TIMEOUT_SECONDS": "15"})
    run.note("acme/m1")
    run.chunks_total, run.chunks_done = 4, 3
    run.note("acme/m1")
    first, second = capsys.readouterr().err.splitlines()
    assert first == "shunt: model acme/m1: total deadline of 15s (SHUNT_TOTAL_TIMEOUT_SECONDS) reached."
    assert second.endswith("reached, 3 of 4 chunks finished.")


def test_the_real_clock_is_monotonic_milliseconds():
    first = deadline.now_ticks()
    time.sleep(0.01)
    assert deadline.now_ticks() - first >= 5 and deadline.TICKS_PER_SECOND == 1000


# ---- through the transport ---------------------------------------------------------


def test_a_single_request_gets_the_per_request_limit(chunk_world, clock, capsys):
    assert status_of(chunk_world, capsys)[0] == 0
    assert clock.limits == [300.0]


def test_a_total_of_one_second_still_sends_one_request_capped_at_one(chunk_world, clock, capsys):
    assert status_of(chunk_world, capsys, SHUNT_TOTAL_TIMEOUT_SECONDS="1")[0] == 0
    assert clock.limits == [1.0]


def test_an_invalid_timeout_sends_nothing(chunk_world, capsys):
    status, err = status_of(chunk_world, capsys, SHUNT_TIMEOUT_SECONDS="abc")
    assert status == reply.CONFIG and "SHUNT_TIMEOUT_SECONDS must be a non-negative number" in err
    assert chunk_world.server.requests == []


def test_an_invalid_total_sends_nothing(chunk_world, capsys):
    status, err = status_of(chunk_world, capsys, SHUNT_TOTAL_TIMEOUT_SECONDS="abc")
    assert status == reply.CONFIG and "SHUNT_TOTAL_TIMEOUT_SECONDS must be a positive whole number" in err
    assert chunk_world.server.requests == []


def test_the_deadline_hit_between_chunks_stops_further_requests(chunk_world, clock, capsys):
    clock.advance = 10
    status, err = status_of(chunk_world, capsys, chunk_world.big_file(), SHUNT_TOTAL_TIMEOUT_SECONDS="25")
    assert status == reply.DEADLINE
    assert len(chunk_world.server.requests) == 3
    assert "model acme/m1: total deadline of 25s (SHUNT_TOTAL_TIMEOUT_SECONDS) reached, 3 of 4 chunks finished." in err


def test_the_deadline_reached_during_the_merge_comes_after_all_chunks(chunk_world, clock, capsys):
    clock.advance = 10
    status, err = status_of(chunk_world, capsys, chunk_world.big_file(), SHUNT_TOTAL_TIMEOUT_SECONDS="40")
    assert status == reply.DEADLINE
    assert len(chunk_world.server.requests) == 4
    assert "4 of 4 chunks finished" in err


def test_each_request_gets_the_time_left(chunk_world, clock, capsys):
    clock.advance = 10
    status_of(chunk_world, capsys, chunk_world.big_file(), SHUNT_TOTAL_TIMEOUT_SECONDS="15")
    assert clock.limits == [15.0, 5.0]


def test_the_default_total_does_not_shrink_when_the_timeout_is_zero(chunk_world, clock, capsys):
    clock.advance = 1000
    status, _err = status_of(chunk_world, capsys, chunk_world.big_file(), SHUNT_TIMEOUT_SECONDS="0")
    assert status == 0 and len(chunk_world.server.requests) == 5


def test_a_request_that_runs_out_of_the_time_it_was_cut_to_is_a_deadline(chunk_world, capsys):
    chunk_world.server.script(CHUNK_ROUTE, body=CHUNK_REPLY, delay=3)
    started = time.monotonic()
    status, err = status_of(chunk_world, capsys, SHUNT_TOTAL_TIMEOUT_SECONDS="1")
    assert status == reply.DEADLINE and time.monotonic() - started < 2.5
    assert "total deadline of 1s" in err and "chunks finished" not in err and CHUNK_KEY not in err


def test_a_plain_per_request_timeout_stays_a_timeout(chunk_world, capsys):
    chunk_world.server.script(CHUNK_ROUTE, body=CHUNK_REPLY, delay=3)
    status, err = status_of(chunk_world, capsys, SHUNT_TIMEOUT_SECONDS="0.3")
    assert status == reply.TIMEOUT and "total deadline" not in err


def test_a_chunk_timeout_that_was_not_cut_stays_a_timeout(chunk_world, capsys):
    chunk_world.server.script(CHUNK_ROUTE, body=CHUNK_REPLY, delay=3)
    status, _err = status_of(chunk_world, capsys, chunk_world.big_file(), SHUNT_TIMEOUT_SECONDS="0.3")
    assert status == reply.TIMEOUT and len(chunk_world.server.requests) == 1


def test_the_reply_file_is_not_written_when_the_deadline_ends_the_call(chunk_world, clock, capsys, tmp_path):
    clock.advance = 10
    status_of(chunk_world, capsys, chunk_world.big_file(), SHUNT_TOTAL_TIMEOUT_SECONDS="25")
    assert list((tmp_path / "tmp").iterdir()) == []


def test_the_reply_of_a_deadline_free_call_is_valid_json(chunk_world, clock):
    path = transport_http.http_call(CHUNK_AGENT, "q", [], chunk_world.environ)
    assert json.load(open(path))["text"] == "ok"
