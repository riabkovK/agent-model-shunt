"""The response readers and the debug usage log (usage_log.py)."""

import json

from shunt import usage_log


def write(path, doc):
    path.write_text(json.dumps(doc))
    return str(path)


def test_extractors_read_text_usage_and_finish_reason(tmp_path):
    f = write(tmp_path / "r.json", {"text": "answer\n\n", "finish_reason": "stop",
                                    "usage": {"input": 5, "output": 6}, "cost": 0.5})
    assert usage_log.extract_text(f) == "answer"
    assert usage_log.extract_usage(f) == "input=5 output=6 cost=0.5"
    assert usage_log.extract_finish_reason(f) == "stop"


def test_extractors_have_nothing_for_missing_fields_or_a_broken_file(tmp_path):
    f = write(tmp_path / "r.json", {"text": "", "usage": {"input": 5, "output": 6.0}})
    assert usage_log.extract_text(f) == ""
    assert usage_log.extract_usage(f) == "input=5 output=6 cost=0"
    assert usage_log.extract_finish_reason(f) == ""
    assert usage_log.extract_usage(write(tmp_path / "n.json", {"text": "x"})) == ""
    bad = tmp_path / "bad.json"
    bad.write_text("{nope")
    assert (usage_log.extract_text(str(bad)), usage_log.extract_usage(str(bad))) == ("", "")
    assert usage_log.extract_text(str(tmp_path / "missing")) == ""


def test_log_usage_appends_one_line_in_the_documented_key_order(tmp_path):
    resp = write(tmp_path / "r.json", {"text": "a", "usage": {"input": 7, "output": 3}, "cost": 0.1})
    data = tmp_path / "in.txt"
    data.write_text("abcdefgh\n")
    log = tmp_path / "logs" / "usage.jsonl"
    environ = {"SHUNT_DEBUG_LOG_PATH": str(log)}
    usage_log.log_usage("p/one", resp, "q?", [str(data), str(tmp_path / "gone")], environ)
    usage_log.log_code_write("p/two", resp, "spec", 400, [str(data)], environ)
    first, second = (json.loads(line) for line in log.read_text().splitlines())
    assert list(first) == ["timestamp", "agent", "model", "files", "question_chars", "delegate_input_tokens",
                           "delegate_output_tokens", "delegate_cost_usd", "avoided_tokens_estimate", "tool"]
    assert first["files"] == [{"path": str(data), "lines": 1, "bytes": 9}]
    assert (first["question_chars"], first["avoided_tokens_estimate"], first["tool"]) == (2, 3, "bulk-read")
    assert (first["delegate_input_tokens"], first["delegate_output_tokens"], first["delegate_cost_usd"]) == (7, 3, 0.1)
    assert (second["tool"], second["avoided_tokens_estimate"], second["generated_bytes"],
            second["avoided_output_tokens_estimate"]) == ("code-write", 0, 400, 100)
    assert first["timestamp"].endswith("Z") and len(first["timestamp"]) == 20


def test_the_logged_model_is_the_id_or_the_model_line_of_the_agent_file(tmp_path):
    agents = tmp_path / "agents"
    config = tmp_path / "cfg" / "agents"
    agents.mkdir()
    config.mkdir(parents=True)
    (config / "bulk-reader.md").write_text("---\ndescription: d\nmodel: acme/legacy-model  \n---\nbody\nmodel: not/this\n")
    (agents / "nofm.md").write_text("model: x/y\n")
    environ = {"SHUNT_AGENTS_DIR": str(agents), "SHUNT_OPENCODE_CONFIG_HOME": str(tmp_path / "cfg")}
    assert usage_log.log_model("p/one", environ) == "p/one"
    assert usage_log.log_model("bulk-reader", environ) == "acme/legacy-model"
    assert usage_log.log_model("nofm", environ) == ""
    assert usage_log.log_model("missing", environ) == ""


def test_a_log_that_cannot_be_written_never_fails_the_caller(tmp_path):
    resp = write(tmp_path / "r.json", {"text": "a"})
    blocker = tmp_path / "file"
    blocker.write_text("x")
    usage_log.log_usage("p/one", resp, "q", [], {"SHUNT_DEBUG_LOG_PATH": str(blocker / "sub" / "log")})
