load 'test_helper'
bats_require_minimum_version 1.5.0

HOOK="$REPO_ROOT/hooks/session-start-orchestrator"

setup() {
  shunt_test_setup
}

teardown() {
  shunt_test_teardown
}

# ctx: runs the hook and prints the additionalContext text.
ctx() {
  "$HOOK" </dev/null | jq -r '.hookSpecificOutput.additionalContext'
}

registry_all() {
  jq -n '{active: "p/m", models: [{id: "p/m", agent: "a"}]}' >"$SHUNT_MODELS_FILE"
}

@test "hook: prints one valid SessionStart JSON object" {
  registry_all
  run "$HOOK" </dev/null
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"'
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | startswith("Shunt delegation")'
  [ "$(echo "$output" | jq -s 'length')" -eq 1 ]
}

@test "hook: no registry gives the model-config line" {
  run ctx
  assert_output --partial 'run /model-config'
}

@test "hook: corrupt models.json gives exit 0 and empty stdout" {
  printf '{not json' >"$SHUNT_MODELS_FILE"
  run "$HOOK" </dev/null
  assert_success
  [ -z "$output" ]
}

@test "hook: a missing interpreter gives exit 0, empty stdout and a warning on stderr" {
  registry_all
  SHUNT_PYTHON="$TEST_TMPDIR/no-such-python" run --separate-stderr "$HOOK" </dev/null
  assert_success
  [ -z "$output" ]
  [[ "$stderr" == "shunt: the Python interpreter is unusable"* ]]
}

@test "hook: closed stdin and /dev/null stdin both exit 0 quickly" {
  registry_all
  run timeout 5 "$HOOK" <&-
  assert_success
  assert_output --partial SessionStart
  run timeout 5 "$HOOK" </dev/null
  assert_success
  assert_output --partial SessionStart
}

@test "hooks.json registers the SessionStart orchestrator hook" {
  local f="$REPO_ROOT/hooks/hooks.json"
  jq -e . "$f" >/dev/null
  run jq -r '.hooks.SessionStart[0].matcher' "$f"
  assert_output 'startup|resume|clear|compact'
  run jq -r '.hooks.SessionStart[0].hooks[0].command' "$f"
  assert_output '${CLAUDE_PLUGIN_ROOT}/hooks/session-start-orchestrator'
  run jq -r '.hooks.SessionStart[0].hooks[0].type' "$f"
  assert_output command
  jq -e '.hooks.SessionStart[0].hooks[0].timeout | type == "number" and . > 0 and . <= 10' "$f" >/dev/null
  jq -e '.hooks.PreToolUse | length == 2' "$f" >/dev/null
  [ -x "$REPO_ROOT/hooks/session-start-orchestrator" ]
}
