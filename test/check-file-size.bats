load 'test_helper'

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

@test "denies a large file when the registry has a closed (usable) candidate" {
  local f="$TEST_TMPDIR/big.txt"
  write_large_file "$f"
  jq -n '{active: "p/m", models: [{id: "p/m", agent: "a"}]}' >"$SHUNT_MODELS_FILE"
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

@test "allows a large file when every registry model is disabled" {
  local f="$TEST_TMPDIR/big.txt"
  write_large_file "$f"
  jq -n '{active: "p/m", models: [{id: "p/m", agent: "a", enabled: false}]}' >"$SHUNT_MODELS_FILE"
  run run_hook "$f"
  assert_success
  assert_output --partial '"permissionDecision": "allow"'
}

@test "denies a large file when a disabled model sits beside an enabled usable one" {
  local f="$TEST_TMPDIR/big.txt"
  write_large_file "$f"
  jq -n '{active: null, models: [{id: "p/off", agent: "a", enabled: false}, {id: "p/on", agent: "b", enabled: true}]}' >"$SHUNT_MODELS_FILE"
  run run_hook "$f"
  assert_output --partial '"permissionDecision": "deny"'
}

@test "allows a large file when every registry candidate's breaker is open" {
  local f="$TEST_TMPDIR/big.txt"
  write_large_file "$f"
  jq -n '{active: "p/m", models: [{id: "p/m", agent: "a"}]}' >"$SHUNT_MODELS_FILE"
  export SHUNT_BREAKER_THRESHOLD=1
  source "$REPO_ROOT/scripts/lib/breaker.sh"
  shunt_breaker_record_failure "p/m"
  run run_hook "$f"
  assert_success
  assert_output --partial '"permissionDecision": "allow"'
}
