#!/bin/bash
# Live eval: does scripts/code-write (delegating the content of a brand-new
# file to a cheaper OpenCode-routed model) produce Go tests that compile and
# pass, and how much does it actually save on Claude's own token/cost/latency
# versus Claude writing the same test itself?
#
# evals/baseline-benchmark.sh measures the READ side (scripts/bulk-read versus
# Claude reading directly). This script measures the WRITE side:
# scripts/code-write versus Claude writing a brand-new Go test file directly,
# for two scenarios against curated excerpts of the real
# github.com/labstack/echo/v5 v5.3.1 module in evals/fixtures/echo/ (see
# evals/fixtures/echo/NOTICE.md).
#
#   direct  A real `claude -p` call, prompted with the source file content
#           inlined, asked to write a complete external Go test file.
#           Represents the no-delegation cost/latency baseline. Hits the
#           real Claude API and spends real money (see cost_usd per row and
#           the total printed at the end) - run deliberately, not in a loop.
#   shunt   The same request delegated to scripts/code-write (OpenCode), no
#           direct API cost to Claude. Its declared outcome (created,
#           declined, failed) is recorded as-is; declined/failed are not
#           script errors, only created proceeds to compile/test.
#
# Compile/pass-rate check, and WHY it needs its own Go module: the local
# evals/fixtures/echo/*.go files are curated EXCERPTS and do NOT compile
# standalone (see the fixture NOTICE.md; cors.go/cors_test.go are
# `package middleware` while echo.go/context.go/router.go/group.go are
# `package echo`, and each package is missing many sibling files from the
# real repo). Generated tests are therefore built as EXTERNAL test packages
# (package echo_test / package middleware_test) against the REAL published
# module, via the small Go module in evals/gotest/ (go.mod pins
# github.com/labstack/echo/v5 v5.3.1; go.mod/go.sum are committed so this
# needs network only the first time the module cache is populated). Each
# run's generated file lands in its own directory under evals/gotest/runs/
# (gitignored) so parallel scenarios/kinds never collide on package name or
# on duplicate Test... function names in one build.
#
# Mutation-testing (do the generated tests actually fail on a mechanically
# mutated implementation, not just compile and pass vacuously) is explicitly
# OUT OF SCOPE for this script - see docs/TODO.md's "Follow-up phase, not in
# this plan: live eval" section for that deferred follow-up and its own
# design pass.
#
# Requires a reachable OpenCode provider (for the shunt side) and a logged-in
# `claude` CLI (for the direct side). NOT part of the no-network evals/run.sh
# suite.
#
# Usage: evals/live-eval-benchmark.sh
#
# Env:
#   ITERATIONS              Repeats per scenario/kind (default: 1). Total real
#                            claude -p calls = ITERATIONS * 2 scenarios (direct
#                            only - shunt has no Claude-side API cost). Keep
#                            this modest, no retry on a failed iteration.
#   SHUNT_BASELINE_MODEL     Model alias for `claude -p --model` (default: sonnet).
#   SHUNT_BASELINE_TIMEOUT   Timeout in seconds per claude -p call (default: 300).
#   LIVE_EVAL_KINDS          Space-separated subset of "direct shunt" to run
#                            (default: "direct shunt"). Set to "shunt" to
#                            exercise only the no-cost delegated path, e.g.
#                            when validating the harness itself without
#                            spending real API money.

set -uo pipefail

EVALS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$EVALS_DIR/.." && pwd)"
GOTEST_DIR="$EVALS_DIR/gotest"
RESULTS_DIR="$EVALS_DIR/results"
RESULTS_JSONL="$RESULTS_DIR/live-eval-benchmark.jsonl"
SUMMARY_JSON="$RESULTS_DIR/live-eval-benchmark-summary.json"

SHUNT_BASELINE_MODEL="${SHUNT_BASELINE_MODEL:-sonnet}"
SHUNT_BASELINE_TIMEOUT="${SHUNT_BASELINE_TIMEOUT:-300}"
ITERATIONS="${ITERATIONS:-1}"
LIVE_EVAL_KINDS="${LIVE_EVAL_KINDS:-direct shunt}"

case " $LIVE_EVAL_KINDS " in
  *" direct "*) command -v claude >/dev/null 2>&1 || { echo "live-eval-benchmark: 'claude' not found in PATH." >&2; exit 1; } ;;
esac
command -v jq >/dev/null 2>&1 || { echo "live-eval-benchmark: 'jq' not found in PATH." >&2; exit 1; }
command -v go >/dev/null 2>&1 || { echo "live-eval-benchmark: 'go' not found in PATH." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "live-eval-benchmark: 'python3' not found in PATH (needed for aggregation)." >&2; exit 1; }

# shellcheck source=../scripts/lib/opencode.sh
source "$REPO_ROOT/scripts/lib/opencode.sh"
case " $LIVE_EVAL_KINDS " in *" shunt "*) shunt_preflight ;; esac

mkdir -p "$RESULTS_DIR" "$GOTEST_DIR/runs"
: > "$RESULTS_JSONL"

SCENARIOS=(cors router)
total_cost_usd="0"
any_failed=0

scenario_source_rel() {
  case "$1" in
    cors) echo "evals/fixtures/echo/cors.go" ;;
    router) echo "evals/fixtures/echo/router.go" ;;
    *) echo "live-eval-benchmark: unknown scenario: $1" >&2; exit 1 ;;
  esac
}

scenario_pkg() {
  case "$1" in
    cors) echo "middleware" ;;
    router) echo "echo" ;;
    *) echo "live-eval-benchmark: unknown scenario: $1" >&2; exit 1 ;;
  esac
}

scenario_import() {
  case "$1" in
    cors) echo "github.com/labstack/echo/v5/middleware" ;;
    router) echo "github.com/labstack/echo/v5" ;;
    *) echo "live-eval-benchmark: unknown scenario: $1" >&2; exit 1 ;;
  esac
}

# scenario_instruction <scenario> <pkg> <import>
# Shared instruction text for both the direct prompt and the shunt --spec.
scenario_instruction() {
  local scenario="$1" pkg="$2" import="$3"
  cat <<EOF
Write a complete Go external test file for package $pkg, to be saved as
"${scenario}_test.go". The file's package declaration must be exactly
"package ${pkg}_test" (an external test package), and it must import the
real published module path "$import" (do not use a local or relative
import, and do not redeclare any type from that package). Cover the
exported API of the source file with table-driven and/or direct test
functions using the standard "testing" package.
Output ONLY raw Go source code. Do not wrap it in markdown code fences
(no triple backticks), and do not add any explanation, commentary, or
notes before or after the code.
EOF
}

# strip_code_fence <file>
# Defensive cleanup for the direct variant: Claude sometimes fences code
# despite being told not to. Only strips a fence line that is the very
# first or very last line, never one that happens to appear mid-file.
strip_code_fence() {
  local file="$1" tmp
  tmp=$(mktemp)
  awk 'NR==1 && /^```/ {next} {print}' "$file" >"$tmp"
  mv "$tmp" "$file"
  tmp=$(mktemp)
  awk '{lines[NR]=$0} END {n=NR; if (n>0 && lines[n] ~ /^```[[:space:]]*$/) n--; for (i=1;i<=n;i++) print lines[i]}' "$file" >"$tmp"
  mv "$tmp" "$file"
}

# compile_and_test <run-dir-name-under-evals/gotest/runs>
# Sets globals BUILD_OK (JSON true/false), TESTS_TOTAL/TESTS_PASSED/
# TESTS_FAILED/TEST_DURATION_MS (JSON numbers, or "null" when build failed).
compile_and_test() {
  local run_dir="$1"
  BUILD_OK="false"
  TESTS_TOTAL="null"; TESTS_PASSED="null"; TESTS_FAILED="null"; TEST_DURATION_MS="null"

  if ! (cd "$GOTEST_DIR" && go vet "./runs/$run_dir/...") >/dev/null 2>&1; then
    return
  fi
  BUILD_OK="true"

  local test_json t_start t_end passed failed
  test_json=$(mktemp)
  t_start=$(date +%s%3N)
  (cd "$GOTEST_DIR" && go test -json "./runs/$run_dir/...") >"$test_json" 2>/dev/null
  t_end=$(date +%s%3N)
  TEST_DURATION_MS=$((t_end - t_start))

  passed=$(jq -s '[.[] | select(.Test != null and .Action=="pass")] | length' "$test_json")
  failed=$(jq -s '[.[] | select(.Test != null and .Action=="fail")] | length' "$test_json")
  rm -f "$test_json"
  TESTS_PASSED="$passed"
  TESTS_FAILED="$failed"
  TESTS_TOTAL=$((passed + failed))
}

# record_result <iter> <scenario> <kind> <outcome> <run-dir> <gen-duration-ms>
#   <input-tok|null> <output-tok|null> <cache-read|null> <cache-write|null>
#   <cost-usd|null> <delegate-input|null> <delegate-output|null>
# Every numeric arg must already be a valid JSON literal (a number or the
# string "null"), never an empty string.
record_result() {
  local iter="$1" scenario="$2" kind="$3" outcome="$4" run_dir="$5" dur_ms="$6"
  local in_tok="$7" out_tok="$8" cread="$9" cwrite="${10}" cost="${11}" din="${12}" dout="${13}"

  local build_ok="null" tests_total="null" tests_passed="null" tests_failed="null" test_dur="null"
  if [ "$outcome" = "created" ]; then
    compile_and_test "$run_dir"
    build_ok="$BUILD_OK"
    tests_total="$TESTS_TOTAL"
    tests_passed="$TESTS_PASSED"
    tests_failed="$TESTS_FAILED"
    test_dur="$TEST_DURATION_MS"
  fi

  jq -n -c \
    --arg scenario "$scenario" --arg kind "$kind" --arg outcome "$outcome" \
    --argjson iter "$iter" --argjson duration_ms "$dur_ms" \
    --argjson input_tokens "$in_tok" --argjson output_tokens "$out_tok" \
    --argjson cache_read_tokens "$cread" --argjson cache_write_tokens "$cwrite" \
    --argjson cost_usd "$cost" \
    --argjson delegate_input_tokens "$din" --argjson delegate_output_tokens "$dout" \
    --argjson build_ok "$build_ok" --argjson tests_total "$tests_total" \
    --argjson tests_passed "$tests_passed" --argjson tests_failed "$tests_failed" \
    --argjson test_duration_ms "$test_dur" \
    '{iteration: $iter, scenario: $scenario, kind: $kind, outcome: $outcome,
      duration_ms: $duration_ms, input_tokens: $input_tokens, output_tokens: $output_tokens,
      cache_read_tokens: $cache_read_tokens, cache_write_tokens: $cache_write_tokens,
      cost_usd: $cost_usd, delegate_input_tokens: $delegate_input_tokens,
      delegate_output_tokens: $delegate_output_tokens, build_ok: $build_ok,
      tests_total: $tests_total, tests_passed: $tests_passed, tests_failed: $tests_failed,
      test_duration_ms: $test_duration_ms}' >>"$RESULTS_JSONL"
}

run_direct_call() {
  local iter="$1" scenario="$2"
  local source_rel pkg import instruction prompt run_dir target_dir target_file

  source_rel=$(scenario_source_rel "$scenario") || exit 1
  pkg=$(scenario_pkg "$scenario") || exit 1
  import=$(scenario_import "$scenario") || exit 1
  instruction=$(scenario_instruction "$scenario" "$pkg" "$import")
  prompt="=== $source_rel ===
$(cat "$REPO_ROOT/$source_rel")

$instruction"

  run_dir="$scenario-direct-$iter"
  target_dir="$GOTEST_DIR/runs/$run_dir"
  target_file="$target_dir/${scenario}_test.go"

  echo "[iter $iter/$ITERATIONS][$scenario] direct (claude -p)..." >&2
  local out_json status
  out_json=$(mktemp)
  status=0
  timeout "$SHUNT_BASELINE_TIMEOUT" claude -p --output-format json --model "$SHUNT_BASELINE_MODEL" \
    "$prompt" >"$out_json" 2>/dev/null || status=$?

  local dur_ms=0 in_tok=0 out_tok=0 cread=0 cwrite=0 cost=0 outcome="failed" result

  if [ "$status" -ne 0 ] || [ ! -s "$out_json" ]; then
    echo "  direct FAILED (exit $status)" >&2
    any_failed=1
    rm -f "$out_json"
    record_result "$iter" "$scenario" "direct" "failed" "$run_dir" 0 0 0 0 0 0 null null
    return
  fi

  dur_ms=$(jq -r '.duration_ms // 0' "$out_json")
  in_tok=$(jq -r '.usage.input_tokens // 0' "$out_json")
  out_tok=$(jq -r '.usage.output_tokens // 0' "$out_json")
  cread=$(jq -r '.usage.cache_read_input_tokens // 0' "$out_json")
  cwrite=$(jq -r '.usage.cache_creation_input_tokens // 0' "$out_json")
  cost=$(jq -r '.total_cost_usd // 0' "$out_json")
  total_cost_usd=$(awk -v a="$total_cost_usd" -v b="$cost" 'BEGIN { printf "%.6f", a + b }')
  result=$(jq -r '.result // empty' "$out_json")
  rm -f "$out_json"

  if [ -z "$result" ]; then
    echo "  direct FAILED (empty result)" >&2
    any_failed=1
    record_result "$iter" "$scenario" "direct" "failed" "$run_dir" "$dur_ms" \
      "$in_tok" "$out_tok" "$cread" "$cwrite" "$cost" null null
    return
  fi

  mkdir -p "$target_dir"
  printf '%s\n' "$result" >"$target_file"
  strip_code_fence "$target_file"
  outcome="created"

  record_result "$iter" "$scenario" "direct" "$outcome" "$run_dir" "$dur_ms" \
    "$in_tok" "$out_tok" "$cread" "$cwrite" "$cost" null null
}

run_shunt_call() {
  local iter="$1" scenario="$2"
  local source_rel pkg import instruction run_dir target_file

  source_rel=$(scenario_source_rel "$scenario") || exit 1
  pkg=$(scenario_pkg "$scenario") || exit 1
  import=$(scenario_import "$scenario") || exit 1
  instruction=$(scenario_instruction "$scenario" "$pkg" "$import")

  run_dir="$scenario-shunt-$iter"
  target_file="$GOTEST_DIR/runs/$run_dir/${scenario}_test.go"

  echo "[iter $iter/$ITERATIONS][$scenario] shunt (code-write)..." >&2
  local shunt_stderr shunt_stdout shunt_start_ms shunt_end_ms shunt_ms status
  shunt_stderr=$(mktemp)
  shunt_stdout=$(mktemp)
  shunt_start_ms=$(date +%s%3N)
  status=0
  "$REPO_ROOT/scripts/code-write" --kind test --spec "$instruction" \
    --reference "$REPO_ROOT/evals/fixtures/echo/cors_test.go" \
    --source "$REPO_ROOT/$source_rel" \
    --target "$target_file" >"$shunt_stdout" 2>"$shunt_stderr" || status=$?
  shunt_end_ms=$(date +%s%3N)
  shunt_ms=$((shunt_end_ms - shunt_start_ms))

  local outcome
  case "$status" in
    0) outcome="created" ;;
    3) outcome="declined" ;;
    *) outcome="failed"; any_failed=1 ;;
  esac
  echo "  shunt $outcome after ${shunt_ms}ms" >&2

  local usage_line din dout
  usage_line=$(grep -o 'usage:.*' "$shunt_stderr" | sed 's/^usage: //')
  din=$(echo "$usage_line" | grep -o 'input=[0-9]*' | cut -d= -f2)
  dout=$(echo "$usage_line" | grep -o 'output=[0-9]*' | cut -d= -f2)
  rm -f "$shunt_stderr" "$shunt_stdout"

  record_result "$iter" "$scenario" "shunt" "$outcome" "$run_dir" "$shunt_ms" \
    null null null null null "${din:-null}" "${dout:-null}"
}

for ((it = 1; it <= ITERATIONS; it++)); do
  for scenario in "${SCENARIOS[@]}"; do
    case " $LIVE_EVAL_KINDS " in *" direct "*) run_direct_call "$it" "$scenario" ;; esac
    case " $LIVE_EVAL_KINDS " in *" shunt "*) run_shunt_call "$it" "$scenario" ;; esac
  done
done

echo "" >&2
printf "Total real Claude API cost for this run: \$%s\n" "$total_cost_usd" >&2
[ "$any_failed" -eq 1 ] && echo "One or more calls failed; see outcome:\"failed\" rows in $RESULTS_JSONL." >&2

echo ""
python3 "$EVALS_DIR/aggregate-live-eval-results.py" "$RESULTS_JSONL" "$SUMMARY_JSON"
