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

# file_mode <path>: the octal permission bits, GNU stat first and BSD second.
file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

@test "shunt_prepare_isolated_config writes opencode.json as 0600 in 0700 directories" {
  write_shunt_agent "shunt-bulk-reader-p-m" "p/m"
  shunt_write_provider "p"
  (umask 022; shunt_prepare_isolated_config "shunt-bulk-reader-p-m" >/dev/null)
  local root="$SHUNT_ISOLATED_CONFIG_DIR/shunt-bulk-reader-p-m"
  [ "$(file_mode "$root/opencode/opencode.json")" = "600" ]
  [ "$(file_mode "$root")" = "700" ]
  [ "$(file_mode "$root/opencode")" = "700" ]
}

@test "shunt_prepare_isolated_config tightens a 0644 file and 0755 directories left by an older run" {
  write_shunt_agent "shunt-bulk-reader-p-m" "p/m"
  shunt_write_provider "p"
  local root="$SHUNT_ISOLATED_CONFIG_DIR/shunt-bulk-reader-p-m"
  mkdir -p "$root/opencode/agents"
  echo '{}' >"$root/opencode/opencode.json"
  chmod 644 "$root/opencode/opencode.json"
  chmod 755 "$root" "$root/opencode"
  (umask 022; shunt_prepare_isolated_config "shunt-bulk-reader-p-m" >/dev/null)
  [ "$(file_mode "$root/opencode/opencode.json")" = "600" ]
  [ "$(file_mode "$root")" = "700" ]
  [ "$(file_mode "$root/opencode")" = "700" ]
}

@test "shunt_prepare_isolated_config writes the empty fallback config as 0600 too" {
  write_shunt_agent "shunt-bulk-reader-p-m" "p/m"
  rm -f "$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"
  (umask 022; shunt_prepare_isolated_config "shunt-bulk-reader-p-m" >/dev/null)
  [ "$(file_mode "$SHUNT_ISOLATED_CONFIG_DIR/shunt-bulk-reader-p-m/opencode/opencode.json")" = "600" ]
}

@test "shunt_prepare_isolated_config leaves the caller's umask unchanged" {
  write_shunt_agent "shunt-bulk-reader-p-m" "p/m"
  shunt_write_provider "p"
  umask 022
  shunt_prepare_isolated_config "shunt-bulk-reader-p-m" >/dev/null
  [ "$(umask)" = "0022" ]
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

  shunt_invoke_with_failover "question" "$f"
  [ "$SHUNT_INVOKE_AGENT_USED" = "bulk-reader" ]
  [ -s "$SHUNT_INVOKE_OUT_FILE" ]
}

@test "shunt_invoke_with_failover uses the registry's active model on success" {
  write_models_registry "p/one" "p/two"
  write_fake_opencode_bin succeed
  local f="$TEST_TMPDIR/file.txt"
  echo hi >"$f"

  shunt_invoke_with_failover "question" "$f"
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

  shunt_invoke_with_failover "question" "$f"
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

# accept_only_p_two <out-file>: rejects everything except p/two's transcript.
accept_only_p_two() {
  grep -q 'p-two' "$1"
}

accept_abort() {
  return 2
}

@test "shunt_extract_finish_reason prints the last step_finish reason" {
  printf '%s\n' \
    '{"type":"step_finish","part":{"reason":"tool-calls"}}' \
    '{"type":"text","part":{"text":"hi"}}' \
    '{"type":"step_finish","part":{"reason":"length"}}' >"$TEST_TMPDIR/t.jsonl"
  run shunt_extract_finish_reason "$TEST_TMPDIR/t.jsonl"
  assert_success
  assert_output "length"
}

@test "shunt_extract_finish_reason prints nothing without a step_finish event" {
  echo '{"type":"text","part":{"text":"hi"}}' >"$TEST_TMPDIR/t.jsonl"
  run shunt_extract_finish_reason "$TEST_TMPDIR/t.jsonl"
  assert_success
  assert_output ""
}

@test "shunt_invoke_role_with_failover uses the role's candidates and agent names" {
  write_models_registry "p/one"
  jq '.models[0].roles = ["code-write"]' "$SHUNT_MODELS_FILE" >"$TEST_TMPDIR/m.json" && mv "$TEST_TMPDIR/m.json" "$SHUNT_MODELS_FILE"
  write_shunt_agent "shunt-code-writer-p-one" "p/one"
  write_role_fake_opencode
  local f="$TEST_TMPDIR/file.txt"
  echo hi >"$f"

  shunt_invoke_role_with_failover code-write shunt_models_code_writer_agent_for "" "question" "$f"
  [ "$SHUNT_INVOKE_AGENT_USED" = "p/one" ]
  grep -q "shunt-code-writer-p-one" "$SHUNT_INVOKE_OUT_FILE"
}

@test "shunt_invoke_role_with_failover fails with a role-specific message when no model has the role" {
  write_models_registry "p/one"
  jq '.models[0].roles = ["bulk-read"]' "$SHUNT_MODELS_FILE" >"$TEST_TMPDIR/m.json" && mv "$TEST_TMPDIR/m.json" "$SHUNT_MODELS_FILE"
  run shunt_invoke_role_with_failover code-write shunt_models_code_writer_agent_for "" "question"
  assert_failure
  assert_output --partial "with the code-write role"
}

@test "an accept function returning 1 sends the call to the next model and counts a failure" {
  write_models_registry "p/one" "p/two"
  write_shunt_agent "shunt-code-writer-p-one" "p/one"
  write_shunt_agent "shunt-code-writer-p-two" "p/two"
  write_role_fake_opencode
  # accept_only_p_two wants 'p-two' in the transcript, the fake echoes the agent name.
  shunt_invoke_role_with_failover code-write shunt_models_code_writer_agent_for accept_only_p_two "question"
  [ "$SHUNT_INVOKE_AGENT_USED" = "p/two" ]
  run shunt_breaker_status "p/one#code-write"
  assert_output --partial "failures=1"
  run shunt_breaker_status "p/two#code-write"
  assert_output --partial "failures=0"
  # The bulk-read counter of the same models is untouched.
  run shunt_breaker_status "p/one"
  assert_output --partial "failures=0"
}

@test "a code-write failure counts against the code-write key, not the bulk-read key" {
  export SHUNT_BREAKER_THRESHOLD=1
  write_models_registry "p/one"
  write_shunt_agent "shunt-code-writer-p-one" "p/one"
  write_role_fake_opencode
  run shunt_invoke_role_with_failover code-write shunt_models_code_writer_agent_for accept_only_p_two "question"
  assert_failure
  run shunt_breaker_is_open "p/one#code-write"
  assert_success
  run shunt_breaker_is_open "p/one"
  assert_failure
}

@test "an open bulk-read breaker does not pause the model for code-write" {
  export SHUNT_BREAKER_THRESHOLD=1
  write_models_registry "p/one"
  write_shunt_agent "shunt-code-writer-p-one" "p/one"
  write_role_fake_opencode
  shunt_breaker_record_failure "p/one"
  shunt_invoke_role_with_failover code-write shunt_models_code_writer_agent_for "" "question"
  [ "$SHUNT_INVOKE_AGENT_USED" = "p/one" ]
}

@test "an open code-write breaker skips the model for code-write but not for bulk-read" {
  export SHUNT_BREAKER_THRESHOLD=1
  write_models_registry "p/one"
  write_shunt_agent "shunt-code-writer-p-one" "p/one"
  write_role_fake_opencode
  shunt_breaker_record_failure "p/one#code-write"
  run shunt_invoke_role_with_failover code-write shunt_models_code_writer_agent_for "" "question"
  assert_failure
  assert_output --partial "paused"
  shunt_invoke_with_failover "question"
  [ "$SHUNT_INVOKE_AGENT_USED" = "p/one" ]
}

@test "an accepted code-write answer resets the code-write counter only" {
  export SHUNT_BREAKER_THRESHOLD=5
  write_models_registry "p/one"
  write_shunt_agent "shunt-code-writer-p-one" "p/one"
  write_role_fake_opencode
  shunt_breaker_record_failure "p/one#code-write"
  shunt_breaker_record_failure "p/one"
  shunt_invoke_role_with_failover code-write shunt_models_code_writer_agent_for "" "question"
  run shunt_breaker_status "p/one#code-write"
  assert_output --partial "failures=0"
  run shunt_breaker_status "p/one"
  assert_output --partial "failures=1"
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

@test "a candidate that times out is reported with the model id and the timeout" {
  export SHUNT_TIMEOUT_SECONDS=1
  write_models_registry "p/one"
  write_failing_opencode timeout
  run shunt_invoke_with_failover "question"
  assert_failure
  assert_output --partial "shunt: p/one failed: timed out after 1s"
}

@test "a candidate whose opencode run errors is reported with the model id" {
  write_models_registry "p/one"
  write_failing_opencode error
  run shunt_invoke_with_failover "question"
  assert_failure
  assert_output --partial "shunt: p/one failed: opencode error"
}

@test "a candidate that prints nothing is reported as empty output" {
  write_models_registry "p/one"
  write_failing_opencode empty
  run shunt_invoke_with_failover "question"
  assert_failure
  assert_output --partial "shunt: p/one failed: empty output"
}

@test "each failed candidate gets its own reason line before the next one is tried" {
  write_models_registry "p/one" "p/two"
  write_failing_opencode error
  run shunt_invoke_with_failover "question"
  assert_failure
  assert_output --partial "shunt: p/one failed: opencode error"
  assert_output --partial "shunt: p/two failed: opencode error"
}

@test "control characters in a model id are stripped from the reason line" {
  write_models_registry "p/one"
  jq '.models[0].id = "p/on\u001be"' "$SHUNT_MODELS_FILE" >"$TEST_TMPDIR/m.json" && mv "$TEST_TMPDIR/m.json" "$SHUNT_MODELS_FILE"
  jq '.active = null' "$SHUNT_MODELS_FILE" >"$TEST_TMPDIR/m.json" && mv "$TEST_TMPDIR/m.json" "$SHUNT_MODELS_FILE"
  write_failing_opencode error
  run shunt_invoke_with_failover "question"
  assert_failure
  assert_output --partial "shunt: p/one failed: opencode error"
}

# --- the unknown-active warning is printed once per call -----------------------

@test "a bulk-read call with an unknown active model warns once" {
  write_models_registry "p/one"
  jq '.active = "p/missing"' "$SHUNT_MODELS_FILE" >"$TEST_TMPDIR/m.json" && mv "$TEST_TMPDIR/m.json" "$SHUNT_MODELS_FILE"
  write_fake_opencode_bin succeed
  run shunt_invoke_with_failover "question"
  assert_success
  [ "$(echo "$output" | grep -c "falling back to priority order")" -eq 1 ]
}

@test "the role failover does not repeat a warning its caller's own candidate lookup printed" {
  write_models_registry "p/one"
  jq '.active = "p/missing"' "$SHUNT_MODELS_FILE" >"$TEST_TMPDIR/m.json" && mv "$TEST_TMPDIR/m.json" "$SHUNT_MODELS_FILE"
  write_shunt_agent "shunt-code-writer-p-one" "p/one"
  write_role_fake_opencode
  run bash -c '
    source "$1/scripts/lib/opencode.sh"
    candidates=$(shunt_models_candidates code-write)
    shunt_invoke_role_with_failover code-write shunt_models_code_writer_agent_for "" "question"
  ' _ "$REPO_ROOT"
  assert_success
  [ "$(echo "$output" | grep -c "falling back to priority order")" -eq 1 ]
}

@test "an accept function returning 2 aborts the call without touching the breaker" {
  write_models_registry "p/one" "p/two"
  write_shunt_agent "shunt-code-writer-p-one" "p/one"
  write_shunt_agent "shunt-code-writer-p-two" "p/two"
  write_role_fake_opencode
  run shunt_invoke_role_with_failover code-write shunt_models_code_writer_agent_for accept_abort "question"
  assert_failure
  [ ! -f "$SHUNT_BREAKER_STATE_FILE" ]
}

@test "a corrupt breaker state file is healed by a successful call without a warning" {
  set -e
  write_models_registry "p/one"
  write_fake_opencode_bin succeed
  echo 'not json' >"$SHUNT_BREAKER_STATE_FILE"
  local f="$TEST_TMPDIR/file.txt"
  echo hi >"$f"

  shunt_invoke_with_failover "question" "$f" 2>"$TEST_TMPDIR/err"
  [ "$SHUNT_INVOKE_AGENT_USED" = "p/one" ]
  [ -s "$SHUNT_INVOKE_OUT_FILE" ]
  ! grep -q "could not update the circuit breaker state" "$TEST_TMPDIR/err"
  jq -e '.models["p/one"] == {failures: 0, cooldown_until: 0}' "$SHUNT_BREAKER_STATE_FILE" >/dev/null
}

@test "a corrupt breaker state file does not stop the failover, it is healed and the failure counted" {
  set -e
  write_models_registry "p/one" "p/two"
  write_shunt_agent "shunt-code-writer-p-one" "p/one"
  write_shunt_agent "shunt-code-writer-p-two" "p/two"
  write_role_fake_opencode
  echo 'not json' >"$SHUNT_BREAKER_STATE_FILE"

  shunt_invoke_role_with_failover code-write shunt_models_code_writer_agent_for accept_only_p_two "question" 2>"$TEST_TMPDIR/err"
  [ "$SHUNT_INVOKE_AGENT_USED" = "p/two" ]
  ! grep -q "could not update the circuit breaker state" "$TEST_TMPDIR/err"
  jq -e '.models["p/one#code-write"].failures == 1 and .models["p/two#code-write"].failures == 0' "$SHUNT_BREAKER_STATE_FILE" >/dev/null
}

@test "a rejected transcript does not leave its output file behind" {
  export TMPDIR="$TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  write_models_registry "p/one"
  write_shunt_agent "shunt-code-writer-p-one" "p/one"
  write_role_fake_opencode
  run shunt_invoke_role_with_failover code-write shunt_models_code_writer_agent_for accept_only_p_two "question"
  assert_failure
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "shunt_log_usage tags bulk-read entries and shunt_log_code_write tags code-write entries" {
  export SHUNT_DEBUG_LOG_PATH="$TEST_TMPDIR/usage.jsonl"
  local f="$TEST_TMPDIR/in.txt" j="$TEST_TMPDIR/t.jsonl"
  printf 'abcdefgh\n' >"$f"
  echo '{"type":"step_finish","part":{"reason":"stop","cost":0.1,"tokens":{"input":7,"output":3}}}' >"$j"

  shunt_log_usage "p/one" "$j" "q" "$f"
  shunt_log_code_write "p/two" "$j" "spec" 400 "$f"

  [ "$(sed -n 1p "$SHUNT_DEBUG_LOG_PATH" | jq -r '.tool')" = "bulk-read" ]
  [ "$(sed -n 1p "$SHUNT_DEBUG_LOG_PATH" | jq -r '.avoided_tokens_estimate')" = "3" ]
  [ "$(sed -n 2p "$SHUNT_DEBUG_LOG_PATH" | jq -r '.tool')" = "code-write" ]
  [ "$(sed -n 2p "$SHUNT_DEBUG_LOG_PATH" | jq -r '.avoided_tokens_estimate')" = "0" ]
  [ "$(sed -n 2p "$SHUNT_DEBUG_LOG_PATH" | jq -r '.generated_bytes')" = "400" ]
  [ "$(sed -n 2p "$SHUNT_DEBUG_LOG_PATH" | jq -r '.avoided_output_tokens_estimate')" = "100" ]
  [ "$(sed -n 2p "$SHUNT_DEBUG_LOG_PATH" | jq -r '.delegate_output_tokens')" = "3" ]
}
