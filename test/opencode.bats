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
