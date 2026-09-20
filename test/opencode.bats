load 'test_helper'

setup() {
  shunt_test_setup
  source "$REPO_ROOT/scripts/lib/opencode.sh"
}

teardown() {
  shunt_test_teardown
}

write_legacy_agent() {
  local name="$1" model="$2"
  mkdir -p "$SHUNT_OPENCODE_CONFIG_HOME/agents"
  cat >"$SHUNT_OPENCODE_CONFIG_HOME/agents/$name.md" <<AGENT
---
model: $model
---
legacy agent
AGENT
}

write_shunt_agent() {
  local name="$1" model="$2"
  mkdir -p "$SHUNT_AGENTS_DIR"
  cat >"$SHUNT_AGENTS_DIR/$name.md" <<AGENT
---
model: $model
---
shunt-owned agent
AGENT
}

# write_models_registry <id> [<id>...]
# Writes a minimal models.json listing the given ids (first one active) and
# materializes a matching shunt-owned agent + provider for each, so
# shunt_invoke_with_failover's registry path has everything it needs.
write_models_registry() {
  local models_json="[]"
  local id provider agent
  for id in "$@"; do
    provider="${id%%/*}"
    agent="shunt-bulk-reader-$(echo "$id" | tr '[:upper:]/' '[:lower:]-')"
    write_shunt_agent "$agent" "$id"
    shunt_write_provider "$provider"
    models_json=$(echo "$models_json" | jq -c --arg id "$id" --arg agent "$agent" '. + [{id: $id, agent: $agent}]')
  done
  jq -n --argjson models "$models_json" --arg active "$1" '{active: $active, models: $models}' >"$SHUNT_MODELS_FILE"
}

# write_fake_opencode_bin <mode>
# Writes a fake `opencode` CLI to $TEST_TMPDIR/bin/opencode and points
# SHUNT_OPENCODE_BIN at it. mode "succeed" prints a minimal valid
# --format json transcript; "fail" exits non-zero with no output.
write_fake_opencode_bin() {
  local mode="$1"
  mkdir -p "$TEST_TMPDIR/bin"
  local bin="$TEST_TMPDIR/bin/opencode"
  if [ "$mode" = "succeed" ]; then
    cat >"$bin" <<'FAKE'
#!/bin/bash
echo '{"type":"text","part":{"text":"ok"}}'
FAKE
  else
    cat >"$bin" <<'FAKE'
#!/bin/bash
exit 1
FAKE
  fi
  chmod +x "$bin"
  export SHUNT_OPENCODE_BIN="$bin"
}

@test "shunt_prepare_isolated_config finds a shunt-owned agent in SHUNT_AGENTS_DIR" {
  write_shunt_agent "shunt-bulk-reader-p-m" "p/m"
  shunt_write_provider "p"
  run shunt_prepare_isolated_config "shunt-bulk-reader-p-m"
  assert_success
  [ -f "$SHUNT_ISOLATED_CONFIG_DIR/shunt-bulk-reader-p-m/opencode/agents/shunt-bulk-reader-p-m.md" ]
}

@test "shunt_prepare_isolated_config falls back to the legacy agents dir when not shunt-owned" {
  write_legacy_agent "bulk-reader" "p/m"
  shunt_write_provider "p"
  run shunt_prepare_isolated_config "bulk-reader"
  assert_success
  [ -f "$SHUNT_ISOLATED_CONFIG_DIR/bulk-reader/opencode/agents/bulk-reader.md" ]
}

@test "shunt_prepare_isolated_config errors when the agent exists in neither location" {
  run shunt_prepare_isolated_config "nowhere"
  assert_failure
}

@test "shunt_prepare_isolated_config isolates different agents into separate directories" {
  write_shunt_agent "agent-one" "p/one"
  write_shunt_agent "agent-two" "p/two"
  shunt_write_provider "p"

  shunt_prepare_isolated_config "agent-one" >/dev/null
  shunt_prepare_isolated_config "agent-two" >/dev/null

  run jq -r '.model' "$SHUNT_ISOLATED_CONFIG_DIR/agent-one/opencode/agents/agent-one.md" 2>/dev/null
  [ -f "$SHUNT_ISOLATED_CONFIG_DIR/agent-one/opencode/agents/agent-one.md" ]
  [ -f "$SHUNT_ISOLATED_CONFIG_DIR/agent-two/opencode/agents/agent-two.md" ]
  run grep -c "model: p/one" "$SHUNT_ISOLATED_CONFIG_DIR/agent-one/opencode/agents/agent-one.md"
  assert_output "1"
  run grep -c "model: p/two" "$SHUNT_ISOLATED_CONFIG_DIR/agent-two/opencode/agents/agent-two.md"
  assert_output "1"
}

@test "shunt_invoke_with_failover uses the legacy single agent when no registry exists" {
  write_legacy_agent "bulk-reader" "p/m"
  shunt_write_provider "p"
  export SHUNT_BULK_READER_AGENT="bulk-reader"
  write_fake_opencode_bin succeed
  local f="$TEST_TMPDIR/file.txt"
  echo hi >"$f"

  shunt_invoke_with_failover "question" "$f" >"$TEST_TMPDIR/out_path"
  [ "$SHUNT_INVOKE_AGENT_USED" = "bulk-reader" ]
  [ -s "$(cat "$TEST_TMPDIR/out_path")" ]
}

@test "shunt_invoke_with_failover uses the registry's active model on success" {
  write_models_registry "p/one" "p/two"
  write_fake_opencode_bin succeed
  local f="$TEST_TMPDIR/file.txt"
  echo hi >"$f"

  shunt_invoke_with_failover "question" "$f" >"$TEST_TMPDIR/out_path"
  [ "$SHUNT_INVOKE_AGENT_USED" = "p/one" ]
  run shunt_breaker_status "p/one"
  assert_output --partial "failures=0"
}

@test "shunt_invoke_with_failover falls over to the next candidate when the first fails" {
  export SHUNT_BREAKER_THRESHOLD=1
  write_models_registry "p/one" "p/two"
  write_fake_opencode_bin fail
  local f="$TEST_TMPDIR/file.txt"
  echo hi >"$f"

  # p/one always fails; swap in a succeeding binary only p/two's call would use
  # is not distinguishable by the fake, so instead assert the failover
  # recorded a failure for p/one and, since both fail, that the call is fatal.
  run shunt_invoke_with_failover "question" "$f"
  assert_failure
  run shunt_breaker_status "p/one"
  assert_output --partial "failures=1"
  run shunt_breaker_status "p/two"
  assert_output --partial "failures=1"
}

@test "shunt_invoke_with_failover skips a candidate whose breaker is already open" {
  export SHUNT_BREAKER_THRESHOLD=1
  write_models_registry "p/one" "p/two"
  shunt_breaker_record_failure "p/one"
  write_fake_opencode_bin succeed
  local f="$TEST_TMPDIR/file.txt"
  echo hi >"$f"

  shunt_invoke_with_failover "question" "$f" >"$TEST_TMPDIR/out_path"
  [ "$SHUNT_INVOKE_AGENT_USED" = "p/two" ]
}

@test "shunt_invoke_with_failover skips a disabled model" {
  write_models_registry "p/one" "p/two"
  local tmp
  tmp=$(jq '.models[0].enabled = false' "$SHUNT_MODELS_FILE") && echo "$tmp" >"$SHUNT_MODELS_FILE"
  write_fake_opencode_bin succeed
  local f="$TEST_TMPDIR/file.txt"
  echo hi >"$f"

  shunt_invoke_with_failover "question" "$f"
  [ "$SHUNT_INVOKE_AGENT_USED" = "p/two" ]
}

@test "shunt_invoke_with_failover fails with a clear message when no model is enabled" {
  write_models_registry "p/one"
  local tmp
  tmp=$(jq '.models[0].enabled = false' "$SHUNT_MODELS_FILE") && echo "$tmp" >"$SHUNT_MODELS_FILE"
  local f="$TEST_TMPDIR/file.txt"
  echo hi >"$f"

  run shunt_invoke_with_failover "question" "$f"
  assert_failure
  assert_output --partial "no enabled delegate models"
}

@test "shunt_invoke_with_failover fails fatally when every candidate's breaker is open" {
  export SHUNT_BREAKER_THRESHOLD=1
  write_models_registry "p/one" "p/two"
  shunt_breaker_record_failure "p/one"
  shunt_breaker_record_failure "p/two"
  local f="$TEST_TMPDIR/file.txt"
  echo hi >"$f"

  run shunt_invoke_with_failover "question" "$f"
  assert_failure
  assert_output --partial "paused"
}
