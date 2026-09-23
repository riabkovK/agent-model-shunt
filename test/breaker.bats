load 'test_helper'

setup() {
  shunt_test_setup
  source "$REPO_ROOT/scripts/lib/breaker.sh"
}

teardown() {
  shunt_test_teardown
}

@test "shunt_breaker_is_open is false for a model with no recorded state" {
  run shunt_breaker_is_open "p/m"
  assert_failure
}

@test "shunt_breaker_is_open is false below the failure threshold" {
  shunt_breaker_record_failure "p/m"
  shunt_breaker_record_failure "p/m"
  run shunt_breaker_is_open "p/m"
  assert_failure
}

@test "shunt_breaker_is_open is true once failures reach the default threshold of 3" {
  shunt_breaker_record_failure "p/m"
  shunt_breaker_record_failure "p/m"
  shunt_breaker_record_failure "p/m"
  run shunt_breaker_is_open "p/m"
  assert_success
}

@test "SHUNT_BREAKER_THRESHOLD overrides the default failure count" {
  export SHUNT_BREAKER_THRESHOLD=1
  shunt_breaker_record_failure "p/m"
  run shunt_breaker_is_open "p/m"
  assert_success
}

@test "shunt_breaker_is_open closes again once the cooldown elapses" {
  export SHUNT_BREAKER_THRESHOLD=1
  export SHUNT_BREAKER_COOLDOWN_SECONDS=300
  export SHUNT_NOW_EPOCH=1000
  shunt_breaker_record_failure "p/m"
  run shunt_breaker_is_open "p/m"
  assert_success

  export SHUNT_NOW_EPOCH=1200
  run shunt_breaker_is_open "p/m"
  assert_success

  export SHUNT_NOW_EPOCH=1301
  run shunt_breaker_is_open "p/m"
  assert_failure
}

@test "shunt_breaker_is_open only affects the model it was recorded for" {
  export SHUNT_BREAKER_THRESHOLD=1
  shunt_breaker_record_failure "p/one"
  run shunt_breaker_is_open "p/one"
  assert_success
  run shunt_breaker_is_open "p/two"
  assert_failure
}

@test "shunt_breaker_record_success resets the failure count and closes the breaker" {
  export SHUNT_BREAKER_THRESHOLD=2
  shunt_breaker_record_failure "p/m"
  shunt_breaker_record_failure "p/m"
  run shunt_breaker_is_open "p/m"
  assert_success

  shunt_breaker_record_success "p/m"
  run shunt_breaker_is_open "p/m"
  assert_failure
  run jq -r '.models["p/m"].failures' "$SHUNT_BREAKER_STATE_FILE"
  assert_output "0"
}

@test "shunt_breaker_record_failure persists failure count across sourcing" {
  shunt_breaker_record_failure "p/m"
  shunt_breaker_record_failure "p/m"
  run jq -r '.models["p/m"].failures' "$SHUNT_BREAKER_STATE_FILE"
  assert_output "2"
}

@test "shunt_breaker_record_failure creates the state file lazily" {
  [ ! -f "$SHUNT_BREAKER_STATE_FILE" ]
  shunt_breaker_record_failure "p/m"
  [ -f "$SHUNT_BREAKER_STATE_FILE" ]
}

@test "shunt_breaker_status reports failures and open state" {
  export SHUNT_BREAKER_THRESHOLD=1
  shunt_breaker_record_failure "p/m"
  run shunt_breaker_status "p/m"
  assert_success
  assert_output --partial "failures=1"
  assert_output --partial "open=true"
}

@test "shunt_breaker_status reports closed for an unknown model" {
  run shunt_breaker_status "p/unknown"
  assert_success
  assert_output --partial "failures=0"
  assert_output --partial "open=false"
}

@test "hardcoded defaults apply when neither config file nor env var is set" {
  unset SHUNT_BREAKER_THRESHOLD SHUNT_BREAKER_COOLDOWN_SECONDS
  source "$REPO_ROOT/scripts/lib/breaker.sh"
  [ "$SHUNT_BREAKER_THRESHOLD" = "3" ]
  [ "$SHUNT_BREAKER_COOLDOWN_SECONDS" = "300" ]
}

@test "breaker config file overrides the hardcoded threshold default" {
  echo '{"threshold": 5, "cooldown_seconds": 300}' >"$SHUNT_BREAKER_CONFIG_FILE"
  unset SHUNT_BREAKER_THRESHOLD SHUNT_BREAKER_COOLDOWN_SECONDS
  source "$REPO_ROOT/scripts/lib/breaker.sh"
  [ "$SHUNT_BREAKER_THRESHOLD" = "5" ]
}

@test "breaker config file overrides the hardcoded cooldown default" {
  echo '{"threshold": 3, "cooldown_seconds": 60}' >"$SHUNT_BREAKER_CONFIG_FILE"
  unset SHUNT_BREAKER_THRESHOLD SHUNT_BREAKER_COOLDOWN_SECONDS
  source "$REPO_ROOT/scripts/lib/breaker.sh"
  [ "$SHUNT_BREAKER_COOLDOWN_SECONDS" = "60" ]
}

@test "SHUNT_BREAKER_THRESHOLD env var overrides the config file value" {
  echo '{"threshold": 5, "cooldown_seconds": 300}' >"$SHUNT_BREAKER_CONFIG_FILE"
  export SHUNT_BREAKER_THRESHOLD=9
  source "$REPO_ROOT/scripts/lib/breaker.sh"
  [ "$SHUNT_BREAKER_THRESHOLD" = "9" ]
}

@test "SHUNT_BREAKER_COOLDOWN_SECONDS env var overrides the config file value" {
  echo '{"threshold": 3, "cooldown_seconds": 60}' >"$SHUNT_BREAKER_CONFIG_FILE"
  export SHUNT_BREAKER_COOLDOWN_SECONDS=15
  source "$REPO_ROOT/scripts/lib/breaker.sh"
  [ "$SHUNT_BREAKER_COOLDOWN_SECONDS" = "15" ]
}

@test "malformed breaker config file falls back to hardcoded defaults" {
  echo 'not json' >"$SHUNT_BREAKER_CONFIG_FILE"
  unset SHUNT_BREAKER_THRESHOLD SHUNT_BREAKER_COOLDOWN_SECONDS
  source "$REPO_ROOT/scripts/lib/breaker.sh"
  [ "$SHUNT_BREAKER_THRESHOLD" = "3" ]
  [ "$SHUNT_BREAKER_COOLDOWN_SECONDS" = "300" ]
}

@test "breaker config file with only one field falls back to the default for the other" {
  echo '{"threshold": 7}' >"$SHUNT_BREAKER_CONFIG_FILE"
  unset SHUNT_BREAKER_THRESHOLD SHUNT_BREAKER_COOLDOWN_SECONDS
  source "$REPO_ROOT/scripts/lib/breaker.sh"
  [ "$SHUNT_BREAKER_THRESHOLD" = "7" ]
  [ "$SHUNT_BREAKER_COOLDOWN_SECONDS" = "300" ]
}

@test "shunt_breaker_any_closed is false when given no ids" {
  run shunt_breaker_any_closed
  assert_failure
}

@test "shunt_breaker_any_closed is true when all given ids have no recorded state" {
  run shunt_breaker_any_closed "p/one" "p/two"
  assert_success
}

@test "shunt_breaker_any_closed is true when at least one of several ids is closed" {
  export SHUNT_BREAKER_THRESHOLD=1
  shunt_breaker_record_failure "p/open"
  run shunt_breaker_any_closed "p/open" "p/closed"
  assert_success
}

@test "shunt_breaker_any_closed is false when every given id is open" {
  export SHUNT_BREAKER_THRESHOLD=1
  shunt_breaker_record_failure "p/one"
  shunt_breaker_record_failure "p/two"
  run shunt_breaker_any_closed "p/one" "p/two"
  assert_failure
}

@test "shunt_breaker_any_closed is true again for an id once its cooldown elapses" {
  export SHUNT_BREAKER_THRESHOLD=1
  export SHUNT_BREAKER_COOLDOWN_SECONDS=300
  export SHUNT_NOW_EPOCH=1000
  shunt_breaker_record_failure "p/m"
  run shunt_breaker_any_closed "p/m"
  assert_failure

  export SHUNT_NOW_EPOCH=1301
  run shunt_breaker_any_closed "p/m"
  assert_success
}

@test "shunt_breaker_key keeps the plain id for bulk-read and suffixes other roles" {
  run shunt_breaker_key "p/m"
  assert_output "p/m"
  run shunt_breaker_key "p/m" bulk-read
  assert_output "p/m"
  run shunt_breaker_key "p/m" code-write
  assert_output "p/m#code-write"
}

@test "shunt_breaker_clear_state drops the plain and the code-write key of the model" {
  shunt_breaker_record_failure "p/m"
  shunt_breaker_record_failure "p/m#code-write"
  shunt_breaker_clear_state "p/m"
  run shunt_breaker_model_state "p/m"
  assert_output "null"
  run shunt_breaker_model_state "p/m#code-write"
  assert_output "null"
}

@test "shunt_breaker_clear_state leaves other models' keys alone" {
  shunt_breaker_record_failure "p/m"
  shunt_breaker_record_failure "p/mm"
  shunt_breaker_record_failure "p/mm#code-write"
  shunt_breaker_clear_state "p/m"
  run shunt_breaker_status "p/mm"
  assert_output --partial "failures=1"
  run shunt_breaker_status "p/mm#code-write"
  assert_output --partial "failures=1"
}

@test "shunt_breaker_clear_state tolerates a state file without a models key" {
  mkdir -p "$(dirname "$SHUNT_BREAKER_STATE_FILE")"
  echo '{"version":1}' >"$SHUNT_BREAKER_STATE_FILE"
  run shunt_breaker_clear_state "p/m"
  assert_success
  run jq -r '.version' "$SHUNT_BREAKER_STATE_FILE"
  assert_output "1"
}

# --- hostile or corrupt state values must never reach bash arithmetic ---

# Writes a state file for "p/m" from raw JSON snippets for both fields.
write_raw_state() {
  mkdir -p "$(dirname "$SHUNT_BREAKER_STATE_FILE")"
  printf '{"version":1,"models":{"p/m":{"failures":%s,"cooldown_until":%s}}}\n' \
    "$1" "$2" >"$SHUNT_BREAKER_STATE_FILE"
}

# Asserts a breaker reading the current state file behaves as closed and the
# record functions keep working on top of it.
assert_safe_closed_breaker() {
  run shunt_breaker_is_open "p/m"
  assert_failure
  run shunt_breaker_status "p/m"
  assert_success
  assert_output "failures=0 open=false"
  run shunt_breaker_any_closed "p/m"
  assert_success
  [ ! -e "$MARKER" ]

  shunt_breaker_record_failure "p/m"
  run jq -r '.models["p/m"].failures' "$SHUNT_BREAKER_STATE_FILE"
  assert_output "1"
  shunt_breaker_record_success "p/m"
  run jq -r '.models["p/m"].failures' "$SHUNT_BREAKER_STATE_FILE"
  assert_output "0"
  [ ! -e "$MARKER" ]
}

@test "state file with a non-numeric failures string reads as a closed breaker" {
  MARKER="$TEST_TMPDIR/pwned"
  write_raw_state '"abc"' '"xyz"'
  assert_safe_closed_breaker
}

@test "state file with a command substitution in failures does not execute it" {
  MARKER="$TEST_TMPDIR/pwned"
  write_raw_state "\"a[\$(touch $MARKER)]\"" 0
  assert_safe_closed_breaker
}

@test "state file with a command substitution in cooldown_until does not execute it" {
  MARKER="$TEST_TMPDIR/pwned"
  write_raw_state 5 "\"a[\$(touch $MARKER)]\""
  run shunt_breaker_is_open "p/m"
  assert_failure
  run shunt_breaker_any_closed "p/m"
  assert_success
  shunt_breaker_record_failure "p/m"
  [ ! -e "$MARKER" ]
  run jq -r '.models["p/m"].failures' "$SHUNT_BREAKER_STATE_FILE"
  assert_output "6"
}

@test "state file with a command substitution in both fields does not execute it" {
  MARKER="$TEST_TMPDIR/pwned"
  write_raw_state "\"\$(touch $MARKER)\"" "\"\`touch $MARKER\`\""
  assert_safe_closed_breaker
}

@test "state file with negative numbers reads as a closed breaker" {
  MARKER="$TEST_TMPDIR/pwned"
  write_raw_state -5 -100
  assert_safe_closed_breaker
}

@test "state file with float numbers reads as a closed breaker" {
  MARKER="$TEST_TMPDIR/pwned"
  write_raw_state 4.5 99999.5
  assert_safe_closed_breaker
}

@test "state file with non-scalar or boolean values reads as a closed breaker" {
  MARKER="$TEST_TMPDIR/pwned"
  write_raw_state '[5]' '{"a":1}'
  assert_safe_closed_breaker
  write_raw_state true false
  assert_safe_closed_breaker
}

@test "state file whose model entry is not an object reads as a closed breaker" {
  MARKER="$TEST_TMPDIR/pwned"
  mkdir -p "$(dirname "$SHUNT_BREAKER_STATE_FILE")"
  echo '{"version":1,"models":{"p/m":"garbage"}}' >"$SHUNT_BREAKER_STATE_FILE"
  assert_safe_closed_breaker
}

@test "corrupt failures with a still-future cooldown does not open the breaker" {
  MARKER="$TEST_TMPDIR/pwned"
  export SHUNT_NOW_EPOCH=1000
  write_raw_state '"lots"' 999999
  run shunt_breaker_is_open "p/m"
  assert_failure
  run shunt_breaker_any_closed "p/m"
  assert_success
}

@test "valid numeric state still opens the breaker after the hardening" {
  export SHUNT_NOW_EPOCH=1000
  write_raw_state 5 1200
  run shunt_breaker_is_open "p/m"
  assert_success
  run shunt_breaker_any_closed "p/m"
  assert_failure
}

@test "SHUNT_NOW_EPOCH with a command substitution is ignored and never executed" {
  MARKER="$TEST_TMPDIR/pwned"
  export SHUNT_NOW_EPOCH="a[\$(touch $MARKER)]"
  write_raw_state 1 0
  run shunt_breaker_now
  assert_success
  [[ "$output" =~ ^[0-9]+$ ]]
  shunt_breaker_record_failure "p/m"
  shunt_breaker_record_failure "p/m"
  shunt_breaker_record_failure "p/m"
  run shunt_breaker_is_open "p/m"
  assert_success
  run shunt_breaker_any_closed "p/m"
  assert_failure
  [ ! -e "$MARKER" ]
}

@test "config file cooldown with a command substitution falls back to the default" {
  MARKER="$TEST_TMPDIR/pwned"
  jq -n --arg c "a[\$(touch $MARKER)]" --arg t "b[\$(touch $MARKER)]" \
    '{threshold: $t, cooldown_seconds: $c}' >"$SHUNT_BREAKER_CONFIG_FILE"
  unset SHUNT_BREAKER_THRESHOLD SHUNT_BREAKER_COOLDOWN_SECONDS
  source "$REPO_ROOT/scripts/lib/breaker.sh"
  [ "$SHUNT_BREAKER_THRESHOLD" = "3" ]
  [ "$SHUNT_BREAKER_COOLDOWN_SECONDS" = "300" ]
  shunt_breaker_record_failure "p/m"
  shunt_breaker_record_failure "p/m"
  shunt_breaker_record_failure "p/m"
  [ ! -e "$MARKER" ]
}

@test "env override with a command substitution falls back to the default" {
  MARKER="$TEST_TMPDIR/pwned"
  export SHUNT_BREAKER_THRESHOLD="a[\$(touch $MARKER)]"
  export SHUNT_BREAKER_COOLDOWN_SECONDS="a[\$(touch $MARKER)]"
  source "$REPO_ROOT/scripts/lib/breaker.sh"
  [ "$SHUNT_BREAKER_THRESHOLD" = "3" ]
  [ "$SHUNT_BREAKER_COOLDOWN_SECONDS" = "300" ]
  shunt_breaker_record_failure "p/m"
  [ ! -e "$MARKER" ]
}

@test "state values with leading zeros are read as decimal, not octal" {
  write_raw_state 8 0
  run shunt_breaker_status "p/m"
  assert_output "failures=8 open=false"
  shunt_breaker_record_failure "p/m"
  run jq -r '.models["p/m"].failures' "$SHUNT_BREAKER_STATE_FILE"
  assert_output "9"
}

@test "unparsable state file reads as closed for is_open, status and any_closed" {
  mkdir -p "$(dirname "$SHUNT_BREAKER_STATE_FILE")"
  echo 'not json {' >"$SHUNT_BREAKER_STATE_FILE"
  run shunt_breaker_is_open "p/m"
  assert_failure
  run shunt_breaker_status "p/m"
  assert_output "failures=0 open=false"
  run shunt_breaker_any_closed "p/m"
  assert_success
}

# --- a broken state file heals on the next write --------------------------------

# write_broken_state <corrupt|truncated|empty|not-an-object>
write_broken_state() {
  mkdir -p "$(dirname "$SHUNT_BREAKER_STATE_FILE")"
  case "$1" in
    corrupt) echo 'not json {' >"$SHUNT_BREAKER_STATE_FILE" ;;
    truncated) printf '{"version":1,"models":{"p/m":{"failures":2,"cool' >"$SHUNT_BREAKER_STATE_FILE" ;;
    empty) : >"$SHUNT_BREAKER_STATE_FILE" ;;
    not-an-object) echo '[1,2,3]' >"$SHUNT_BREAKER_STATE_FILE" ;;
  esac
}

@test "record_failure heals a corrupt, truncated, empty or non-object state file" {
  local kind
  for kind in corrupt truncated empty not-an-object; do
    write_broken_state "$kind"
    run shunt_breaker_record_failure "p/m"
    assert_success
    run jq -e '.models["p/m"].failures == 1 and .models["p/m"].cooldown_until == 0' "$SHUNT_BREAKER_STATE_FILE"
    assert_success
  done
}

@test "record_success heals a corrupt, truncated, empty or non-object state file" {
  local kind
  for kind in corrupt truncated empty not-an-object; do
    write_broken_state "$kind"
    run shunt_breaker_record_success "p/m"
    assert_success
    run jq -e '.models["p/m"] == {failures: 0, cooldown_until: 0}' "$SHUNT_BREAKER_STATE_FILE"
    assert_success
  done
}

@test "a healed state file keeps counting failures and opens the breaker at the threshold" {
  write_broken_state corrupt
  export SHUNT_NOW_EPOCH=1000
  shunt_breaker_record_failure "p/m"
  shunt_breaker_record_failure "p/m"
  shunt_breaker_record_failure "p/m"
  run jq -e '.version == 1 and .models["p/m"].failures == 3 and .models["p/m"].cooldown_until == 1300' "$SHUNT_BREAKER_STATE_FILE"
  assert_success
  run shunt_breaker_is_open "p/m"
  assert_success
}

@test "healing leaves no temp files next to the state file" {
  write_broken_state truncated
  shunt_breaker_record_failure "p/m"
  run bash -c 'ls -A "$1"' _ "$(dirname "$SHUNT_BREAKER_STATE_FILE")"
  refute_output --partial ".breaker-state.json."
}

@test "reads never modify a broken or a valid state file" {
  local kind before
  for kind in corrupt truncated empty; do
    write_broken_state "$kind"
    before=$(cat "$SHUNT_BREAKER_STATE_FILE")
    shunt_breaker_is_open "p/m" || true
    shunt_breaker_status "p/m" >/dev/null
    shunt_breaker_any_closed "p/m" || true
    [ "$(cat "$SHUNT_BREAKER_STATE_FILE")" = "$before" ]
  done
  write_raw_state 2 0
  before=$(cat "$SHUNT_BREAKER_STATE_FILE")
  shunt_breaker_is_open "p/m" || true
  shunt_breaker_status "p/m" >/dev/null
  shunt_breaker_any_closed "p/m" || true
  [ "$(cat "$SHUNT_BREAKER_STATE_FILE")" = "$before" ]
}

@test "record calls still fail when the state file cannot really be written" {
  # The state directory path is a regular file, so it can never be created.
  echo blocker >"$TEST_TMPDIR/blocker"
  export SHUNT_BREAKER_STATE_FILE="$TEST_TMPDIR/blocker/state.json"
  run shunt_breaker_record_failure "p/m"
  assert_failure
  run shunt_breaker_record_success "p/m"
  assert_failure
}

@test "a failed write leaves an existing broken state file as it was" {
  write_broken_state corrupt
  # The real writer cannot be blocked without breaking the read, so make the
  # atomic rename fail by shadowing mv.
  mv() { return 1; }
  run shunt_breaker_record_failure "p/m"
  assert_failure
  unset -f mv
  [ "$(cat "$SHUNT_BREAKER_STATE_FILE")" = 'not json {' ]
  run bash -c 'ls -A "$1"' _ "$(dirname "$SHUNT_BREAKER_STATE_FILE")"
  refute_output --partial ".breaker-state.json."
}
