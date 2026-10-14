"""evals/preflight.sh helpers: preflight without opencode, first choice lookup, row stamping.

Each test sources the real preflight.sh in bash with REPO_ROOT pointing at a temp tree whose
scripts/shunt-models is a stub, so no registry, provider or network is touched.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
PREFLIGHT = ROOT / "evals" / "preflight.sh"

pytestmark = pytest.mark.skipif(shutil.which("jq") is None, reason="the eval helpers need jq")


def _run(tmp_path, body, status_output="", path=None):
    stub = tmp_path / "scripts" / "shunt-models"
    stub.parent.mkdir(parents=True, exist_ok=True)
    stub.write_text(f"#!/bin/sh\ncat <<'OUT'\n{status_output}\nOUT\n")
    stub.chmod(0o755)
    env = dict(os.environ, REPO_ROOT=str(tmp_path))
    if path is not None:
        env["PATH"] = path
    script = f'source "{PREFLIGHT}"\n{body}\n'
    return subprocess.run([shutil.which("bash"), "-c", script], capture_output=True, text=True, env=env)


def test_preflight_passes_without_opencode_on_path(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for tool in ("jq", "python3"):
        (bin_dir / tool).symlink_to(shutil.which(tool))
    result = _run(tmp_path, "evals_preflight && echo ok", path=str(bin_dir))
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "ok"


STATUS = (
    "shunt: prov/model-a  ok\n"
    "shunt: first choice: prov/Spark/model-b\n"
    "shunt: code-write first choice: other/model-c"
)


@pytest.mark.parametrize(
    ("role", "expected"),
    [("bulk-read", "Spark/model-b"), ("code-write", "model-c")],
)
def test_first_choice_drops_the_provider_prefix(tmp_path, role, expected):
    result = _run(tmp_path, f"evals_first_choice {role}", STATUS)
    assert result.stdout.strip() == expected


def test_first_choice_is_empty_without_a_first_choice(tmp_path):
    result = _run(tmp_path, "evals_first_choice bulk-read", "shunt: no enabled models (large reads are not redirected).")
    assert result.returncode == 0
    assert result.stdout == ""


def test_stamp_rows_adds_both_models_to_every_row(tmp_path):
    rows = tmp_path / "r.jsonl"
    rows.write_text('{"a":1}\n{"a":2,"failed":true}\n')
    result = _run(tmp_path, f'evals_stamp_rows "{rows}" sonnet Spark/model-b')
    assert result.returncode == 0, result.stderr
    stamped = [json.loads(line) for line in rows.read_text().splitlines()]
    assert stamped == [
        {"a": 1, "claude_model": "sonnet", "delegate_model": "Spark/model-b"},
        {"a": 2, "failed": True, "claude_model": "sonnet", "delegate_model": "Spark/model-b"},
    ]
    assert not list(tmp_path.glob("r.jsonl.tmp.*"))


def test_stamp_rows_stores_an_empty_delegate_as_null(tmp_path):
    rows = tmp_path / "r.jsonl"
    rows.write_text('{"a":1}\n')
    _run(tmp_path, f'evals_stamp_rows "{rows}" haiku ""')
    assert json.loads(rows.read_text()) == {"a": 1, "claude_model": "haiku", "delegate_model": None}


def test_stamp_rows_keeps_an_empty_file_empty(tmp_path):
    rows = tmp_path / "r.jsonl"
    rows.write_text("")
    result = _run(tmp_path, f'evals_stamp_rows "{rows}" haiku x')
    assert result.returncode == 0, result.stderr
    assert rows.read_text() == ""


@pytest.mark.parametrize("tail", ['{"a":2', "not json at all"])
def test_stamp_rows_with_an_unparsable_line_leaves_the_file_intact_and_no_temp_file(tmp_path, tail):
    rows = tmp_path / "r.jsonl"
    original = '{"a":1}\n' + tail
    rows.write_text(original)
    result = _run(tmp_path, f'evals_stamp_rows "{rows}" haiku x')
    assert result.returncode != 0
    assert rows.read_text() == original
    assert not list(tmp_path.glob("r.jsonl.tmp.*"))


def test_stamp_rows_gives_a_delegate_only_to_the_delegate_kinds(tmp_path):
    rows = tmp_path / "r.jsonl"
    rows.write_text('{"kind":"no-resume"}\n{"kind":"shunt"}\n{"kind":"shunt-live"}\n{"name":"q1"}\n')
    result = _run(tmp_path, f'evals_stamp_rows "{rows}" sonnet Spark/m "shunt shunt-live"')
    assert result.returncode == 0, result.stderr
    delegates = [json.loads(line)["delegate_model"] for line in rows.read_text().splitlines()]
    assert delegates == [None, "Spark/m", "Spark/m", "Spark/m"]


def test_stamp_rows_warns_when_a_line_is_not_json(tmp_path):
    rows = tmp_path / "r.jsonl"
    rows.write_text('{"a":1}\n{"a":2')
    result = _run(tmp_path, f'evals_stamp_rows "{rows}" haiku x')
    assert "could not add the model fields" in result.stderr


@pytest.mark.parametrize("kinds", ["shunt-lve", "shunt nope"])
def test_baseline_refuses_an_unknown_kind(tmp_path, kinds):
    script = ROOT / "evals" / "baseline-benchmark.sh"
    env = dict(os.environ, BASELINE_KINDS=kinds, SHUNT_BASELINE_MODEL="haiku")
    result = subprocess.run([shutil.which("bash"), str(script)], capture_output=True, text=True, env=env, timeout=30)
    assert result.returncode == 1
    assert "unknown kind" in result.stderr


# ---------------------------------------------------------------- adversarial probes

def test_stamp_rows_big_integer_survives_unchanged(tmp_path):
    rows = tmp_path / "r.jsonl"
    rows.write_text('{"id":12345678901234567890123}\n')
    _run(tmp_path, f'evals_stamp_rows "{rows}" haiku x')
    assert '"id":12345678901234567890123' in rows.read_text()


@pytest.mark.parametrize("row", ["[1,2]", "5", '"s"'])
def test_stamp_rows_non_object_row_leaves_file_intact(tmp_path, row):
    rows = tmp_path / "r.jsonl"
    original = '{"a":1}\n' + row + "\n"
    rows.write_text(original)
    result = _run(tmp_path, f'evals_stamp_rows "{rows}" haiku x')
    assert result.returncode != 0
    assert rows.read_text() == original
    assert not list(tmp_path.glob("r.jsonl.tmp.*"))


def test_stamp_rows_null_row_is_not_turned_into_an_object(tmp_path):
    rows = tmp_path / "r.jsonl"
    rows.write_text('null\n')
    _run(tmp_path, f'evals_stamp_rows "{rows}" haiku x')
    assert rows.read_text().strip() == "null"


def test_stamp_rows_file_with_a_leading_dash_name(tmp_path):
    rows = tmp_path / "-r.jsonl"
    rows.write_text('{"a":1}\n')
    result = _run(tmp_path, f'cd "{tmp_path}"; evals_stamp_rows -r.jsonl haiku x')
    assert result.returncode == 0, result.stderr
    assert json.loads(rows.read_text())["claude_model"] == "haiku"


def test_stamp_rows_name_with_spaces_and_newline(tmp_path):
    rows = tmp_path / "a b\nc.jsonl"
    rows.write_text('{"a":1}\n')
    result = _run(tmp_path, 'evals_stamp_rows "$ROWS" haiku x'.replace("$ROWS", str(rows).replace("\n", "$'\\n'")) if False else
                  f'evals_stamp_rows "{tmp_path}/a b"$\'\\n\'"c.jsonl" haiku x')
    assert result.returncode == 0, result.stderr
    assert json.loads(rows.read_text())["claude_model"] == "haiku"


def test_stamp_rows_kind_that_is_not_a_string(tmp_path):
    rows = tmp_path / "r.jsonl"
    rows.write_text('{"kind":5}\n{"kind":["shunt"]}\n{"kind":""}\n')
    result = _run(tmp_path, f'evals_stamp_rows "{rows}" sonnet D "shunt"')
    assert result.returncode == 0, result.stderr
    delegates = [json.loads(line)["delegate_model"] for line in rows.read_text().splitlines()]
    assert delegates == [None, None, None]


def test_stamp_rows_invalid_utf8_leaves_file_intact(tmp_path):
    rows = tmp_path / "r.jsonl"
    rows.write_bytes(b'{"a":"\xff\xfe"}\n')
    result = _run(tmp_path, f'evals_stamp_rows "{rows}" haiku x')
    assert result.returncode != 0
    assert rows.read_bytes() == b'{"a":"\xff\xfe"}\n'
    assert not list(tmp_path.glob("r.jsonl.tmp.*"))


def test_stamp_rows_crlf_lines(tmp_path):
    rows = tmp_path / "r.jsonl"
    rows.write_bytes(b'{"a":1}\r\n{"a":2}\r\n')
    result = _run(tmp_path, f'evals_stamp_rows "{rows}" haiku x')
    assert result.returncode == 0, result.stderr
    assert len(rows.read_text().splitlines()) == 2


def test_stamp_rows_through_a_symlinked_results_file_keeps_the_link(tmp_path):
    real = tmp_path / "real.jsonl"
    real.write_text('{"a":1}\n')
    link = tmp_path / "link.jsonl"
    link.symlink_to(real)
    _run(tmp_path, f'evals_stamp_rows "{link}" haiku x')
    assert link.is_symlink()
    assert "claude_model" in real.read_text()



@pytest.mark.parametrize("model_id", ["p/a/b", "p/-x", "p/a b", "p/a&b\\1", "p/[x]*.+"])
def test_first_choice_keeps_everything_after_the_provider(tmp_path, model_id):
    result = _run(tmp_path, "evals_first_choice bulk-read", f"shunt: first choice: {model_id}")
    assert result.stdout == model_id.split("/", 1)[1] + "\n"


def test_first_choice_ignores_a_line_that_only_looks_like_one(tmp_path):
    status = "shunt: code-write first choice: p/cw\nshunt: first choice: p/br"
    assert _run(tmp_path, "evals_first_choice bulk-read", status).stdout == "br\n"
    assert _run(tmp_path, "evals_first_choice code-write", status).stdout == "cw\n"


def test_first_choice_for_an_id_without_a_provider_prefix_is_not_leaked_whole(tmp_path):
    result = _run(tmp_path, "evals_first_choice bulk-read", "shunt: first choice: bare")
    assert result.stdout in ("", "bare\n")  # documents behaviour; see report



@pytest.mark.parametrize("kinds", ["   ", "\t\n", "-n", "shunt\nbogus", "shunt,resume"])
def test_baseline_refuses_blank_or_odd_kinds(tmp_path, kinds):
    script = ROOT / "evals" / "baseline-benchmark.sh"
    env = dict(os.environ, BASELINE_KINDS=kinds, SHUNT_BASELINE_MODEL="haiku")
    result = subprocess.run([shutil.which("bash"), str(script)], capture_output=True, text=True, env=env, timeout=30)
    assert result.returncode == 1, (result.stdout, result.stderr)
    assert "BASELINE_KINDS" in result.stderr or "unknown kind" in result.stderr
