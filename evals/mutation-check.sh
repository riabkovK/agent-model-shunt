#!/bin/bash
# mutation-check.sh — drives evals/mutate-go.sh against a real Go toolchain
# to run a mutation-testing pass over one already-generated code-under-test
# file plus its already-passing generated test file.
#
# Usage 1 (used by the live-eval harness, sub-phase 4):
#   mutation-check.sh <gotest-dir> <run-dir-name> <source-basename>
#     <gotest-dir>        the Go module root (in real use, evals/gotest).
#     <run-dir-name>      a directory name under <gotest-dir>/runs/ that
#                          already contains the code-under-test file
#                          (<source-basename>) and a generated test file
#                          that already passed once. This script assumes
#                          that baseline-green precondition; it does not
#                          re-verify it.
#     <source-basename>   e.g. pricing.go.
#   Prints exactly one line of compact JSON to stdout (see schema below)
#   and free-form human progress to stderr. On bad arguments or missing
#   inputs, prints a one-line error to stderr and exits 2 with NO stdout
#   output at all.
#
#   Env vars (all optional):
#     MUTANTS_MAX     max number of mutants to try (default 5).
#     MUTANT_TIMEOUT  passed verbatim to `go test -timeout` (default 60s).
#     KEEP_MUTANTS    when "1", mutant run dirs are not removed afterwards
#                      (default unset: they are removed).
#
#   JSON schema (every key present on both "ok" and "skipped"):
#     {"mutation_status": "ok" | "skipped",
#      "mutants_total": <int>, "mutants_killed": <int>,
#      "mutants_survived": <int>, "mutants_invalid": <int>,
#      "mutants_survived_ids": [<string>, ...],
#      "mutation_duration_ms": <int>}
#
# Usage 2:
#   mutation-check.sh --self-test
#   Live-only: needs a real Go toolchain. Copies
#   evals/fixtures/mutation/{pricing.go,pricing_reference_test.go} into a
#   scratch run directory under evals/gotest/runs/, runs the full
#   algorithm above against it with a generous MUTANTS_MAX (so every site
#   is exercised, not just a handful), and additionally asserts
#   mutants_survived == 0 (the reference suite is documented to kill every
#   non-equivalent mutant, see evals/fixtures/mutation/README.md). Prints
#   PASS/FAIL to stderr and exits 0/1. Cleans up its scratch dir either way.

set -uo pipefail

_MC_USAGE='mutation-check: usage: mutation-check.sh <gotest-dir> <run-dir-name> <source-basename> | --self-test'

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MUTATE_GO="$_SCRIPT_DIR/mutate-go.sh"

_mc_die() {
  echo "mutation-check: $1" >&2
  exit "${2:-2}"
}

_mc_now_ms() {
  date +%s%3N
}

# _mc_emit_skipped: prints the "skipped" JSON object on stdout.
_mc_emit_skipped() {
  local duration_ms="$1"
  jq -n -c --argjson duration_ms "$duration_ms" \
    '{mutation_status: "skipped", mutants_total: 0, mutants_killed: 0,
      mutants_survived: 0, mutants_invalid: 0, mutants_survived_ids: [],
      mutation_duration_ms: $duration_ms}'
}

# _mc_emit_ok <total> <killed> <survived> <invalid> <duration_ms> <id>...
_mc_emit_ok() {
  local total="$1" killed="$2" survived="$3" invalid="$4" duration_ms="$5"
  shift 5
  jq -n -c \
    --argjson total "$total" --argjson killed "$killed" \
    --argjson survived "$survived" --argjson invalid "$invalid" \
    --argjson duration_ms "$duration_ms" \
    --args '{mutation_status: "ok", mutants_total: $total,
      mutants_killed: $killed, mutants_survived: $survived,
      mutants_invalid: $invalid, mutants_survived_ids: $ARGS.positional,
      mutation_duration_ms: $duration_ms}' "$@"
}

# _mc_run <gotest-dir> <run-dir-name> <source-basename>
# Runs the full algorithm and prints the resulting JSON object on stdout.
# Assumes arguments were already validated by the caller.
_mc_run() {
  local gotest_dir="$1" run_dir_name="$2" source_basename="$3"
  local start_ms
  start_ms="$(_mc_now_ms)"

  local src_dir="$gotest_dir/runs/$run_dir_name"
  local src_file="$src_dir/$source_basename"

  local ids
  ids="$("$_MUTATE_GO" --select "${MUTANTS_MAX:-5}" "$src_file")" \
    || _mc_die "mutate-go.sh --select failed on $src_file" 1
  if [ -z "$ids" ]; then
    echo "mutation-check: no mutation sites found in $src_file, skipping" >&2
    _mc_emit_skipped "$(( $(_mc_now_ms) - start_ms ))"
    return 0
  fi

  local total=0 killed=0 survived=0 invalid=0
  local survived_ids=()
  local n=0
  local id
  while IFS= read -r id; do
    n=$((n + 1))
    local mut_dir="$gotest_dir/runs/${run_dir_name}-mut-${n}"
    rm -rf "$mut_dir"
    mkdir -p "$mut_dir"

    local f
    for f in "$src_dir"/*.go; do
      cp "$f" "$mut_dir/"
    done

    rm -f "$mut_dir/$source_basename"
    if ! "$_MUTATE_GO" --apply "$id" "$src_file" "$mut_dir/$source_basename" >&2; then
      echo "mutation-check: mutant $id: apply failed, treating as invalid" >&2
      invalid=$((invalid + 1))
      [ "${KEEP_MUTANTS:-0}" = "1" ] || rm -rf "$mut_dir"
      continue
    fi

    if ! (cd "$gotest_dir" && go vet "./runs/${run_dir_name}-mut-${n}/...") >&2; then
      echo "mutation-check: mutant $id: go vet failed, invalid mutant" >&2
      invalid=$((invalid + 1))
      [ "${KEEP_MUTANTS:-0}" = "1" ] || rm -rf "$mut_dir"
      continue
    fi

    total=$((total + 1))
    if (cd "$gotest_dir" && go test -count=1 -timeout "${MUTANT_TIMEOUT:-60s}" "./runs/${run_dir_name}-mut-${n}/...") >&2; then
      echo "mutation-check: mutant $id: SURVIVED" >&2
      survived=$((survived + 1))
      survived_ids+=("$id")
    else
      echo "mutation-check: mutant $id: killed" >&2
      killed=$((killed + 1))
    fi

    [ "${KEEP_MUTANTS:-0}" = "1" ] || rm -rf "$mut_dir"
  done <<<"$ids"

  local duration_ms=$(( $(_mc_now_ms) - start_ms ))
  _mc_emit_ok "$total" "$killed" "$survived" "$invalid" "$duration_ms" "${survived_ids[@]}"
}

# _mc_validate <gotest-dir> <run-dir-name> <source-basename>: exits 2 with a
# stderr message on any problem, otherwise returns 0.
_mc_validate() {
  local gotest_dir="$1" run_dir_name="$2" source_basename="$3"
  case "$run_dir_name" in
    */* | . | ..) _mc_die "run-dir-name must be a plain directory name, not a path: $run_dir_name" ;;
  esac
  case "$source_basename" in
    */* | . | ..) _mc_die "source-basename must be a plain file name, not a path: $source_basename" ;;
  esac
  [ -d "$gotest_dir" ] || _mc_die "gotest dir not found: $gotest_dir"
  [ -d "$gotest_dir/runs/$run_dir_name" ] || _mc_die "run dir not found: $gotest_dir/runs/$run_dir_name"
  [ -f "$gotest_dir/runs/$run_dir_name/$source_basename" ] \
    || _mc_die "source file not found: $gotest_dir/runs/$run_dir_name/$source_basename"
}

_mc_self_test() {
  local fixtures_dir="$_SCRIPT_DIR/fixtures/mutation"
  local gotest_dir="$_SCRIPT_DIR/gotest"
  local run_dir_name="selftest-mutation"
  local run_dir="$gotest_dir/runs/$run_dir_name"

  [ -f "$fixtures_dir/pricing.go" ] || _mc_die "fixture not found: $fixtures_dir/pricing.go" 1
  [ -f "$fixtures_dir/pricing_reference_test.go" ] || _mc_die "fixture not found: $fixtures_dir/pricing_reference_test.go" 1
  [ -d "$gotest_dir" ] || _mc_die "gotest module root not found: $gotest_dir" 1

  rm -rf "$run_dir"
  mkdir -p "$run_dir"
  cp "$fixtures_dir/pricing.go" "$fixtures_dir/pricing_reference_test.go" "$run_dir/"

  local result
  result="$(MUTANTS_MAX="${MUTANTS_MAX:-50}" _mc_run "$gotest_dir" "$run_dir_name" "pricing.go")"
  local rc=$?
  rm -rf "$run_dir"

  if [ "$rc" -ne 0 ]; then
    echo "mutation-check --self-test: FAIL (runner exited $rc)" >&2
    return 1
  fi

  echo "$result"

  local survived
  survived="$(echo "$result" | jq -r '.mutants_survived')"
  if [ "$survived" != "0" ]; then
    echo "mutation-check --self-test: FAIL ($survived mutant(s) survived)" >&2
    echo "$result" | jq -r '.mutants_survived_ids[]' | sed 's/^/  survived: /' >&2
    return 1
  fi

  local total
  total="$(echo "$result" | jq -r '.mutants_total')"
  echo "mutation-check --self-test: PASS (mutants_total=$total, mutants_killed=$total, mutants_survived=0)" >&2
  return 0
}

main() {
  if [ "${1:-}" = "--self-test" ]; then
    _mc_self_test
    exit $?
  fi

  [ $# -eq 3 ] || _mc_die "$_MC_USAGE"
  _mc_validate "$1" "$2" "$3"
  _mc_run "$1" "$2" "$3"
}

main "$@"
