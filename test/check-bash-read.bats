load 'test_helper'
bats_require_minimum_version 1.5.0

# The Bash PreToolUse hook through the real launcher: stdin JSON in, one JSON line out, exit 0.

setup() {
  shunt_test_setup
}

teardown() {
  shunt_test_teardown
}

run_hook() {
  local command="$1"
  jq -n --arg c "$command" '{tool_input: {command: $c}}' | "$REPO_ROOT/hooks/check-bash-read"
}

@test "allows cat of a small file" {
  local f="$TEST_TMPDIR/small.txt"
  seq 1 10 >"$f"
  run run_hook "cat $f"
  assert_success
  assert_output --partial '"permissionDecision": "allow"'
}

@test "allows a command that is not a file read" {
  run run_hook "ls $TEST_TMPDIR"
  assert_success
  assert_output --partial '"permissionDecision": "allow"'
}

@test "denies cat of a large file and points at the bulk-reader skill" {
  local f="$TEST_TMPDIR/big.txt"
  seq 1 400 >"$f"
  run run_hook "cat $f"
  assert_success
  assert_output --partial '"permissionDecision": "deny"'
  assert_output --partial 'bulk-reader'
  echo "$output" | jq -e . >/dev/null
}

@test "an unusable interpreter allows the command: stdout JSON, exit 0, warning only on stderr" {
  local f="$TEST_TMPDIR/big.txt"
  seq 1 400 >"$f"
  export SHUNT_PYTHON="$TEST_TMPDIR/no-such-python"
  run --separate-stderr run_hook "cat $f"
  assert_success
  assert_output --partial '"permissionDecision": "allow"'
  [[ "$stderr" == "shunt: the Python interpreter is unusable"* ]]
}
