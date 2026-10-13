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

# file_mode <path>: the octal permission bits, GNU stat first and BSD second.
file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# --- role-aware failover with an acceptance check -----------------------------

# write_role_fake_opencode: a fake CLI whose text answer is the agent name.
write_role_fake_opencode() {
  mkdir -p "$TEST_TMPDIR/bin"
  cat >"$TEST_TMPDIR/bin/opencode" <<'FAKE'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) agent="$2"; shift 2 ;;
    *) shift ;;
  esac
done
jq -cn --arg a "$agent" '{type:"text",part:{text:$a}}'
echo '{"type":"step_finish","part":{"reason":"stop","cost":0,"tokens":{"input":1,"output":2}}}'
FAKE
  chmod +x "$TEST_TMPDIR/bin/opencode"
  export SHUNT_OPENCODE_BIN="$TEST_TMPDIR/bin/opencode"
}

# --- one reason line per failed candidate --------------------------------------

# write_failing_opencode <timeout|error|empty>
write_failing_opencode() {
  mkdir -p "$TEST_TMPDIR/bin"
  case "$1" in
    timeout) printf '#!/bin/bash\nsleep 5\n' >"$TEST_TMPDIR/bin/opencode" ;;
    error) printf '#!/bin/bash\necho partial\nexit 3\n' >"$TEST_TMPDIR/bin/opencode" ;;
    empty) printf '#!/bin/bash\nexit 0\n' >"$TEST_TMPDIR/bin/opencode" ;;
  esac
  chmod +x "$TEST_TMPDIR/bin/opencode"
  export SHUNT_OPENCODE_BIN="$TEST_TMPDIR/bin/opencode"
}

@test "a model id with a control character makes the registry invalid, so it is never used" {
  write_models_registry "p/one"
  jq '.models[0].id = "p/on\u001be" | .active = null' "$SHUNT_MODELS_FILE" >"$TEST_TMPDIR/m.json" && mv "$TEST_TMPDIR/m.json" "$SHUNT_MODELS_FILE"
  run shunt_models_available
  assert_failure
  run shunt_models_validate
  assert_failure
  assert_output --partial "control character"
}
