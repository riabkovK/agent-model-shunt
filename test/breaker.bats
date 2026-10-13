load 'test_helper'

setup() {
  shunt_test_setup
  source "$REPO_ROOT/scripts/lib/breaker.sh"
}

teardown() {
  shunt_test_teardown
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

@test "shunt_breaker_key keeps the plain id for bulk-read and suffixes other roles" {
  run shunt_breaker_key "p/m"
  assert_output "p/m"
  run shunt_breaker_key "p/m" bulk-read
  assert_output "p/m"
  run shunt_breaker_key "p/m" code-write
  assert_output "p/m#code-write"
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

@test "healing leaves no temp files next to the state file" {
  write_broken_state truncated
  shunt_breaker_record_failure "p/m"
  run bash -c 'ls -A "$1"' _ "$(dirname "$SHUNT_BREAKER_STATE_FILE")"
  refute_output --partial ".breaker-state.json."
}

@test "a failed write leaves an existing broken state file as it was" {
  write_broken_state corrupt
  # A symlink in place of the lock file is refused, so the write fails before
  # it touches the state file (works for root too, unlike a read-only dir).
  ln -s /dev/null "$SHUNT_BREAKER_STATE_FILE.lock"
  run shunt_breaker_record_failure "p/m"
  assert_failure
  [ "$(cat "$SHUNT_BREAKER_STATE_FILE")" = 'not json {' ]
  run bash -c 'ls -A "$1"' _ "$(dirname "$SHUNT_BREAKER_STATE_FILE")"
  refute_output --partial ".breaker-state.json."
}
