"""map_reduce chunking in one process (port of transport-http-chunking.sh)."""

import json
import os
import re
import subprocess
import sys

import pytest

from conftest import CHUNK_AGENT, CHUNK_KEY, CHUNK_REPLY, CHUNK_ROUTE, SHUNT_MAIN
from shunt import chunk_plan, chunking, providers, transport_http
from shunt import transport_reply as reply

BUDGET = 10800  # 6000 tokens, 60 percent, 3 bytes per token


def run_call(world, capsys, *files, question="q", **env):
    """(status, stderr) of a call, or (0, reply document)."""
    try:
        path = transport_http.http_call(CHUNK_AGENT, question, list(files), {**world.environ, **env})
    except transport_http._Stop as stop:
        return stop.status, capsys.readouterr().err
    return 0, json.load(open(path))


def user_texts(world):
    return [json.loads(r.body)["messages"][1]["content"] for r in world.server.requests]


def chunk_ranges(world):
    notes = [re.search(r"lines (\d+)-(\d+)\.", t) for t in user_texts(world)[:-1]]
    return [(int(m.group(1)), int(m.group(2))) for m in notes]


# ---- one process, one key lookup ----------------------------------------------------


def test_a_chunked_call_asks_each_chunk_then_merges(chunk_world, capsys):
    status, doc = run_call(chunk_world, capsys, chunk_world.big_file())
    assert status == 0 and doc["text"] == "ok"
    assert len(chunk_world.server.requests) == 5
    assert "asking in 4 parts and merging" in capsys.readouterr().err


def test_the_key_is_read_once_per_call(chunk_world, capsys, monkeypatch):
    calls = []
    real = providers.bearer_key
    monkeypatch.setattr(providers, "bearer_key", lambda *a, **k: calls.append(1) or real(*a, **k))
    registry_reads = []
    real_load = transport_http.models._load
    monkeypatch.setattr(transport_http.models, "_load", lambda p: registry_reads.append(p) or real_load(p))
    assert run_call(chunk_world, capsys, chunk_world.big_file())[0] == 0
    assert len(chunk_world.server.requests) == 5 and calls == [1]
    assert len(registry_reads) == 1


def test_every_request_carries_the_key_and_it_is_never_in_a_message(chunk_world, capsys, tmp_path):
    run_call(chunk_world, capsys, chunk_world.big_file())
    assert {r.headers["authorization"] for r in chunk_world.server.requests} == {f"Bearer {CHUNK_KEY}"}
    assert CHUNK_KEY not in capsys.readouterr().err
    assert all(CHUNK_KEY not in r.body.decode() for r in chunk_world.server.requests)
    assert len(list((tmp_path / "tmp").iterdir())) == 1  # the reply file only


def test_usage_and_cost_are_totalled_over_every_request(chunk_world, capsys):
    chunk_world.server.script(CHUNK_ROUTE, body={**CHUNK_REPLY, "usage": {
        "prompt_tokens": 100, "completion_tokens": 7, "cost": 0.25}})
    status, doc = run_call(chunk_world, capsys, chunk_world.big_file())
    assert status == 0
    assert doc == {"text": "ok", "finish_reason": "stop", "usage": {"input": 500, "output": 35}, "cost": 1.25}


def test_a_reply_without_usage_gives_a_total_without_usage(chunk_world, capsys):
    chunk_world.server.script(CHUNK_ROUTE, body={"choices": CHUNK_REPLY["choices"]})
    status, doc = run_call(chunk_world, capsys, chunk_world.big_file())
    assert status == 0 and doc == {"text": "ok", "finish_reason": "stop"}


# ---- prompts, notes and merge order ---------------------------------------------------


def test_chunk_prompts_name_the_file_and_the_lines(chunk_world, capsys):
    big = chunk_world.big_file()
    run_call(chunk_world, capsys, big, question="what is here?")
    first = user_texts(chunk_world)[0]
    head = (f"what is here?\n\n(This is part 1 of 4 of {big}, lines 1-")
    assert first.startswith(head)
    assert f". Answer for this part only.)\n\n--- file: {big} ---\nL0001 " in first
    assert first.endswith("\n--- end of file ---\n")


def test_neighbouring_line_chunks_overlap_and_cover_the_file(chunk_world, capsys):
    run_call(chunk_world, capsys, chunk_world.big_file(300))
    ranges = chunk_ranges(chunk_world)
    assert ranges[0][0] == 1 and ranges[-1][1] == 300
    for (_a, b), (c, _d) in zip(ranges, ranges[1:]):
        assert 0 <= b - c + 1 <= chunk_plan.CHUNK_OVERLAP_LINES


def test_every_request_fits_the_budget(chunk_world, capsys):
    run_call(chunk_world, capsys, chunk_world.big_file(300))
    for request in chunk_world.server.requests:
        messages = json.loads(request.body)["messages"]
        assert sum(len(m["content"].encode()) for m in messages) <= BUDGET


def test_the_merge_request_lists_the_partial_answers_in_order(chunk_world, capsys):
    run_call(chunk_world, capsys, chunk_world.big_file(), question="the question")
    merge = user_texts(chunk_world)[-1]
    assert merge.startswith(f"the question\n\n{chunking.MERGE_INSTRUCTION}\n")
    labels = re.findall(r"\n--- partial answer (\d+) of 4 \((.*?)\) ---\nok\n", merge)
    assert [n for n, _ in labels] == ["1", "2", "3", "4"]
    assert labels[0][1].endswith(", lines 1-" + chunk_ranges(chunk_world)[0][1].__str__())
    assert "(This is part" not in merge


def test_the_merge_instruction_text_is_the_bash_one():
    assert chunking.MERGE_INSTRUCTION == (
        "The input was too large to send at once, so it was analysed in parts. Below are the partial "
        "answers to the question above, one per part. Neighbouring parts of one file share 20 lines, "
        "so the same finding can appear twice. Combine them into one final answer to the question, "
        "without repeating duplicates.")


def test_a_partial_answer_loses_its_trailing_newlines(chunk_world, capsys):
    chunk_world.server.script(CHUNK_ROUTE, body={"choices": [
        {"message": {"content": "answer\n\n\n"}, "finish_reason": "stop"}]})
    run_call(chunk_world, capsys, chunk_world.big_file())
    assert "\nanswer\n\n--- partial answer 2" in user_texts(chunk_world)[-1]


def test_two_files_get_their_own_part_numbers(chunk_world, capsys):
    first, second = chunk_world.big_file(150, "a.txt"), chunk_world.big_file(150, "b.txt")
    run_call(chunk_world, capsys, first, second)
    texts = user_texts(chunk_world)
    assert f"part 1 of 2 of {first}, lines" in texts[0] and f"part 2 of 2 of {second}, lines" in texts[-2]


def test_a_failing_chunk_aborts_and_sends_no_later_request(chunk_world, capsys):
    chunk_world.server.script(CHUNK_ROUTE, status=500, body="oops")
    status, err = run_call(chunk_world, capsys, chunk_world.big_file())
    assert status == reply.ERROR and len(chunk_world.server.requests) == 1
    assert "answered HTTP 500" in err


def test_an_empty_chunk_answer_is_the_empty_status(chunk_world, capsys):
    chunk_world.server.script(CHUNK_ROUTE, body={"choices": [{"message": {"content": ""}, "finish_reason": "stop"}]})
    assert run_call(chunk_world, capsys, chunk_world.big_file())[0] == reply.EMPTY


# ---- budgets ------------------------------------------------------------------------------


def test_exactly_the_chunk_limit_is_sent_and_one_more_is_refused(chunk_world, capsys):
    big = chunk_world.path / "m.txt"
    room = BUDGET - chunk_plan.overhead("q", str(big), "99999", len(b"You read."))
    big.write_text("a" * (3 * room))
    assert run_call(chunk_world, capsys, str(big), SHUNT_HTTP_MAX_CHUNKS="3")[0] == 0
    assert len(chunk_world.server.requests) == 4
    big.write_text("a" * (3 * room + 1))
    chunk_world.server.requests.clear()
    status, err = run_call(chunk_world, capsys, str(big), SHUNT_HTTP_MAX_CHUNKS="3")
    assert status == reply.OVERSIZE and "more chunks than the limit of 3" in err
    assert chunk_world.server.requests == []


@pytest.mark.parametrize("raw,expected", [("", 100), ("7", 7), ("0", 100), ("-3", 100), ("x", 100), ("1.5", 100)])
def test_the_chunk_limit_comes_from_the_environment(raw, expected):
    assert chunking.max_chunks({"SHUNT_HTTP_MAX_CHUNKS": raw}) == expected


def test_a_question_that_alone_exceeds_the_budget_fails_with_nothing_sent(chunk_world, capsys):
    status, err = run_call(chunk_world, capsys, chunk_world.big_file(), question="q" * 20000)
    assert status == reply.OVERSIZE and "leave no room for file content" in err
    assert chunk_world.server.requests == []


def test_a_call_without_files_has_no_chunks_to_send(chunk_world, capsys):
    status, err = run_call(chunk_world, capsys, question="q" * 20000)
    assert status == reply.OVERSIZE  # the question alone leaves no room
    assert "no room" in err


def test_no_files_and_no_oversize_never_reaches_map_reduce(chunk_world, capsys):
    with pytest.raises(transport_http._Stop) as stop:
        chunking.map_reduce("q", [], model_id="acme/m1", system_len=9, context_tokens="6000",
                            ask=lambda _p: {}, environ={}, progress=type("P", (), {})())
    assert stop.value.status == reply.ERROR and "no chunks to send" in capsys.readouterr().err


def test_empty_and_one_byte_files_next_to_a_big_file_all_fit(chunk_world, capsys):
    empty, one = chunk_world.path / "empty.txt", chunk_world.path / "one.txt"
    empty.write_text("")
    one.write_text("z")
    assert run_call(chunk_world, capsys, str(empty), str(one), chunk_world.big_file(), question="")[0] == 0
    for request in chunk_world.server.requests:
        messages = json.loads(request.body)["messages"]
        assert sum(len(m["content"].encode()) for m in messages) <= BUDGET


def test_hostile_file_names_keep_every_request_in_budget(chunk_world, capsys):
    name = chunk_world.path / ("-n a \"q\" 'r'\nünï€😀 " + "ж" * 100 + ".txt")
    name.write_text("".join(f"L{i:04d} {'x' * 93}\n" for i in range(300)))
    assert run_call(chunk_world, capsys, str(name))[0] == 0
    assert "ünï€😀" in user_texts(chunk_world)[0]
    for request in chunk_world.server.requests:
        messages = json.loads(request.body)["messages"]
        assert sum(len(m["content"].encode()) for m in messages) <= BUDGET


# ---- the planner ------------------------------------------------------------------------------


def plan(path, budget, room=100):
    return chunk_plan.plan_file(str(path), budget, room)


def rebuild(path, budget):
    pieces = plan(path, budget, 10**6)
    out, nxt = b"", 1
    for i, (start, end, off, length) in enumerate(pieces, 1):
        data = chunk_plan.write_chunk(chunk_plan.Chunk(str(path), start, end, off, length, i, len(pieces)))
        if off >= 0:
            out, nxt = out + data, start + 1
        else:
            out, nxt = out + b"".join(data.splitlines(keepends=True)[nxt - start:]), end + 1
    return pieces, out


def test_a_file_that_fits_is_one_chunk(tmp_path):
    target = tmp_path / "f"
    target.write_bytes(b"a\nb\nc")
    assert plan(target, 100) == [(1, 3, -1, 0)]
    target.write_bytes(b"")
    assert plan(target, 100) == [(1, 1, -1, 0)]


@pytest.mark.parametrize("char", ["é", "€", "😀"])
@pytest.mark.parametrize("prefix", ["", "a", "ab", "abc"])
def test_an_overlong_line_of_multibyte_characters_is_rebuilt_byte_for_byte(tmp_path, char, prefix):
    target = tmp_path / "u.txt"
    target.write_bytes((prefix + char * 9000 + "\n").encode())
    pieces, joined = rebuild(target, 200)
    assert len(pieces) > 1 and joined == target.read_bytes()
    for start, _end, off, length in pieces:
        piece = chunk_plan.write_chunk(chunk_plan.Chunk(str(target), start, start, off, length, 1, 1))
        assert len(piece) <= 200
        piece.decode("utf-8")


def test_invalid_utf8_loses_no_bytes(tmp_path):
    target = tmp_path / "bad.bin"
    target.write_bytes(b"\x80" * 15000 + b"\xe2\x82" * 2000 + b"\xc0\xaf" * 2000 + b"\xf0\x9f" * 2000)
    pieces, joined = rebuild(target, 200)
    assert len(pieces) > 1 and joined == target.read_bytes()


def test_crlf_lines_nul_bytes_and_a_last_line_without_newline_survive(tmp_path):
    target = tmp_path / "mix.bin"
    rows = b"".join(b"row %04d\0with nul and crlf %s\r\n" % (i, b"y" * 40) for i in range(400))
    target.write_bytes(rows + b"z" * 30000)
    pieces, joined = rebuild(target, 1000)
    assert len(pieces) > 2 and joined == target.read_bytes()


def test_a_file_of_only_newlines_and_a_file_without_any_are_rebuilt(tmp_path):
    target = tmp_path / "nl"
    target.write_bytes(b"\n" * 50000)
    assert rebuild(target, 1000)[1] == target.read_bytes()
    target.write_bytes(b"k" * 50000)
    assert rebuild(target, 1000)[1] == target.read_bytes()


def test_a_line_exactly_at_the_budget_is_a_line_chunk_and_one_over_is_split(tmp_path):
    target = tmp_path / "b.txt"
    tail = b"".join(b"%04d %s\n" % (i, b"x" * 90) for i in range(200))
    target.write_bytes(b"a" * 99 + b"\n" + tail)
    assert plan(target, 100)[0][2] == -1
    target.write_bytes(b"a" * 100 + b"\n" + tail)
    assert plan(target, 100)[0][2] == 0


def test_a_lone_newline_is_not_a_request_of_its_own(tmp_path):
    target = tmp_path / "b.txt"
    target.write_bytes(b"a" * 100 + b"\n" + b"tail line\n" * 30)
    for _start, _end, off, length in plan(target, 100):
        assert not (off >= 0 and length == 1)


def test_a_long_line_ending_in_whitespace_sends_no_whitespace_only_piece(tmp_path):
    target = tmp_path / "w.txt"
    target.write_bytes(b"a" * 97 + b"      \r\n" + b"tail line\n" * 30)
    pieces = plan(target, 100)
    for start, end, off, length in pieces:
        if off >= 0:
            data = chunk_plan.write_chunk(chunk_plan.Chunk(str(target), start, end, off, length, 1, 1))
            assert data.strip()


def test_utf8_cut_steps_back_to_a_character_start():
    data = "ab€cd".encode()  # the euro sign is bytes 2..4
    assert [chunk_plan.utf8_cut(data, pos) for pos in range(2, 7)] == [2, 2, 2, 5, 6]
    assert chunk_plan.utf8_cut(b"\x80\x80\x80\x80\x80", 4) == 4


def test_planning_a_huge_file_of_newlines_stops_early(tmp_path):
    target = tmp_path / "huge"
    target.write_bytes(b"\n" * 20_000_000)
    assert len(plan(target, 10000, 100)) == 101  # one more than the limit, then it stops


def test_a_missing_file_cannot_be_planned_or_cut(tmp_path, capsys):
    missing = str(tmp_path / "missing")
    with pytest.raises(transport_http._Stop) as stop:
        chunk_plan.write_chunk(chunk_plan.Chunk(missing, 1, 1, 0, 5, 1, 1))
    assert stop.value.status == reply.FAILED and "cannot read" in capsys.readouterr().err
    with pytest.raises(OSError):
        plan(missing, 100)


def test_a_directory_is_not_a_source(tmp_path, capsys):
    with pytest.raises(transport_http._Stop):
        chunk_plan.write_chunk(chunk_plan.Chunk(str(tmp_path), 1, 1, 2, 100, 1, 1))
    assert "cannot read" in capsys.readouterr().err


def test_a_file_truncated_after_planning_fails_instead_of_a_short_chunk(tmp_path, capsys):
    target = tmp_path / "short.txt"
    target.write_text("abcdef\n")
    with pytest.raises(transport_http._Stop) as stop:
        chunk_plan.write_chunk(chunk_plan.Chunk(str(target), 1, 1, 2, 100, 1, 1))
    assert stop.value.status == reply.FAILED and "expected 100 bytes" in capsys.readouterr().err


def test_a_small_slice_of_a_huge_line_is_cut(tmp_path):
    target = tmp_path / "long.txt"
    target.write_bytes(b"a" * 300000 + b"\n")
    assert chunk_plan.write_chunk(chunk_plan.Chunk(str(target), 1, 1, 0, 10, 1, 1)) == b"a" * 10


# ---- merging and usage -----------------------------------------------------------------


def merger(limit, ask):
    return chunking._Merger("q", "acme/m1", limit, ask)


def test_one_partial_answer_alone_too_big_fails_the_merge(capsys):
    partials = chunking._Partials(["x" * 5000, "y"], ["a", "b"])
    with pytest.raises(transport_http._Stop) as stop:
        merger(2000, lambda p: {"text": "t"}).merge(partials)
    assert stop.value.status == reply.ERROR
    assert "one partial answer alone is too big" in capsys.readouterr().err


def test_merging_that_makes_no_progress_fails(capsys):
    partials = chunking._Partials(["x" * 600, "y" * 600], ["a", "b"])
    with pytest.raises(transport_http._Stop):
        merger(1500, lambda p: {"text": "z" * 600}).merge(partials)
    err = capsys.readouterr().err
    assert "the partial answers cannot be merged" in err and "no result" in err


def test_the_merge_depth_is_capped(capsys):
    partials = chunking._Partials(["x" * 300] * 40, [f"l{i}" for i in range(40)])
    with pytest.raises(transport_http._Stop):
        merger(len(chunking.MERGE_INSTRUCTION) + 1200, lambda p: {"text": "w" * 300}).merge(partials)
    assert "still too big after 3 rounds of merging, depth cap reached" in capsys.readouterr().err


def test_groups_merge_in_rounds_before_the_final_request():
    asked = []

    def ask(prompt):
        asked.append(prompt)
        return {"text": "m"}

    partials = chunking._Partials(["x" * 300] * 6, [f"l{i}" for i in range(6)])
    result = merger(len(chunking.MERGE_INSTRUCTION) + 1000, ask).merge(partials)
    assert result == {"text": "m"} and len(asked) > 1
    assert b"merged parts l0 .. l" in asked[-1] or b"(l0)" in asked[-1]


def test_usage_ignores_values_that_are_not_whole_numbers():
    usage = chunking.Usage()
    usage.add({"usage": {"input": "x[$(id)]", "output": 1.5}, "cost": "free"})
    usage.add({"usage": {"input": 4, "output": True}, "cost": -1})
    assert (usage.tokens_in, usage.tokens_out, usage.cost) == (4, 0, None)
    assert usage.apply({"text": "t", "usage": {"input": 9}, "cost": 3}) == {
        "text": "t", "usage": {"input": 4, "output": 0}}


def test_cost_totals_print_whole_numbers_without_a_fraction():
    usage = chunking.Usage()
    usage.add({"cost": 1.5})
    usage.add({"cost": 0.5})
    assert usage.apply({"text": "t"}) == {"text": "t", "cost": 2}
    assert isinstance(usage.apply({"text": "t"})["cost"], int)


def test_the_budget_counts_only_plain_digits():
    assert chunking.budget_bytes("6000") == BUDGET
    assert chunking.budget_bytes("") == chunking.budget_bytes("1e30") == chunking.budget_bytes("-3") == 0
    assert chunking.budget_bytes("1234567890123") == 0


# ---- the CLI ----------------------------------------------------------------------------------


def test_the_cli_chunks_in_one_process_and_prints_the_reply_path(chunk_world):
    argv = [sys.executable, "-I", "-B", str(SHUNT_MAIN), "transport", "http-call", "--", CHUNK_AGENT, "q",
            chunk_world.big_file()]
    done = subprocess.run(argv, env=chunk_world.environ, capture_output=True, text=True, check=False)
    assert done.returncode == 0 and len(chunk_world.server.requests) == 5
    path = done.stdout.strip()
    assert os.path.basename(path).startswith("shunt-opencode.") and json.load(open(path))["text"] == "ok"
    assert CHUNK_KEY not in done.stderr + done.stdout


def test_the_cli_has_no_http_ask_command_any_more(chunk_world):
    argv = [sys.executable, "-I", "-B", str(SHUNT_MAIN), "transport", "http-ask", "--", CHUNK_AGENT, "/x"]
    done = subprocess.run(argv, env=chunk_world.environ, capture_output=True, text=True, check=False)
    assert done.returncode != 0 and chunk_world.server.requests == []
