"""scripts/usage-report in one process (usage_report.py): the same JSON the jq program printed."""

import json

import pytest

from shunt import usage_report


def entry(agent, tool=None, model=None, cost=0.25, avoided=100, **extra):
    row = {"agent": agent, "delegate_input_tokens": 10, "delegate_output_tokens": 5,
           "delegate_cost_usd": cost, "avoided_tokens_estimate": avoided, **extra}
    if tool:
        row["tool"] = tool
    if model:
        row["model"] = model
    return row


def write_log(path, rows):
    path.write_text("".join(json.dumps(r) + "\n" for r in rows))
    return str(path)


def report(path, capsys):
    code = usage_report.main([path], {})
    out = capsys.readouterr()
    return code, out.out, out.err


def test_counts_distinct_models_not_providers(tmp_path, capsys):
    rows = [entry("mac/qwen36"), entry("mac/qwen38"), entry("bootsman/Spark/deepseek-v4.1-flash")]
    code, out, _ = report(write_log(tmp_path / "u.jsonl", rows), capsys)
    data = json.loads(out)
    assert code == 0
    assert sorted(m["model"] for m in data["by_model"]) == [
        "bootsman/Spark/deepseek-v4.1-flash", "mac/qwen36", "mac/qwen38"]
    assert len(data["by_model"]) == 3  # three models on two providers, one row per model


def test_groups_by_tool_and_model_and_sums_in_order(tmp_path, capsys):
    rows = [entry("p/one", cost=0.25, avoided=400), entry("p/one", "bulk-read", avoided=100),
            entry("p/one", "code-write", cost=0.5, avoided=0, generated_bytes=7, avoided_output_tokens_estimate=2),
            entry("p/two", "bulk-read", cost=0.125, avoided=8)]
    _, out, err = report(write_log(tmp_path / "u.jsonl", rows), capsys)
    data = json.loads(out)
    assert data["calls"] == 4
    assert data["delegate_cost_usd"] == 1.125
    assert [(t["tool"], t["calls"], t["generated_bytes"]) for t in data["by_tool"]] == [
        ("bulk-read", 3, 0), ("code-write", 1, 7)]
    rows_by = {(m["tool"], m["model"]): m for m in data["by_model"]}
    assert rows_by[("bulk-read", "p/one")]["avoided_tokens_estimate"] == 500
    assert rows_by[("code-write", "p/one")]["avoided_output_tokens_estimate"] == 2
    assert list(data) == ["calls", "delegate_input_tokens", "delegate_output_tokens", "delegate_cost_usd",
                          "avoided_tokens_estimate", "avoided_output_tokens_estimate", "by_tool", "by_model"]
    assert out.startswith('{\n  "calls": 4,\n')
    assert err.count("\nshunt: ") == 3 and err.startswith("\nshunt: avoided_tokens_estimate")


def test_tool_and_model_groups_sum_delegate_tokens(tmp_path, capsys):
    rows = [entry("p/one", "bulk-read"), entry("p/one", "bulk-read", delegate_input_tokens=30),
            entry("p/two", "code-write", delegate_output_tokens=7)]
    _, out, _ = report(write_log(tmp_path / "u.jsonl", rows), capsys)
    data = json.loads(out)
    assert [(t["tool"], t["delegate_input_tokens"], t["delegate_output_tokens"]) for t in data["by_tool"]] == [
        ("bulk-read", 40, 10), ("code-write", 10, 7)]
    assert [(m["model"], m["delegate_input_tokens"], m["delegate_output_tokens"]) for m in data["by_model"]] == [
        ("p/one", 40, 10), ("p/two", 10, 7)]


def test_a_legacy_agent_name_is_not_reported_as_a_model(tmp_path, capsys):
    rows = [entry("bulk-reader"), entry("bulk-reader", model="p/legacy", tool="bulk-read")]
    _, out, _ = report(write_log(tmp_path / "u.jsonl", rows), capsys)
    labels = sorted(m["model"] for m in json.loads(out)["by_model"])
    assert labels == ["p/legacy", "unknown (legacy OpenCode agent bulk-reader)"]


def test_a_missing_or_empty_log_exits_1_with_the_hint(tmp_path, capsys):
    empty = tmp_path / "empty.jsonl"
    empty.write_text("")
    for path in (str(tmp_path / "none.jsonl"), str(empty)):
        code, out, err = report(path, capsys)
        assert (code, out) == (1, "")
        assert err == f"shunt: no usage log at {path} (enable with SHUNT_DEBUG_LOG=1, see /usage-report skill).\n"


def test_invalid_json_and_non_numbers_fail_without_a_report(tmp_path, capsys):
    bad = tmp_path / "bad.jsonl"
    bad.write_text('{"agent": "a/b"\n')
    code, out, err = report(str(bad), capsys)
    assert (code, out) == (2, "") and "not valid JSON" in err
    text = write_log(tmp_path / "s.jsonl", [entry("a/b", cost="free")])
    code, out, err = report(text, capsys)
    assert (code, out) == (5, "") and "not a number" in err


def test_the_log_path_defaults_to_the_env_then_the_cache_dir(tmp_path, capsys):
    path = write_log(tmp_path / "env.jsonl", [entry("a/b")])
    assert usage_report.main([], {"SHUNT_DEBUG_LOG_PATH": path}) == 0
    assert json.loads(capsys.readouterr().out)["calls"] == 1
    assert usage_report.main([], {"HOME": str(tmp_path)}) == 1
    assert str(tmp_path / ".cache/agent-model-shunt/usage.jsonl") in capsys.readouterr().err


@pytest.mark.parametrize("total, shown", [(2.0, 2), (0.1 + 0.2, 0.30000000000000004)])
def test_float_sums_print_like_jq(tmp_path, capsys, total, shown):
    half = total / 2 if total == 2.0 else None
    rows = [entry("a/b", cost=half), entry("a/b", cost=half)] if half else [entry("a/b", cost=0.1), entry("a/b", cost=0.2)]
    _, out, _ = report(write_log(tmp_path / "u.jsonl", rows), capsys)
    assert json.loads(out)["delegate_cost_usd"] == shown
