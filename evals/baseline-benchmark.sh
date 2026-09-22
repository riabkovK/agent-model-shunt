#!/bin/bash
# End-to-end usefulness benchmark: shunt (scripts/bulk-read, via OpenCode)
# versus the baseline of Claude reading the same files directly.
#
# evals/benchmark.sh already measures the *delegated* OpenCode round trip in
# isolation. This script instead measures what actually matters for
# deciding whether shunt is worth it: the real cost paid on the Claude side
# (context tokens and $) and the real wall-clock time, against the same
# question over the same fixture files, in three variants:
#
#   no-resume  Each scenario is sent as a brand-new `claude -p` session (no
#              prior turns). Represents the cost of Claude reading a file
#              directly with no session-level amortization.
#   resume     Scenarios within one iteration are chained via `--resume`
#              into the same Claude session, so only the first scenario
#              pays this project's system-prompt/CLAUDE.md priming cost.
#              Represents a real interactive session reading several files.
#   shunt      The same question delegated to scripts/bulk-read directly
#              (no Claude session involved). context_tokens here is an
#              ESTIMATE (chars/4 of the response), not a measured usage
#              number, since no `claude -p` call happens in this variant.
#   shunt-live The honest version of `shunt`: a real `claude -p` session
#              that is told to delegate to scripts/bulk-read (via the Bash
#              tool, with all other tools disabled) and answer from what it
#              returns. context_tokens/cost here are measured the same way
#              as no-resume/resume (from `.usage` in the JSON response), so
#              this is the number that's actually comparable to them.
#
# Baseline (no-resume/resume/shunt-live) calls hit the real Claude API and
# spend real money (see `cost_usd` per row and the total printed at the
# end). Run this deliberately, not in a loop or a retry cycle - each
# `claude -p` call counts against your account's usage.
#
# Requires a reachable OpenCode provider (for the shunt side) and a logged
# in `claude` CLI (for the baseline side). NOT part of the no-network
# evals/run.sh suite.
#
# Usage: evals/baseline-benchmark.sh
#
# Env:
#   ITERATIONS              Repeats per scenario/variant (default: 3). Total
#                            claude -p calls = ITERATIONS * 3 scenarios * 2
#                            (no-resume + resume). Keep this modest - it
#                            counts against real usage/rate limits with no
#                            retry if a later iteration fails.
#   SHUNT_BASELINE_MODEL     Model alias for `claude -p --model` (default: sonnet).
#   SHUNT_BASELINE_TIMEOUT   Timeout in seconds per claude -p call (default: 120).

set -uo pipefail

EVALS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$EVALS_DIR/.." && pwd)"
BENCHMARKS="$EVALS_DIR/benchmarks.json"
RESULTS_DIR="$EVALS_DIR/results"
RESULTS_JSONL="$RESULTS_DIR/baseline-benchmark.jsonl"
SUMMARY_JSON="$RESULTS_DIR/baseline-benchmark-summary.json"

SHUNT_BASELINE_MODEL="${SHUNT_BASELINE_MODEL:-sonnet}"
SHUNT_BASELINE_TIMEOUT="${SHUNT_BASELINE_TIMEOUT:-120}"
SHUNT_LIVE_TIMEOUT="${SHUNT_LIVE_TIMEOUT:-600}"
ITERATIONS="${ITERATIONS:-3}"

command -v claude >/dev/null 2>&1 || { echo "baseline-benchmark: 'claude' not found in PATH." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "baseline-benchmark: 'jq' not found in PATH." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "baseline-benchmark: 'python3' not found in PATH (needed for aggregation)." >&2; exit 1; }

# shellcheck source=../scripts/lib/opencode.sh
source "$REPO_ROOT/scripts/lib/opencode.sh"
shunt_preflight

mkdir -p "$RESULTS_DIR"
: > "$RESULTS_JSONL"

count=$(jq '.benchmarks | length' "$BENCHMARKS")
total_cost_usd="0"
any_failed=0

scenario_prompt() {
  local idx="$1"
  local question
  question=$(jq -r ".benchmarks[$idx].question" "$BENCHMARKS")
  local prompt="$question"
  while IFS= read -r p; do
    prompt="$prompt

=== $p ===
$(cat "$EVALS_DIR/$p")"
  done < <(jq -r ".benchmarks[$idx].paths[]" "$BENCHMARKS")
  prompt="$prompt

Answer using only the content above. Do not use any tools."
  echo "$prompt"
}

# run_baseline_call <iteration> <scenario-name> <kind: no-resume|resume> <prompt> <resume-session-id-or-empty>
# Sets global LAST_SESSION_ID (empty on failure) instead of using stdout /
# a $(...) capture, so it can run in the caller's own shell (not a
# subshell) and its updates to the global total_cost_usd/any_failed stick.
run_baseline_call() {
  local iter="$1" name="$2" kind="$3" prompt="$4" resume_id="$5"
  LAST_SESSION_ID=""

  local resume_args=()
  [ -n "$resume_id" ] && resume_args=(--resume "$resume_id")

  echo "[iter $iter/$ITERATIONS][$name] $kind (claude -p)..." >&2
  local base_json status
  base_json=$(mktemp)
  status=0
  timeout "$SHUNT_BASELINE_TIMEOUT" claude -p --output-format json --model "$SHUNT_BASELINE_MODEL" \
    "${resume_args[@]}" "$prompt" >"$base_json" 2>/dev/null || status=$?

  if [ "$status" -ne 0 ] || [ ! -s "$base_json" ]; then
    echo "  $kind FAILED (exit $status)" >&2
    jq -n -c --arg iter "$iter" --arg scenario "$name" --arg kind "$kind" \
      '{iteration: ($iter|tonumber), scenario: $scenario, kind: $kind, failed: true}' >>"$RESULTS_JSONL"
    rm -f "$base_json"
    any_failed=1
    return 1
  fi

  local new_session in_tok out_tok cread cwrite cost ctx_tokens
  new_session=$(jq -r '.session_id // empty' "$base_json")
  local dur_ms
  dur_ms=$(jq -r '.duration_ms // 0' "$base_json")
  in_tok=$(jq -r '.usage.input_tokens // 0' "$base_json")
  out_tok=$(jq -r '.usage.output_tokens // 0' "$base_json")
  cread=$(jq -r '.usage.cache_read_input_tokens // 0' "$base_json")
  cwrite=$(jq -r '.usage.cache_creation_input_tokens // 0' "$base_json")
  cost=$(jq -r '.total_cost_usd // 0' "$base_json")
  ctx_tokens=$((in_tok + cread + cwrite))
  total_cost_usd=$(awk -v a="$total_cost_usd" -v b="$cost" 'BEGIN { printf "%.6f", a + b }')
  rm -f "$base_json"

  jq -n -c --arg iter "$iter" --arg scenario "$name" --arg kind "$kind" \
    --argjson duration_ms "$dur_ms" --argjson context_tokens "$ctx_tokens" \
    --argjson input_tokens "$in_tok" --argjson output_tokens "$out_tok" \
    --argjson cache_read_tokens "$cread" --argjson cache_write_tokens "$cwrite" \
    --argjson cost_usd "$cost" \
    '{iteration: ($iter|tonumber), scenario: $scenario, kind: $kind, duration_ms: $duration_ms,
      context_tokens: $context_tokens, input_tokens: $input_tokens, output_tokens: $output_tokens,
      cache_read_tokens: $cache_read_tokens, cache_write_tokens: $cache_write_tokens, cost_usd: $cost_usd}' \
    >>"$RESULTS_JSONL"

  LAST_SESSION_ID="$new_session"
  return 0
}

run_shunt_live_call() {
  local iter="$1" name="$2" question="$3"
  shift 3
  local paths=("$@")

  local rel_paths=()
  local p
  for p in "${paths[@]}"; do
    rel_paths+=("${p#"$REPO_ROOT"/}")
  done

  local prompt
  prompt="$question

Files (relative to the repo root): ${rel_paths[*]}

Answer by running: scripts/bulk-read --question \"<your question to it>\" --paths ${rel_paths[*]}
Use only that command via Bash to read these files. Do not read them with any other tool or command.
This command can take several minutes on large files. When you call it, set the Bash tool's timeout parameter to at least 600000 (10 minutes) so the call runs to completion instead of being moved to the background. Wait for it to finish and base your final answer only on what it returns."

  echo "[iter $iter/$ITERATIONS][$name] shunt-live (claude -p, real delegate call)..." >&2
  local live_json status
  live_json=$(mktemp)
  status=0
  timeout "$SHUNT_LIVE_TIMEOUT" claude -p --output-format json --model "$SHUNT_BASELINE_MODEL" \
    --tools "Bash" --allowedTools "Bash(scripts/bulk-read:*)" --permission-mode acceptEdits \
    "$prompt" >"$live_json" 2>/dev/null || status=$?

  if [ "$status" -ne 0 ] || [ ! -s "$live_json" ]; then
    echo "  shunt-live FAILED (exit $status)" >&2
    jq -n -c --arg iter "$iter" --arg scenario "$name" \
      '{iteration: ($iter|tonumber), scenario: $scenario, kind: "shunt-live", failed: true}' >>"$RESULTS_JSONL"
    rm -f "$live_json"
    any_failed=1
    return 1
  fi

  local in_tok out_tok cread cwrite cost ctx_tokens dur_ms
  dur_ms=$(jq -r '.duration_ms // 0' "$live_json")
  in_tok=$(jq -r '.usage.input_tokens // 0' "$live_json")
  out_tok=$(jq -r '.usage.output_tokens // 0' "$live_json")
  cread=$(jq -r '.usage.cache_read_input_tokens // 0' "$live_json")
  cwrite=$(jq -r '.usage.cache_creation_input_tokens // 0' "$live_json")
  cost=$(jq -r '.total_cost_usd // 0' "$live_json")
  ctx_tokens=$((in_tok + cread + cwrite))
  total_cost_usd=$(awk -v a="$total_cost_usd" -v b="$cost" 'BEGIN { printf "%.6f", a + b }')
  rm -f "$live_json"

  jq -n -c --arg iter "$iter" --arg scenario "$name" \
    --argjson duration_ms "$dur_ms" --argjson context_tokens "$ctx_tokens" \
    --argjson input_tokens "$in_tok" --argjson output_tokens "$out_tok" \
    --argjson cache_read_tokens "$cread" --argjson cache_write_tokens "$cwrite" \
    --argjson cost_usd "$cost" \
    '{iteration: ($iter|tonumber), scenario: $scenario, kind: "shunt-live", duration_ms: $duration_ms,
      context_tokens: $context_tokens, input_tokens: $input_tokens, output_tokens: $output_tokens,
      cache_read_tokens: $cache_read_tokens, cache_write_tokens: $cache_write_tokens, cost_usd: $cost_usd}' \
    >>"$RESULTS_JSONL"
}

run_shunt_call() {
  local iter="$1" name="$2" question="$3"
  shift 3
  local paths=("$@")

  echo "[iter $iter/$ITERATIONS][$name] shunt..." >&2
  local shunt_stderr shunt_start_ms shunt_end_ms shunt_ms shunt_response
  shunt_stderr=$(mktemp)
  shunt_start_ms=$(date +%s%3N)
  if shunt_response=$("$REPO_ROOT/scripts/bulk-read" --question "$question" --paths "${paths[@]}" 2>"$shunt_stderr"); then
    shunt_end_ms=$(date +%s%3N)
    shunt_ms=$((shunt_end_ms - shunt_start_ms))
    local ctx_tokens usage_line din dout
    ctx_tokens=$(( (${#shunt_response} + 3) / 4 ))
    usage_line=$(grep -o 'usage:.*' "$shunt_stderr" | sed 's/^usage: //')
    din=$(echo "$usage_line" | grep -o 'input=[0-9]*' | cut -d= -f2)
    dout=$(echo "$usage_line" | grep -o 'output=[0-9]*' | cut -d= -f2)
    jq -n -c --arg iter "$iter" --arg scenario "$name" \
      --argjson duration_ms "$shunt_ms" --argjson context_tokens "$ctx_tokens" \
      --argjson din "${din:-0}" --argjson dout "${dout:-0}" \
      '{iteration: ($iter|tonumber), scenario: $scenario, kind: "shunt", duration_ms: $duration_ms,
        context_tokens: $context_tokens, delegate_input_tokens: $din, delegate_output_tokens: $dout,
        cost_usd: null}' >>"$RESULTS_JSONL"
  else
    shunt_end_ms=$(date +%s%3N)
    shunt_ms=$((shunt_end_ms - shunt_start_ms))
    echo "  shunt FAILED after ${shunt_ms}ms" >&2
    jq -n -c --arg iter "$iter" --arg scenario "$name" --argjson duration_ms "$shunt_ms" \
      '{iteration: ($iter|tonumber), scenario: $scenario, kind: "shunt", duration_ms: $duration_ms, failed: true}' >>"$RESULTS_JSONL"
    any_failed=1
  fi
  rm -f "$shunt_stderr"
}

for ((it = 1; it <= ITERATIONS; it++)); do
  resume_session_id=""
  for ((i = 0; i < count; i++)); do
    name=$(jq -r ".benchmarks[$i].name" "$BENCHMARKS")
    question=$(jq -r ".benchmarks[$i].question" "$BENCHMARKS")
    paths=()
    while IFS= read -r p; do
      paths+=("$EVALS_DIR/$p")
    done < <(jq -r ".benchmarks[$i].paths[]" "$BENCHMARKS")
    prompt=$(scenario_prompt "$i")

    run_baseline_call "$it" "$name" "no-resume" "$prompt" ""

    run_baseline_call "$it" "$name" "resume" "$prompt" "$resume_session_id"
    if [ -n "$LAST_SESSION_ID" ]; then
      resume_session_id="$LAST_SESSION_ID"
    fi

    run_shunt_call "$it" "$name" "$question" "${paths[@]}"

    run_shunt_live_call "$it" "$name" "$question" "${paths[@]}"
  done
done

echo "" >&2
printf "Total real Claude API cost for this run: \$%s\n" "$total_cost_usd" >&2
[ "$any_failed" -eq 1 ] && echo "One or more calls failed; see failed:true rows in $RESULTS_JSONL." >&2

echo ""
python3 "$EVALS_DIR/aggregate-baseline-results.py" "$RESULTS_JSONL" "$SUMMARY_JSON"
