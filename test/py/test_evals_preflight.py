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


@pytest.mark.parametrize("kinds", ["shunt-lve", "shunt nope"])
def test_baseline_refuses_an_unknown_kind(tmp_path, kinds):
    script = ROOT / "evals" / "baseline-benchmark.sh"
    env = dict(os.environ, BASELINE_KINDS=kinds, SHUNT_BASELINE_MODEL="haiku")
    result = subprocess.run([shutil.which("bash"), str(script)], capture_output=True, text=True, env=env, timeout=30)
    assert result.returncode == 1
    assert "unknown kind" in result.stderr
