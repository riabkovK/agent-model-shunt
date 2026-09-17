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
