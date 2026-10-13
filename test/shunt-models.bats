load 'test_helper'
bats_require_minimum_version 1.5.0

# The registry commands are Python (scripts/py/shunt/models_cli.py) and are tested in
# test/py/test_models_cli.py. These tests cover the bash entry point only.

SHUNT_MODELS_BIN="$REPO_ROOT/scripts/shunt-models"

setup() {
  shunt_test_setup
}

teardown() {
  shunt_test_teardown
}

@test "the launcher passes every argument through raw after one double dash" {
  cat >"$TEST_TMPDIR/fake-python" <<'EOF'
#!/bin/bash
printf '%s\n' "$@"
EOF
  chmod +x "$TEST_TMPDIR/fake-python"
  SHUNT_PYTHON="$TEST_TMPDIR/fake-python" run "$SHUNT_MODELS_BIN" request-body "p/m" --clear '{"a": 1}'
  assert_success
  assert_line --index 0 "-I"
  assert_line --index 1 "-B"
  assert_line --index 3 "shunt-models"
  [ "${lines[4]}" = "--" ]
  assert_line --index 5 "request-body"
  assert_line --index 7 "--clear"
  assert_line --index 8 '{"a": 1}'
  [ "${#lines[@]}" -eq 9 ]
}

@test "the launcher exits with the status of the Python command" {
  printf '#!/bin/bash\nexit 42\n' >"$TEST_TMPDIR/fake-python"
  chmod +x "$TEST_TMPDIR/fake-python"
  SHUNT_PYTHON="$TEST_TMPDIR/fake-python" run "$SHUNT_MODELS_BIN" list
  assert_failure 42
}

@test "add then list: a model is registered, its agent file written and listed" {
  shunt_write_provider "p"
  run "$SHUNT_MODELS_BIN" add "p/m"
  assert_success
  assert_output "shunt: added 'p/m' (agent: shunt-bulk-reader-p-m, roles: bulk-read,code-write)."
  [ -f "$SHUNT_AGENTS_DIR/shunt-bulk-reader-p-m.md" ]
  run "$SHUNT_MODELS_BIN" list
  assert_success
  assert_output "p/m"
}

@test "an error exits 1 with a shunt: line on stderr and leaves the registry alone" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/m"
  local before
  before=$(cat "$SHUNT_MODELS_FILE")
  run --separate-stderr "$SHUNT_MODELS_BIN" add "p/m"
  assert_failure 1
  [ -z "$output" ]
  [[ "$stderr" == shunt:* ]]
  [ "$(cat "$SHUNT_MODELS_FILE")" = "$before" ]
}

@test "an unknown subcommand and a missing one are refused" {
  run "$SHUNT_MODELS_BIN" bogus
  assert_failure 1
  assert_output "shunt: unknown subcommand: bogus"
  run "$SHUNT_MODELS_BIN"
  assert_failure 1
  assert_output --partial "shunt: usage: shunt-models <list|status|"
}
