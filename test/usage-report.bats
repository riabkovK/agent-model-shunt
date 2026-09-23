load 'test_helper'

setup() {
  shunt_test_setup
  LOG="$TEST_TMPDIR/usage.jsonl"
}

teardown() {
  shunt_test_teardown
}

# Two bulk-read calls (one legacy entry without a tool field) and one
# code-write call, all on the same model id, plus a bulk-read call on another.
write_log() {
  cat >"$LOG" <<'JSONL'
{"agent":"p/one","delegate_input_tokens":10,"delegate_output_tokens":5,"delegate_cost_usd":0.25,"avoided_tokens_estimate":400}
{"agent":"p/one","tool":"bulk-read","delegate_input_tokens":10,"delegate_output_tokens":5,"delegate_cost_usd":0.25,"avoided_tokens_estimate":100}
{"agent":"p/one","tool":"code-write","delegate_input_tokens":20,"delegate_output_tokens":50,"delegate_cost_usd":0.5,"avoided_tokens_estimate":0,"generated_bytes":7,"avoided_output_tokens_estimate":2}
{"agent":"p/two","tool":"bulk-read","delegate_input_tokens":1,"delegate_output_tokens":1,"delegate_cost_usd":0.125,"avoided_tokens_estimate":8}
JSONL
}

report() {
  "$REPO_ROOT/scripts/usage-report" "$LOG" 2>/dev/null
}

@test "by_agent keeps bulk-read and code-write rows of the same model apart" {
  write_log
  run report
  assert_success
  [ "$(echo "$output" | jq '.by_agent | length')" = "3" ]
  [ "$(echo "$output" | jq -r '.by_agent[] | select(.agent == "p/one" and .tool == "bulk-read") | .calls')" = "2" ]
  [ "$(echo "$output" | jq -r '.by_agent[] | select(.agent == "p/one" and .tool == "bulk-read") | .avoided_tokens_estimate')" = "500" ]
  [ "$(echo "$output" | jq -r '.by_agent[] | select(.agent == "p/one" and .tool == "code-write") | .calls')" = "1" ]
  [ "$(echo "$output" | jq -r '.by_agent[] | select(.agent == "p/one" and .tool == "code-write") | .delegate_cost_usd')" = "0.5" ]
  [ "$(echo "$output" | jq -r '.by_agent[] | select(.agent == "p/one" and .tool == "code-write") | .avoided_output_tokens_estimate')" = "2" ]
}

@test "by_agent rows keep the agent, calls, cost and avoided fields" {
  write_log
  run report
  assert_success
  [ "$(echo "$output" | jq -r '.by_agent[] | select(.agent == "p/two") | .calls')" = "1" ]
  [ "$(echo "$output" | jq -r '.by_agent[] | select(.agent == "p/two") | .delegate_cost_usd')" = "0.125" ]
  [ "$(echo "$output" | jq -r '.by_agent[] | select(.agent == "p/two") | .avoided_tokens_estimate')" = "8" ]
}

@test "the totals and by_tool sections are unchanged" {
  write_log
  run report
  assert_success
  [ "$(echo "$output" | jq -r '.calls')" = "4" ]
  [ "$(echo "$output" | jq -r '.by_tool | length')" = "2" ]
  [ "$(echo "$output" | jq -r '.by_tool[] | select(.tool == "bulk-read") | .calls')" = "3" ]
}
