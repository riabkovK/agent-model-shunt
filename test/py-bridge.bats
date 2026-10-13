load 'test_helper'
bats_require_minimum_version 1.5.0

setup() {
  shunt_test_setup
  source "$REPO_ROOT/scripts/lib/py.sh"
  unset SHUNT_PYTHON
}

teardown() {
  shunt_test_teardown
}

@test "shunt_py version prints the plugin version" {
  expected="$(jq -r .version "$REPO_ROOT/.claude-plugin/plugin.json")"

  run shunt_py version

  assert_success
  assert_output "$expected"
}

@test "SHUNT_PYTHON overrides the interpreter and receives -I -B, the runner and args" {
  cat >"$TEST_TMPDIR/fake-python" <<'SH'
#!/bin/sh
echo "$*" >"$FAKE_ARGV"
SH
  chmod +x "$TEST_TMPDIR/fake-python"
  export FAKE_ARGV="$TEST_TMPDIR/argv"
  export SHUNT_PYTHON="$TEST_TMPDIR/fake-python"

  run shunt_py version --x

  assert_success
  assert_equal "$(cat "$FAKE_ARGV")" "-I -B $SHUNT_PY_MAIN version --x"
}

@test "a missing interpreter yields a non-zero exit" {
  export SHUNT_PYTHON="$TEST_TMPDIR/no-such-python"

  run -127 shunt_py version

  assert_failure 127
}

@test "SHUNT_PY_MAIN points at the runner next to the lib" {
  [ -f "$SHUNT_PY_MAIN" ]
}
