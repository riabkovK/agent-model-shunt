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
#           Runs with `--tools ""` (no tool access at all): the instruction
#           text says the file is "to be saved as ...", which an agentic
#           Claude with tool access and this repo's own CLAUDE.md loaded can
#           read as a real file-write request against a path that might
#           collide with a committed fixture, and decline/ask a clarifying
#           question instead of answering - wasted since `-p` mode can't
#           relay the question back. `--tools ""` forces pure text
#           completion so the only possible outputs are code or a refusal in
#           `.result`, never a stuck tool-permission prompt.
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
# A third scenario, `pricing`, runs LOCAL (not module) mode: it is a small,
# dependency-free fixture (evals/fixtures/mutation/pricing.go, see that
# directory's README.md) copied as-is into the run directory rather than
# generated against a real published module, and the generated test lives
# in the SAME package (package pricing), not an external _test package.
# `pricing` also drives mutation testing: after its generated test compiles
# and passes against the unmodified fixture (a green baseline), evals/
# mutation-check.sh mechanically mutates the fixture a few times and reruns
# the generated test against each mutant, recording how many mutants it
# kills versus lets survive - a signal that the test asserts real behavior
# rather than just existing. See evals/mutation-check.sh's own header for
# the exact algorithm and JSON schema; its 7 fields land at the top level
# of every result row (mutation_status/mutants_total/mutants_killed/
# mutants_survived/mutants_invalid/mutants_survived_ids/
# mutation_duration_ms), with mutation_status "n/a" for the non-mutation
# cors/router scenarios, "skipped" when pricing's own baseline wasn't green
# or mutation testing was disabled, "error" if mutation-check.sh itself
# failed, and "ok" for a real result.
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
#   LIVE_EVAL_SCENARIOS      Space-separated subset of "cors router pricing"
#                            to run (default: all three). Same filtering
#                            idiom as LIVE_EVAL_KINDS.
#   LIVE_EVAL_MUTATION       When "0", skips the mutation-check.sh call
#                            entirely for the pricing scenario (default: 1).
#                            Useful for a quick smoke run.
#   MUTANTS_MAX              Forwarded to evals/mutation-check.sh (its own
#                            default: 5). Max mutants tried per pricing run.
#   MUTANT_TIMEOUT           Forwarded to evals/mutation-check.sh (its own
#                            default: 60s). Per-mutant `go test -timeout`.

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
LIVE_EVAL_SCENARIOS="${LIVE_EVAL_SCENARIOS:-cors router pricing}"
LIVE_EVAL_MUTATION="${LIVE_EVAL_MUTATION:-1}"
# Not redefined here (mutation-check.sh has its own defaults) - only made
# visible to it, since it runs as a separate process invocation below.
[ -n "${MUTANTS_MAX:-}" ] && export MUTANTS_MAX
[ -n "${MUTANT_TIMEOUT:-}" ] && export MUTANT_TIMEOUT

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

SCENARIOS=(cors router pricing)
total_cost_usd="0"
any_failed=0

# Globals compile_and_test fills in per call; initialized here (mirroring
# compile_and_test's own first lines) so maybe_run_mutation_check can safely
# read them under `set -u` even before compile_and_test has run once.
BUILD_OK="false"
TESTS_TOTAL="null"; TESTS_PASSED="null"; TESTS_FAILED="null"; TEST_DURATION_MS="null"
# Global set by maybe_run_mutation_check for record_result to consume.
mutation_json=""

scenario_source_rel() {
  case "$1" in
    cors) echo "evals/fixtures/echo/cors.go" ;;
    router) echo "evals/fixtures/echo/router.go" ;;
    pricing) echo "evals/fixtures/mutation/pricing.go" ;;
    *) echo "live-eval-benchmark: unknown scenario: $1" >&2; exit 1 ;;
  esac
}

scenario_pkg() {
  case "$1" in
    cors) echo "middleware" ;;
    router) echo "echo" ;;
    pricing) echo "pricing" ;;
    *) echo "live-eval-benchmark: unknown scenario: $1" >&2; exit 1 ;;
  esac
}

scenario_import() {
  case "$1" in
    cors) echo "github.com/labstack/echo/v5/middleware" ;;
    router) echo "github.com/labstack/echo/v5" ;;
    pricing) echo "" ;;
    *) echo "live-eval-benchmark: unknown scenario: $1" >&2; exit 1 ;;
  esac
}

# scenario_mode <scenario>: "module" (generated as an external test package
# against a real published module, evals/fixtures/echo/*) or "local" (fixture
# copied as-is into the run dir, generated test in the SAME package, no
# third-party import - see evals/fixtures/mutation/README.md).
scenario_mode() {
  case "$1" in
    cors|router) echo "module" ;;
    pricing) echo "local" ;;
    *) echo "live-eval-benchmark: unknown scenario: $1" >&2; exit 1 ;;
  esac
}

# scenario_reference <scenario>: the --reference file passed to
# scripts/code-write for the shunt call.
scenario_reference() {
  case "$1" in
    cors|router) echo "evals/fixtures/echo/cors_test.go" ;;
    pricing) echo "evals/fixtures/mutation/pricing_reference_test.go" ;;
    *) echo "live-eval-benchmark: unknown scenario: $1" >&2; exit 1 ;;
  esac
}

# scenario_mutation <scenario>: "yes" if this scenario should drive
# evals/mutation-check.sh after a green baseline, empty otherwise.
scenario_mutation() {
  case "$1" in
    pricing) echo "yes" ;;
    *) echo "" ;;
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

# scenario_instruction_local <pkg>
# Instruction text for local-mode scenarios (see scenario_mode): the
# generated test lives in the SAME package as the fixture, not an external
# _test package, and must not import the fixture or a third-party module.
scenario_instruction_local() {
  local pkg="$1"
  cat <<EOF
Write a complete Go test file for package $pkg, to be saved as
"${pkg}_test.go". The file's package declaration must be exactly
"package ${pkg}" (the same package, not an external test package). The
file under test, "${pkg}.go", is in the same directory and the same
package - do not import it, and do not redeclare any of its exported
identifiers. Only the Go standard library may be imported. Cover the
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

# prepare_run_dir <scenario> <run-dir-name-under-evals/gotest/runs>
# Removes any stale run dir first (so scripts/code-write's no-clobber target
# check still sees a target that doesn't exist yet), then recreates it. For
# local-mode scenarios, also copies the fixture source in under its package
# name so it compiles alongside the generated test.
prepare_run_dir() {
  local scenario="$1" run_dir_name="$2"
  local run_dir="$GOTEST_DIR/runs/$run_dir_name"
  rm -rf "$run_dir"
  mkdir -p "$run_dir"
  if [ "$(scenario_mode "$scenario")" = "local" ]; then
    cp "$REPO_ROOT/$(scenario_source_rel "$scenario")" "$run_dir/$(scenario_pkg "$scenario").go"
  fi
}

# maybe_run_mutation_check <scenario> <run-dir-name> <outcome>
# Sets global mutation_json (a compact JSON object, see evals/mutation-check.sh
# header for the "ok"/"skipped" shape) to pass into record_result. Only
# actually invokes evals/mutation-check.sh when this scenario opts into
# mutation testing, it's enabled, and the baseline (this call's outcome plus
# compile_and_test's globals, already set by the caller) is green - a
# failing/vacuous baseline makes "kill count" meaningless.
maybe_run_mutation_check() {
  local scenario="$1" run_dir_name="$2" outcome="$3"

  if [ "$(scenario_mutation "$scenario")" != "yes" ]; then
    mutation_json=$(jq -n -c '{mutation_status: "n/a", mutants_total: null,
      mutants_killed: null, mutants_survived: null, mutants_invalid: null,
      mutants_survived_ids: null, mutation_duration_ms: null}')
    return
  fi

  local baseline_green=1
  [ "$LIVE_EVAL_MUTATION" != "0" ] || baseline_green=0
  [ "$outcome" = "created" ] || baseline_green=0
  [ "$BUILD_OK" = "true" ] || baseline_green=0
  [ "$TESTS_TOTAL" != "null" ] && [ "$TESTS_TOTAL" -gt 0 ] || baseline_green=0
  [ "$TESTS_FAILED" = "0" ] || baseline_green=0

  if [ "$baseline_green" -ne 1 ]; then
    mutation_json=$(jq -n -c '{mutation_status: "skipped", mutants_total: null,
      mutants_killed: null, mutants_survived: null, mutants_invalid: null,
      mutants_survived_ids: null, mutation_duration_ms: null}')
    return
  fi

  local mc_stdout
  mc_stdout=$(mktemp)
  if "$EVALS_DIR/mutation-check.sh" "$GOTEST_DIR" "$run_dir_name" "$(scenario_pkg "$scenario").go" >"$mc_stdout"; then
    mutation_json=$(cat "$mc_stdout")
  else
    mutation_json=$(jq -n -c '{mutation_status: "error", mutants_total: null,
      mutants_killed: null, mutants_survived: null, mutants_invalid: null,
      mutants_survived_ids: null, mutation_duration_ms: null}')
  fi
  rm -f "$mc_stdout"
}

# record_result <iter> <scenario> <kind> <outcome> <run-dir> <gen-duration-ms>
#   <input-tok|null> <output-tok|null> <cache-read|null> <cache-write|null>
#   <cost-usd|null> <delegate-input|null> <delegate-output|null>
#   <mutation-json>
# Every numeric arg must already be a valid JSON literal (a number or the
# string "null"), never an empty string. <mutation-json> is a full compact
# JSON object (see maybe_run_mutation_check) whose keys are merged into the
# row as-is. Callers must run compile_and_test (when outcome is "created")
# and maybe_run_mutation_check themselves before calling this, so BUILD_OK/
# TESTS_TOTAL/etc reflect the same call this row describes.
record_result() {
  local iter="$1" scenario="$2" kind="$3" outcome="$4" run_dir="$5" dur_ms="$6"
  local in_tok="$7" out_tok="$8" cread="$9" cwrite="${10}" cost="${11}" din="${12}" dout="${13}"
  local mutation_json="${14}"

  local build_ok="null" tests_total="null" tests_passed="null" tests_failed="null" test_dur="null"
  if [ "$outcome" = "created" ]; then
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
    --argjson mutation "$mutation_json" \
    '{iteration: $iter, scenario: $scenario, kind: $kind, outcome: $outcome,
      duration_ms: $duration_ms, input_tokens: $input_tokens, output_tokens: $output_tokens,
      cache_read_tokens: $cache_read_tokens, cache_write_tokens: $cache_write_tokens,
      cost_usd: $cost_usd, delegate_input_tokens: $delegate_input_tokens,
      delegate_output_tokens: $delegate_output_tokens, build_ok: $build_ok,
      tests_total: $tests_total, tests_passed: $tests_passed, tests_failed: $tests_failed,
      test_duration_ms: $test_duration_ms} + $mutation' >>"$RESULTS_JSONL"
}

run_direct_call() {
  local iter="$1" scenario="$2"
  local source_rel pkg import instruction prompt run_dir target_dir target_file

  source_rel=$(scenario_source_rel "$scenario") || exit 1
  pkg=$(scenario_pkg "$scenario") || exit 1
  import=$(scenario_import "$scenario") || exit 1
  if [ "$(scenario_mode "$scenario")" = "local" ]; then
    instruction=$(scenario_instruction_local "$pkg")
  else
    instruction=$(scenario_instruction "$scenario" "$pkg" "$import")
  fi
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
  timeout "$SHUNT_BASELINE_TIMEOUT" claude -p --safe-mode --output-format json --model "$SHUNT_BASELINE_MODEL" \
    --tools="" "$prompt" >"$out_json" 2>/dev/null || status=$?

  local dur_ms=0 in_tok=0 out_tok=0 cread=0 cwrite=0 cost=0 outcome="failed" result

  if [ "$status" -ne 0 ] || [ ! -s "$out_json" ]; then
    echo "  direct FAILED (exit $status)" >&2
    any_failed=1
    rm -f "$out_json"
    maybe_run_mutation_check "$scenario" "$run_dir" "failed"
    record_result "$iter" "$scenario" "direct" "failed" "$run_dir" 0 0 0 0 0 0 null null "$mutation_json"
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
    maybe_run_mutation_check "$scenario" "$run_dir" "failed"
    record_result "$iter" "$scenario" "direct" "failed" "$run_dir" "$dur_ms" \
      "$in_tok" "$out_tok" "$cread" "$cwrite" "$cost" null null "$mutation_json"
    return
  fi

  prepare_run_dir "$scenario" "$run_dir"
  printf '%s\n' "$result" >"$target_file"
  strip_code_fence "$target_file"
  outcome="created"

  compile_and_test "$run_dir"
  maybe_run_mutation_check "$scenario" "$run_dir" "$outcome"
  record_result "$iter" "$scenario" "direct" "$outcome" "$run_dir" "$dur_ms" \
    "$in_tok" "$out_tok" "$cread" "$cwrite" "$cost" null null "$mutation_json"
}

run_shunt_call() {
  local iter="$1" scenario="$2"
  local source_rel pkg import instruction run_dir target_file

  source_rel=$(scenario_source_rel "$scenario") || exit 1
  pkg=$(scenario_pkg "$scenario") || exit 1
  import=$(scenario_import "$scenario") || exit 1
  if [ "$(scenario_mode "$scenario")" = "local" ]; then
    instruction=$(scenario_instruction_local "$pkg")
  else
    instruction=$(scenario_instruction "$scenario" "$pkg" "$import")
  fi

  run_dir="$scenario-shunt-$iter"
  target_file="$GOTEST_DIR/runs/$run_dir/${scenario}_test.go"
  prepare_run_dir "$scenario" "$run_dir"

  echo "[iter $iter/$ITERATIONS][$scenario] shunt (code-write)..." >&2
  local shunt_stderr shunt_stdout shunt_start_ms shunt_end_ms shunt_ms status
  shunt_stderr=$(mktemp)
  shunt_stdout=$(mktemp)
  shunt_start_ms=$(date +%s%3N)
  status=0
  "$REPO_ROOT/scripts/code-write" --kind test --spec "$instruction" \
    --reference "$REPO_ROOT/$(scenario_reference "$scenario")" \
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

  if [ "$outcome" = "created" ]; then
    compile_and_test "$run_dir"
  fi
  maybe_run_mutation_check "$scenario" "$run_dir" "$outcome"

  record_result "$iter" "$scenario" "shunt" "$outcome" "$run_dir" "$shunt_ms" \
    null null null null null "${din:-null}" "${dout:-null}" "$mutation_json"
}

for ((it = 1; it <= ITERATIONS; it++)); do
  for scenario in "${SCENARIOS[@]}"; do
    case " $LIVE_EVAL_SCENARIOS " in *" $scenario "*) : ;; *) continue ;; esac
    case " $LIVE_EVAL_KINDS " in *" direct "*) run_direct_call "$it" "$scenario" ;; esac
    case " $LIVE_EVAL_KINDS " in *" shunt "*) run_shunt_call "$it" "$scenario" ;; esac
  done
done

echo "" >&2
printf "Total real Claude API cost for this run: \$%s\n" "$total_cost_usd" >&2
[ "$any_failed" -eq 1 ] && echo "One or more calls failed; see outcome:\"failed\" rows in $RESULTS_JSONL." >&2

echo ""
python3 "$EVALS_DIR/aggregate-live-eval-results.py" "$RESULTS_JSONL" "$SUMMARY_JSON"
