load 'test_helper'

# Launcher-level checks. The subcommands, validation and output lines are covered
# by test/py/test_breaker_config_cli.py.

setup() {
  shunt_test_setup
}

teardown() {
  shunt_test_teardown
}

@test "show reports hardcoded defaults when no config file exists" {
  run "$REPO_ROOT/scripts/shunt-breaker-config" show
  assert_success
  assert_output --partial "threshold=3 (default: 3)"
  assert_output --partial "cooldown_seconds=300 (default: 300)"
}

@test "set threshold writes the config file and is reflected by show" {
  run "$REPO_ROOT/scripts/shunt-breaker-config" set threshold 5
  assert_success
  [ -f "$SHUNT_BREAKER_CONFIG_FILE" ]
  run "$REPO_ROOT/scripts/shunt-breaker-config" show
  assert_output --partial "threshold=5 (default: 3)"
}

@test "set threshold rejects a non-integer value with exit code 1" {
  run "$REPO_ROOT/scripts/shunt-breaker-config" set threshold abc
  assert_failure 1
  [ ! -f "$SHUNT_BREAKER_CONFIG_FILE" ]
}

@test "disable and reset round-trip through show" {
  run "$REPO_ROOT/scripts/shunt-breaker-config" disable
  assert_success
  run "$REPO_ROOT/scripts/shunt-breaker-config" show
  assert_output --partial "disabled"
  run "$REPO_ROOT/scripts/shunt-breaker-config" reset
  assert_success
  [ ! -f "$SHUNT_BREAKER_CONFIG_FILE" ]
}

@test "show lists the code-write breaker state next to each model's own" {
  shunt_write_provider "p"
  "$REPO_ROOT/scripts/shunt-models" add "p/one" >/dev/null
  echo '{"version":1,"models":{"p/one":{"failures":1,"cooldown_until":0},"p/one#code-write":{"failures":2,"cooldown_until":0}}}' \
    >"$SHUNT_BREAKER_STATE_FILE"
  run "$REPO_ROOT/scripts/shunt-breaker-config" show
  assert_success
  assert_output --partial "p/one: failures=1 open=false"
  assert_output --partial "p/one (code-write): failures=2 open=false"
}
