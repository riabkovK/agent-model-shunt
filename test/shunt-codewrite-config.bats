load 'test_helper'

setup() {
  shunt_test_setup
}

teardown() {
  shunt_test_teardown
}

@test "show reports the hardcoded default when no config file exists" {
  run "$REPO_ROOT/scripts/shunt-codewrite-config" show
  assert_success
  assert_output --partial "self_fix_retries=1 (default: 1)"
}

@test "set self-fix-retries writes the config file and is reflected by show" {
  run "$REPO_ROOT/scripts/shunt-codewrite-config" set self-fix-retries 3
  assert_success
  [ -f "$SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE" ]
  run "$REPO_ROOT/scripts/shunt-codewrite-config" show
  assert_output --partial "self_fix_retries=3 (default: 1)"
}

@test "set self-fix-retries accepts zero (effectively disables the loop)" {
  run "$REPO_ROOT/scripts/shunt-codewrite-config" set self-fix-retries 0
  assert_success
  run "$REPO_ROOT/scripts/shunt-codewrite-config" show
  assert_output --partial "self_fix_retries=0 (default: 1)"
}

@test "set self-fix-retries rejects a non-integer value" {
  run "$REPO_ROOT/scripts/shunt-codewrite-config" set self-fix-retries abc
  assert_failure
  [ ! -f "$SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE" ]
}

@test "set self-fix-retries rejects a negative value" {
  run "$REPO_ROOT/scripts/shunt-codewrite-config" set self-fix-retries -1
  assert_failure
}

@test "set rejects an unknown field" {
  run "$REPO_ROOT/scripts/shunt-codewrite-config" set threshold 3
  assert_failure
}

@test "reset removes the config file and restores the hardcoded default" {
  "$REPO_ROOT/scripts/shunt-codewrite-config" set self-fix-retries 5 >/dev/null
  [ -f "$SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE" ]
  run "$REPO_ROOT/scripts/shunt-codewrite-config" reset
  assert_success
  [ ! -f "$SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE" ]
  run "$REPO_ROOT/scripts/shunt-codewrite-config" show
  assert_output --partial "self_fix_retries=1 (default: 1)"
}

@test "an env var override is reflected by show even with no config file" {
  export SHUNT_CODE_WRITE_SELF_FIX_RETRIES=4
  run "$REPO_ROOT/scripts/shunt-codewrite-config" show
  assert_success
  assert_output --partial "self_fix_retries=4 (default: 1)"
}

@test "an env var override takes precedence over a config file value" {
  "$REPO_ROOT/scripts/shunt-codewrite-config" set self-fix-retries 2 >/dev/null
  export SHUNT_CODE_WRITE_SELF_FIX_RETRIES=9
  run "$REPO_ROOT/scripts/shunt-codewrite-config" show
  assert_success
  assert_output --partial "self_fix_retries=9 (default: 1)"
}

@test "missing subcommand fails with a usage message" {
  run "$REPO_ROOT/scripts/shunt-codewrite-config"
  assert_failure
  assert_output --partial "usage:"
}
