load 'test_helper'

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

@test "set cooldown writes the config file and is reflected by show" {
  run "$REPO_ROOT/scripts/shunt-breaker-config" set cooldown 60
  assert_success
  run "$REPO_ROOT/scripts/shunt-breaker-config" show
  assert_output --partial "cooldown_seconds=60 (default: 300)"
}

@test "set threshold preserves a previously-set cooldown value" {
  "$REPO_ROOT/scripts/shunt-breaker-config" set cooldown 60 >/dev/null
  "$REPO_ROOT/scripts/shunt-breaker-config" set threshold 5 >/dev/null
  run "$REPO_ROOT/scripts/shunt-breaker-config" show
  assert_output --partial "threshold=5 (default: 3)"
  assert_output --partial "cooldown_seconds=60 (default: 300)"
}

@test "set threshold rejects a non-integer value" {
  run "$REPO_ROOT/scripts/shunt-breaker-config" set threshold abc
  assert_failure
  [ ! -f "$SHUNT_BREAKER_CONFIG_FILE" ]
}

@test "set threshold rejects zero" {
  run "$REPO_ROOT/scripts/shunt-breaker-config" set threshold 0
  assert_failure
}

@test "set cooldown rejects a negative value" {
  run "$REPO_ROOT/scripts/shunt-breaker-config" set cooldown -1
  assert_failure
}

@test "set cooldown accepts zero" {
  run "$REPO_ROOT/scripts/shunt-breaker-config" set cooldown 0
  assert_success
}

@test "disable presets an unreachable threshold" {
  run "$REPO_ROOT/scripts/shunt-breaker-config" disable
  assert_success
  run "$REPO_ROOT/scripts/shunt-breaker-config" show
  assert_output --partial "disabled"
}

@test "reset removes the config file and restores hardcoded defaults" {
  "$REPO_ROOT/scripts/shunt-breaker-config" set threshold 9 >/dev/null
  [ -f "$SHUNT_BREAKER_CONFIG_FILE" ]
  run "$REPO_ROOT/scripts/shunt-breaker-config" reset
  assert_success
  [ ! -f "$SHUNT_BREAKER_CONFIG_FILE" ]
  run "$REPO_ROOT/scripts/shunt-breaker-config" show
  assert_output --partial "threshold=3 (default: 3)"
}

@test "an env var override is reflected by show even with no config file" {
  export SHUNT_BREAKER_THRESHOLD=7
  run "$REPO_ROOT/scripts/shunt-breaker-config" show
  assert_success
  assert_output --partial "threshold=7 (default: 3)"
}

@test "show reports legacy mode when no models registry exists" {
  run "$REPO_ROOT/scripts/shunt-breaker-config" show
  assert_success
  assert_output --partial "not applicable"
}
