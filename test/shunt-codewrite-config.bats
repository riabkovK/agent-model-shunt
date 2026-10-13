load 'test_helper'

# Launcher-level checks. The subcommands, validation and output lines are covered
# by test/py/test_codewrite_config_cli.py.

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

@test "set self-fix-retries rejects a non-integer value with exit code 1" {
  run "$REPO_ROOT/scripts/shunt-codewrite-config" set self-fix-retries abc
  assert_failure 1
  [ ! -f "$SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE" ]
}

@test "reset removes the config file and restores the hardcoded default" {
  "$REPO_ROOT/scripts/shunt-codewrite-config" set self-fix-retries 5 >/dev/null
  run "$REPO_ROOT/scripts/shunt-codewrite-config" reset
  assert_success
  [ ! -f "$SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE" ]
}

@test "missing subcommand fails with a usage message" {
  run "$REPO_ROOT/scripts/shunt-codewrite-config"
  assert_failure 1
  assert_output --partial "usage:"
}
