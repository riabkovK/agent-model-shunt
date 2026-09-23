load 'test_helper'

# End-to-end tests for scripts/bulk-read itself (not just the library
# functions it calls), so anything that only breaks across the script's own
# command substitutions is caught here.

setup() {
  shunt_test_setup
  export SHUNT_DEBUG_LOG=1
  export SHUNT_DEBUG_LOG_PATH="$TEST_TMPDIR/usage.jsonl"
  export SHUNT_BULK_READER_AGENT="bulk-reader"

  mkdir -p "$TEST_TMPDIR/bin"
  cat >"$TEST_TMPDIR/bin/opencode" <<'FAKE'
#!/bin/bash
echo '{"type":"text","part":{"text":"ok"}}'
FAKE
  chmod +x "$TEST_TMPDIR/bin/opencode"
  export SHUNT_OPENCODE_BIN="$TEST_TMPDIR/bin/opencode"

  SAMPLE="$TEST_TMPDIR/sample.txt"
  echo "alpha=1" >"$SAMPLE"
}

teardown() {
  shunt_test_teardown
}

# logged_agent
# Prints the delegate agent recorded by the last bulk-read call.
logged_agent() {
  jq -r '.agent' "$SHUNT_DEBUG_LOG_PATH" | tail -n 1
}

@test "bulk-read answers and logs the model id when a registry exists" {
  shunt_write_provider "p"
  "$REPO_ROOT/scripts/shunt-models" add p/one >/dev/null

  run "$REPO_ROOT/scripts/bulk-read" --question "q" --paths "$SAMPLE"
  assert_success
  assert_output --partial "ok"
  [ "$(logged_agent)" = "p/one" ]
}

@test "bulk-read skips a disabled model and logs the next one" {
  shunt_write_provider "p"
  "$REPO_ROOT/scripts/shunt-models" add p/one >/dev/null
  "$REPO_ROOT/scripts/shunt-models" add p/two >/dev/null
  "$REPO_ROOT/scripts/shunt-models" activate p/one >/dev/null
  "$REPO_ROOT/scripts/shunt-models" disable p/one >/dev/null

  run "$REPO_ROOT/scripts/bulk-read" --question "q" --paths "$SAMPLE"
  assert_success
  [ "$(logged_agent)" = "p/two" ]
}

@test "bulk-read fails over to the next model even when opencode reads stdin" {
  # The real opencode reads stdin, which would swallow the remaining
  # candidates the failover loop is iterating over if it inherited them.
  cat >"$TEST_TMPDIR/bin/opencode" <<'FAKE'
#!/bin/bash
cat >/dev/null
case "$*" in
  *shunt-bulk-reader-p-one*) exit 1 ;;
esac
echo '{"type":"text","part":{"text":"ok"}}'
FAKE
  shunt_write_provider "p"
  "$REPO_ROOT/scripts/shunt-models" add p/one >/dev/null
  "$REPO_ROOT/scripts/shunt-models" add p/two >/dev/null
  "$REPO_ROOT/scripts/shunt-models" activate p/one >/dev/null

  run "$REPO_ROOT/scripts/bulk-read" --question "q" --paths "$SAMPLE"
  assert_success
  [ "$(logged_agent)" = "p/two" ]
}

@test "bulk-read fails clearly when every model is disabled" {
  shunt_write_provider "p"
  "$REPO_ROOT/scripts/shunt-models" add p/one >/dev/null
  "$REPO_ROOT/scripts/shunt-models" disable p/one >/dev/null

  run "$REPO_ROOT/scripts/bulk-read" --question "q" --paths "$SAMPLE"
  assert_failure
  assert_output --partial "no enabled delegate models"
}

@test "bulk-read skips a model restricted to code-write and uses one that has bulk-read" {
  shunt_write_provider "p"
  "$REPO_ROOT/scripts/shunt-models" add p/writer >/dev/null
  "$REPO_ROOT/scripts/shunt-models" add p/reader >/dev/null
  "$REPO_ROOT/scripts/shunt-models" roles p/writer code-write >/dev/null
  "$REPO_ROOT/scripts/shunt-models" activate p/writer >/dev/null

  run "$REPO_ROOT/scripts/bulk-read" --question "q" --paths "$SAMPLE"
  assert_success
  [ "$(logged_agent)" = "p/reader" ]
}

@test "bulk-read fails clearly when no enabled model has the bulk-read role" {
  shunt_write_provider "p"
  "$REPO_ROOT/scripts/shunt-models" add p/writer >/dev/null
  "$REPO_ROOT/scripts/shunt-models" roles p/writer code-write >/dev/null

  run "$REPO_ROOT/scripts/bulk-read" --question "q" --paths "$SAMPLE"
  assert_failure
  assert_output --partial "with the bulk-read role"
}

@test "bulk-read still works in legacy single-agent mode" {
  mkdir -p "$SHUNT_OPENCODE_CONFIG_HOME/agents"
  printf -- '---\nmodel: p/legacy\n---\nlegacy agent\n' \
    >"$SHUNT_OPENCODE_CONFIG_HOME/agents/bulk-reader.md"
  shunt_write_provider "p"

  run "$REPO_ROOT/scripts/bulk-read" --question "q" --paths "$SAMPLE"
  assert_success
  assert_output --partial "ok"
  [ "$(logged_agent)" = "bulk-reader" ]
}
