load 'test_helper'

# End-to-end tests for evals/mutation-check.sh with a stubbed `go`. The bats
# image has no real Go toolchain, so `go vet`/`go test` are replaced by a
# fake executable placed early on PATH; it records every call's subcommand
# and argv and replays a scripted exit code per call. evals/mutate-go.sh
# itself is exercised for real (pure bash/text, already covered by
# test/mutate-go.bats), only `go` needs stubbing here.

setup() {
  shunt_test_setup
  MC="$REPO_ROOT/evals/mutation-check.sh"

  STUB_DIR="$TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR/bin"
  export STUB_DIR
  write_stub_go
  export PATH="$STUB_DIR/bin:$PATH"

  GOTEST_DIR="$TEST_TMPDIR/gotest"
  mkdir -p "$GOTEST_DIR/runs/r1"
}

teardown() {
  shunt_test_teardown
}

# The stub: `go <vet|test> <args...>`. Records the call ("$sub $*") in
# $STUB_DIR/calls (one line per call, so `wc -l` gives the total call
# count) and the full argv (one arg per line) in
# $STUB_DIR/argv.<sub>.<n>. Exits with the code in $STUB_DIR/exit.<sub>.<n>,
# falling back to $STUB_DIR/exit.<sub>.default, falling back to 0.
write_stub_go() {
  cat >"$STUB_DIR/bin/go" <<'FAKE'
#!/bin/bash
sub="$1"; shift
n=$(( $(cat "$STUB_DIR/${sub}_count" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$STUB_DIR/${sub}_count"
echo "$sub $*" >>"$STUB_DIR/calls"
printf '%s\n' "$@" >"$STUB_DIR/argv.$sub.$n"
code_file="$STUB_DIR/exit.$sub.$n"
[ -f "$code_file" ] || code_file="$STUB_DIR/exit.$sub.default"
code=0
[ -f "$code_file" ] && code="$(cat "$code_file")"
exit "$code"
FAKE
  chmod +x "$STUB_DIR/bin/go"
}

# A 6-mutation-site fixture (cond-boundary, cond-negate, arith-op and three
# int-literal sites), matching the multi-site example in test/mutate-go.bats.
write_multi_go() {
  printf '%s' $'package p\n\nfunc F(n int) int {\n\tif n >= 10 {\n\t\treturn 1\n\t}\n\tx := n + 2\n\treturn x\n}\n' >"$1"
}

# A source with zero mutation sites: the only non-trivial line contains a
# double-quoted string, which the global skip rule excludes from every
# operator.
write_nosite_go() {
  printf '%s' $'package p\n\nfunc F() string {\n\treturn ""\n}\n' >"$1"
}

# run_mc <args...>: runs mutation-check.sh, capturing stdout and stderr into
# separate files ($TEST_TMPDIR/mc.out, $TEST_TMPDIR/mc.err) so JSON-on-stdout
# and human progress-on-stderr can be asserted independently. Intended to be
# wrapped in `run`, which then captures its own (empty) output and exit code.
run_mc() {
  "$MC" "$@" >"$TEST_TMPDIR/mc.out" 2>"$TEST_TMPDIR/mc.err"
}

mc_out() {
  cat "$TEST_TMPDIR/mc.out" 2>/dev/null
}

mc_err() {
  cat "$TEST_TMPDIR/mc.err" 2>/dev/null
}

stub_call_count() {
  wc -l <"$STUB_DIR/calls" 2>/dev/null || echo 0
}

# ---- ok path: mutants killed / survived -------------------------------

@test "all mutants are killed when go test always fails and go vet always passes" {
  write_multi_go "$GOTEST_DIR/runs/r1/f.go"
  export MUTANTS_MAX=6
  echo 1 >"$STUB_DIR/exit.test.default"

  run run_mc "$GOTEST_DIR" r1 f.go
  assert_success

  local json
  json="$(mc_out)"
  [ "$(wc -l <"$TEST_TMPDIR/mc.out")" = "1" ]
  echo "$json" | jq -e . >/dev/null

  [ "$(echo "$json" | jq -r .mutation_status)" = "ok" ]
  local total
  total="$(echo "$json" | jq -r .mutants_total)"
  [ "$total" = "6" ]
  [ "$(echo "$json" | jq -r .mutants_killed)" = "6" ]
  [ "$(echo "$json" | jq -r .mutants_survived)" = "0" ]
  [ "$(echo "$json" | jq -r .mutants_invalid)" = "0" ]
  [ "$(echo "$json" | jq -c .mutants_survived_ids)" = "[]" ]
}

@test "all mutants survive when go test always passes (vacuous-test signal)" {
  write_multi_go "$GOTEST_DIR/runs/r1/f.go"
  export MUTANTS_MAX=6
  echo 0 >"$STUB_DIR/exit.test.default"

  run run_mc "$GOTEST_DIR" r1 f.go
  assert_success

  local json
  json="$(mc_out)"
  local total
  total="$(echo "$json" | jq -r .mutants_total)"
  [ "$total" = "6" ]
  [ "$(echo "$json" | jq -r .mutants_killed)" = "0" ]
  [ "$(echo "$json" | jq -r .mutants_survived)" = "$total" ]
  [ "$(echo "$json" | jq -r '.mutants_survived_ids | length')" = "$total" ]
}

@test "a mutant whose go vet fails is counted as invalid and excluded from mutants_total" {
  write_multi_go "$GOTEST_DIR/runs/r1/f.go"
  export MUTANTS_MAX=6
  echo 1 >"$STUB_DIR/exit.vet.3"
  echo 1 >"$STUB_DIR/exit.test.default"

  run run_mc "$GOTEST_DIR" r1 f.go
  assert_success

  local json
  json="$(mc_out)"
  [ "$(echo "$json" | jq -r .mutants_invalid)" = "1" ]
  [ "$(echo "$json" | jq -r .mutants_total)" = "5" ]
}

# ---- skipped path -------------------------------------------------------

@test "a source with zero mutation sites yields status skipped and never invokes go" {
  write_nosite_go "$GOTEST_DIR/runs/r1/f.go"

  run run_mc "$GOTEST_DIR" r1 f.go
  assert_success

  local json
  json="$(mc_out)"
  [ "$(echo "$json" | jq -r .mutation_status)" = "skipped" ]
  [ "$(echo "$json" | jq -r .mutants_total)" = "0" ]
  [ "$(echo "$json" | jq -r .mutants_killed)" = "0" ]
  [ "$(echo "$json" | jq -r .mutants_survived)" = "0" ]
  [ "$(echo "$json" | jq -r .mutants_invalid)" = "0" ]
  [ "$(echo "$json" | jq -c .mutants_survived_ids)" = "[]" ]
  [ ! -f "$STUB_DIR/calls" ]
}

# ---- JSON contract -------------------------------------------------------

@test "every documented key is present with the correct JSON type in the ok path" {
  write_multi_go "$GOTEST_DIR/runs/r1/f.go"
  export MUTANTS_MAX=6
  echo 1 >"$STUB_DIR/exit.test.default"

  run run_mc "$GOTEST_DIR" r1 f.go
  assert_success

  echo "$(mc_out)" | jq -e '
    (.mutation_status == "ok") and
    (.mutants_total | type) == "number" and
    (.mutants_killed | type) == "number" and
    (.mutants_survived | type) == "number" and
    (.mutants_invalid | type) == "number" and
    (.mutants_survived_ids | type) == "array" and
    (.mutation_duration_ms | type) == "number"
  ' >/dev/null
}

@test "every documented key is present with the correct JSON type in the skipped path" {
  write_nosite_go "$GOTEST_DIR/runs/r1/f.go"

  run run_mc "$GOTEST_DIR" r1 f.go
  assert_success

  echo "$(mc_out)" | jq -e '
    (.mutation_status == "skipped") and
    (.mutants_total | type) == "number" and
    (.mutants_killed | type) == "number" and
    (.mutants_survived | type) == "number" and
    (.mutants_invalid | type) == "number" and
    (.mutants_survived_ids | type) == "array" and
    (.mutation_duration_ms | type) == "number"
  ' >/dev/null
}

# ---- isolation -----------------------------------------------------------

@test "mutant run directories are removed after a run" {
  write_multi_go "$GOTEST_DIR/runs/r1/f.go"
  export MUTANTS_MAX=3
  echo 1 >"$STUB_DIR/exit.test.default"

  run run_mc "$GOTEST_DIR" r1 f.go
  assert_success

  local leftover
  leftover="$(find "$GOTEST_DIR/runs" -maxdepth 1 -name 'r1-mut-*' | wc -l)"
  [ "$leftover" = "0" ]
}

@test "KEEP_MUTANTS=1 preserves mutant directories with mutated source and untouched test copy" {
  local run_dir="$GOTEST_DIR/runs/r1"
  write_multi_go "$run_dir/f.go"
  printf 'package p\n' >"$run_dir/f_test.go"
  export MUTANTS_MAX=2
  export KEEP_MUTANTS=1
  echo 1 >"$STUB_DIR/exit.test.default"

  run run_mc "$GOTEST_DIR" r1 f.go
  assert_success

  [ -d "$GOTEST_DIR/runs/r1-mut-1" ]
  [ -d "$GOTEST_DIR/runs/r1-mut-2" ]
  [ -f "$GOTEST_DIR/runs/r1-mut-1/f.go" ]
  [ -f "$GOTEST_DIR/runs/r1-mut-1/f_test.go" ]
  diff -q "$run_dir/f_test.go" "$GOTEST_DIR/runs/r1-mut-1/f_test.go"
  ! diff -q "$run_dir/f.go" "$GOTEST_DIR/runs/r1-mut-1/f.go" >/dev/null 2>&1
}

# ---- bad usage -------------------------------------------------------

@test "wrong arg count exits 2 with a one-line stderr message and no stdout" {
  run run_mc "$GOTEST_DIR"
  [ "$status" = "2" ]
  [ -z "$(mc_out)" ]
  [ "$(mc_err | wc -l)" = "1" ]
}

@test "a missing gotest-dir exits 2 with a one-line stderr message and no stdout" {
  run run_mc "$GOTEST_DIR/does-not-exist" r1 f.go
  [ "$status" = "2" ]
  [ -z "$(mc_out)" ]
  [ "$(mc_err | wc -l)" = "1" ]
}

@test "a missing runs/<run-dir-name> exits 2 with a one-line stderr message and no stdout" {
  run run_mc "$GOTEST_DIR" no-such-run f.go
  [ "$status" = "2" ]
  [ -z "$(mc_out)" ]
  [ "$(mc_err | wc -l)" = "1" ]
}

@test "a missing source-basename exits 2 with a one-line stderr message and no stdout" {
  write_multi_go "$GOTEST_DIR/runs/r1/f.go"
  run run_mc "$GOTEST_DIR" r1 missing.go
  [ "$status" = "2" ]
  [ -z "$(mc_out)" ]
  [ "$(mc_err | wc -l)" = "1" ]
}

# ---- env vars -------------------------------------------------------

@test "MUTANTS_MAX limits how many mutants are tried" {
  write_multi_go "$GOTEST_DIR/runs/r1/f.go"
  export MUTANTS_MAX=2
  echo 1 >"$STUB_DIR/exit.test.default"

  run run_mc "$GOTEST_DIR" r1 f.go
  assert_success

  [ "$(echo "$(mc_out)" | jq -r .mutants_total)" = "2" ]
  [ "$(stub_call_count)" = "4" ]
}

@test "MUTANT_TIMEOUT is passed through to go test as -timeout" {
  write_multi_go "$GOTEST_DIR/runs/r1/f.go"
  export MUTANTS_MAX=1
  export MUTANT_TIMEOUT=5s
  echo 1 >"$STUB_DIR/exit.test.default"

  run run_mc "$GOTEST_DIR" r1 f.go
  assert_success

  grep -qx -- '-timeout' "$STUB_DIR/argv.test.1"
  grep -qx '5s' "$STUB_DIR/argv.test.1"
}
