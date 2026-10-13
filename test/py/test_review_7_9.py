"""Fixes of reviews 7-9: hard total deadline, unlimited timeout, bounded reads, hidden
characters in stderr, and request size of NUL / invalid UTF-8 text."""

import socket
import threading
import time
import tracemalloc

import pytest

from conftest import CHUNK_AGENT, CHUNK_REPLY, CHUNK_ROUTE
from shunt import chunk_plan, deadline, httpclient, transport_http
from shunt import transport_reply as reply

TIMEOUT = 0.6
SLACK = 2.0


class RawServer:
    """Accepts connections and runs `behavior(conn)` in a thread per connection."""

    def __init__(self, behavior):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(5)
        self.url = f"http://127.0.0.1:{self.sock.getsockname()[1]}"
        self.behavior = behavior
        self.stopped = False
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while not self.stopped:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._run, args=(conn,), daemon=True).start()

    def _run(self, conn):
        try:
            conn.recv(65536)
            self.behavior(conn, lambda: self.stopped)
        except OSError:
            pass
        finally:
            conn.close()

    def close(self):
        self.stopped = True
        self.sock.close()


def _endless_continue(conn, stopped):
    while not stopped():
        conn.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
        time.sleep(0.05)


def _drip(data, gap):
    def behavior(conn, stopped):
        for i in range(len(data)):
            if stopped():
                return
            conn.sendall(data[i:i + 1])
            time.sleep(gap)
    return behavior


HEADER_DRIP = _drip(b"HTTP/1.1 200 OK\r\nX-Pad: " + b"a" * 400 + b"\r\n\r\n", 0.3)
CHUNK_SIZE_DRIP = _drip(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + b"0" * 400 + b"\r\n", 0.3)
BODY_DRIP = _drip(b"HTTP/1.1 200 OK\r\nContent-Length: 400\r\n\r\n" + b"x" * 400, 0.3)


@pytest.mark.parametrize("behavior", [_endless_continue, HEADER_DRIP, CHUNK_SIZE_DRIP, BODY_DRIP],
                         ids=["endless-100-continue", "header-drip", "chunk-size-drip", "body-drip"])
def test_the_timeout_is_a_hard_total_deadline(behavior):
    server = RawServer(behavior)
    started = time.monotonic()
    try:
        with pytest.raises(httpclient.HttpError) as info:
            httpclient.get(server.url + "/x", timeout=TIMEOUT)
    finally:
        server.close()
    assert (info.value.kind, info.value.curl_exit) == ("timeout", 28)
    assert time.monotonic() - started < TIMEOUT + SLACK


def test_a_hung_server_before_the_status_line_ends_with_timeout():
    server = RawServer(lambda conn, stopped: time.sleep(5))
    started = time.monotonic()
    try:
        with pytest.raises(httpclient.HttpError) as info:
            httpclient.post_json(server.url + "/x", {"a": 1}, timeout=TIMEOUT)
    finally:
        server.close()
    assert info.value.kind == "timeout"
    assert time.monotonic() - started < TIMEOUT + SLACK


def test_a_zero_or_missing_timeout_means_no_limit(http_server):
    http_server.script("/ok", body=b"fine", delay=0.3)
    assert httpclient.get(http_server.url + "/ok", timeout=0).body == b"fine"
    assert httpclient.get(http_server.url + "/ok", timeout=None).body == b"fine"


def test_a_fast_answer_comes_back_through_the_worker_thread(http_server):
    http_server.script("/ok", body=b"fine")
    response = httpclient.get(http_server.url + "/ok", timeout=5)
    assert (response.status, response.body) == (200, b"fine")


# ---------------------------------------------------------------- 2. no limit

def test_a_timeout_of_eleven_digits_means_no_limit_and_requests_work(chunk_world, capsys):
    clock = deadline.Deadline({"SHUNT_TIMEOUT_SECONDS": "99999999999"})
    assert clock.request_time().max_time is None
    path = transport_http.http_call(CHUNK_AGENT, "q", [], {**chunk_world.environ,
                                                           "SHUNT_TIMEOUT_SECONDS": "99999999999"})
    assert path
    assert len(chunk_world.server.requests) == 1


def test_a_timeout_of_zero_is_no_limit():
    assert deadline.Deadline({"SHUNT_TIMEOUT_SECONDS": "0"}).request_time().max_time is None


# ---------------------------------------------------------------- 3. bounded reads

def test_a_huge_file_without_newlines_is_refused_before_it_is_read(chunk_world, capsys, tmp_path):
    big = tmp_path / "blob.txt"
    with open(big, "wb") as handle:
        handle.truncate(60_000_000)  # a sparse 60 MB of NULs, no newline
    tracemalloc.start()
    try:
        with pytest.raises(transport_http._Stop) as info:
            transport_http.http_call(CHUNK_AGENT, "q", [str(big)], chunk_world.environ)
        peak = tracemalloc.get_traced_memory()[1]
    finally:
        tracemalloc.stop()
    assert info.value.status == reply.OVERSIZE
    assert "needs more chunks than the limit of 100" in capsys.readouterr().err
    assert peak < 5_000_000
    assert chunk_world.server.requests == []


def test_a_long_line_is_planned_and_cut_without_holding_it_whole(tmp_path):
    big = tmp_path / "line.txt"
    big.write_bytes(b"abc " * 600_000)  # 2.4 MB, one line
    tracemalloc.start()
    try:
        plan = chunk_plan.plan_file(str(big), 10_000, 1000)
        window = chunk_plan._Window(str(big), 1)
        covered = sum(len(window[off:off + length]) for _, _, off, length in plan)
        peak = tracemalloc.get_traced_memory()[1]
    finally:
        tracemalloc.stop()
    assert covered == 2_400_000
    assert all(length <= 10_000 for _, _, _, length in plan)
    assert peak < 800_000  # a whole read of the line alone would be 2.4 MB


def test_a_long_line_between_short_ones_reads_the_same_bytes(tmp_path):
    path = tmp_path / "mix.txt"
    path.write_bytes(b"one\n" + b"y" * 200_000 + b"\nthree\nfour")
    assert chunk_plan.read_lines(str(path), 1, 1) == b"one\n"
    assert chunk_plan.read_lines(str(path), 3, 4) == b"three\nfour"
    assert chunk_plan.read_lines(str(path), 5, 6) == b""
    assert len(chunk_plan._Window(str(path), 2)) == 200_001
    assert chunk_plan._Window(str(path), 2)[3:6] == b"yyy"


def test_build_prompt_reads_at_most_limit_plus_one_bytes(tmp_path):
    big = tmp_path / "big.bin"
    big.write_bytes(b"z" * 5_000_000)
    prompt = transport_http.build_prompt("q", [str(big)], 100)
    assert len(prompt) < 300
    tracemalloc.start()
    try:
        transport_http.build_prompt("q", [str(big)], 100)
        peak = tracemalloc.get_traced_memory()[1]
    finally:
        tracemalloc.stop()
    assert peak < 100_000


def test_an_oversize_file_is_refused_with_the_token_estimate_without_reading_it(chunk_world, capsys, tmp_path):
    chunk_world.server.script(CHUNK_ROUTE, body=CHUNK_REPLY)
    big = tmp_path / "huge.txt"
    big.write_bytes(b"w" * 40_000)
    model = chunk_world.path / "models.json"
    model.write_text(model.read_text().replace('"enabled": true', '"enabled": true, "oversize_policy": "fail"'))
    with pytest.raises(transport_http._Stop) as info:
        transport_http.http_call(CHUNK_AGENT, "q", [str(big)], chunk_world.environ)
    assert info.value.status == reply.OVERSIZE
    assert "input is too large for the model (about 13" in capsys.readouterr().err


# ---------------------------------------------------------------- 4. hidden characters

HIDDEN = "a\x85b‮c d e‏f\x1bg\x7fh­i"


def test_strip_cntrl_drops_controls_format_and_separator_characters():
    assert reply.strip_cntrl(HIDDEN) == "abcdefghi"
    assert reply.strip_cntrl("ключ 日本 ok") == "ключ 日本 ok"


def test_the_excerpt_strips_c1_bidi_and_line_separators():
    shown = reply.excerpt(HIDDEN.encode(), None)
    assert shown == "abcdefghi"


def test_a_deadline_setting_is_shown_without_hidden_characters():
    with pytest.raises(deadline.DeadlineError) as info:
        deadline.Deadline({"SHUNT_TIMEOUT_SECONDS": "5‮\x85s"})
    assert "got '5s'" in str(info.value)


def test_an_unreadable_file_name_is_shown_without_hidden_characters(chunk_world, capsys, tmp_path):
    with pytest.raises(transport_http._Stop):
        transport_http.http_call(CHUNK_AGENT, "q", [str(tmp_path / "no‮ne xt.txt")], chunk_world.environ)
    err = capsys.readouterr().err
    assert "nonext.txt" in err
    assert "‮" not in err and " " not in err


def test_a_chunk_source_name_is_shown_without_hidden_characters(tmp_path, capsys):
    chunk = chunk_plan.Chunk(str(tmp_path / "gone‮.txt"), 1, 1, chunk_plan.NO_OFFSET, 0, 1, 1)
    with pytest.raises(reply.Abort):
        chunk_plan.write_chunk(chunk)
    assert "‮" not in capsys.readouterr().err


# ---------------------------------------------------------------- 5. NUL and invalid UTF-8

def test_sent_size_counts_what_the_request_carries():
    assert transport_http.sent_size("abc ключ".encode()) == len("abc ключ".encode())
    assert transport_http.sent_size(b"a\0b") == 1 + 6 + 1
    assert transport_http.sent_size(b"a\xffb") == 1 + 3 + 1


def test_needs_care_flags_nul_and_invalid_utf8_only(tmp_path):
    clean, nul, bad, cut = (tmp_path / n for n in ("clean", "nul", "bad", "cut"))
    clean.write_bytes("текст\n".encode())
    nul.write_bytes(b"a\0b")
    bad.write_bytes(b"a\xffb")
    cut.write_bytes("é".encode()[:1])  # ends inside a character
    assert [chunk_plan.needs_care(str(p)) for p in (clean, nul, bad, cut)] == [False, True, True, True]


def _bodies(world):
    import json
    return [json.loads(r.body)["messages"][1]["content"] for r in world.server.requests]


@pytest.mark.parametrize("content", [b"\0", b"\xff"], ids=["nul", "invalid-utf8"])
def test_a_small_file_of_inflating_bytes_is_chunked_and_every_chunk_fits(chunk_world, capsys, tmp_path, content):
    path = tmp_path / "dirty.bin"
    path.write_bytes((content * 99 + b"\n") * 200)  # 20000 bytes, far over the budget once sent
    transport_http.http_call(CHUNK_AGENT, "q", [str(path)], chunk_world.environ)
    bodies = _bodies(chunk_world)
    assert len(bodies) > 3
    for text in bodies[:-1]:  # the last request is the merge
        assert len(text.encode()) + 5 * text.count("\0") <= 10800


def test_one_request_with_nul_that_would_exceed_the_budget_once_sent_is_chunked(chunk_world, tmp_path):
    path = tmp_path / "nul.bin"
    path.write_bytes(b"\0" * 5000)  # 5000 bytes raw, 30000 sent
    transport_http.http_call(CHUNK_AGENT, "q", [str(path)], chunk_world.environ)
    assert len(chunk_world.server.requests) > 1


def test_clean_text_still_goes_in_one_request(chunk_world, tmp_path):
    path = tmp_path / "clean.txt"
    path.write_text("привет\n" * 500)  # 7000 bytes
    transport_http.http_call(CHUNK_AGENT, "q", [str(path)], chunk_world.environ)
    assert len(chunk_world.server.requests) == 1
