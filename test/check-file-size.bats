load 'test_helper'
bats_require_minimum_version 1.5.0

setup() {
  shunt_test_setup
}

teardown() {
  shunt_test_teardown
}

write_large_file() {
  local f="$1"
  seq 1 400 >"$f"
}

run_hook() {
  local file_path="$1"
  echo "{\"tool_input\": {\"file_path\": \"$file_path\"}}" | "$REPO_ROOT/hooks/check-file-size"
}

@test "allows a small file" {
  local f="$TEST_TMPDIR/small.txt"
  seq 1 10 >"$f"
  run run_hook "$f"
  assert_success
  assert_output --partial '"permissionDecision": "allow"'
}

@test "denies a large file when no models registry exists" {
  local f="$TEST_TMPDIR/big.txt"
  write_large_file "$f"
  run run_hook "$f"
  assert_output --partial '"permissionDecision": "deny"'
}

@test "allows a large file when the registry has no models" {
  local f="$TEST_TMPDIR/big.txt"
  write_large_file "$f"
  jq -n '{active: null, models: []}' >"$SHUNT_MODELS_FILE"
  run run_hook "$f"
  assert_success
  assert_output --partial '"permissionDecision": "allow"'
}

@test "allows a large file when every registry candidate's breaker is open" {
  local f="$TEST_TMPDIR/big.txt"
  write_large_file "$f"
  jq -n '{active: "p/m", models: [{id: "p/m", agent: "a"}]}' >"$SHUNT_MODELS_FILE"
  export SHUNT_BREAKER_THRESHOLD=1
  source "$REPO_ROOT/scripts/lib/py.sh"
  shunt_py breaker record-failure -- "p/m"
  run run_hook "$f"
  assert_success
  assert_output --partial '"permissionDecision": "allow"'
}

@test "an unusable interpreter allows the read: stdout JSON, exit 0, warning only on stderr" {
  local f="$TEST_TMPDIR/big.txt"
  write_large_file "$f"
  echo '{"version":1,"active":null,"models":[{"id":"p/m"}]}' >"$SHUNT_MODELS_FILE"
  export SHUNT_PYTHON="$TEST_TMPDIR/no-such-python"
  run --separate-stderr run_hook "$f"
  assert_success
  assert_output --partial '"permissionDecision": "allow"'
  echo "$output" | jq -e . >/dev/null
  [[ "$stderr" == "shunt: the Python interpreter is unusable"* ]]
}
