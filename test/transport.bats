load 'test_helper'

setup() {
  shunt_test_setup
  source "$REPO_ROOT/scripts/lib/opencode.sh"
}

teardown() {
  shunt_test_teardown
}

# write_transcript <path> <jsonl-line>...
write_transcript() {
  local path="$1"
  shift
  printf '%s\n' "$@" >"$path"
}

# write_stub_opencode: a fake `opencode` that prints a fixed transcript.
write_stub_opencode() {
  mkdir -p "$TEST_TMPDIR/bin"
  cat >"$TEST_TMPDIR/bin/opencode" <<'FAKE'
#!/bin/bash
echo '{"type":"text","part":{"text":"stub answer"}}'
echo '{"type":"step_finish","part":{"reason":"stop","cost":0.25,"tokens":{"input":11,"output":4}}}'
FAKE
  chmod +x "$TEST_TMPDIR/bin/opencode"
  export SHUNT_OPENCODE_BIN="$TEST_TMPDIR/bin/opencode"
  mkdir -p "$SHUNT_OPENCODE_CONFIG_HOME/agents"
  printf -- '---\nmodel: p/m\n---\nagent\n' >"$SHUNT_OPENCODE_CONFIG_HOME/agents/a.md"
  shunt_write_provider p
}

@test "normalize keeps the last text part and reason and sums tokens and cost over every step" {
  local j="$TEST_TMPDIR/t.jsonl"
  write_transcript "$j" \
    '{"type":"text","part":{"text":"first"}}' \
    '{"type":"step_finish","part":{"reason":"tool-calls","cost":0.01,"tokens":{"input":1,"output":1}}}' \
    '{"type":"text","part":{"text":"final answer"}}' \
    '{"type":"step_finish","part":{"reason":"stop","cost":0.125,"tokens":{"input":100,"output":50}}}'
  run shunt_opencode_normalize "$j"
  assert_success
  [ "$(jq -r '.text' <<<"$output")" = "final answer" ]
  [ "$(jq -r '.finish_reason' <<<"$output")" = "stop" ]
  [ "$(jq -r '.usage.input' <<<"$output")" = "101" ]
  [ "$(jq -r '.usage.output' <<<"$output")" = "51" ]
  [ "$(jq -r '.cost' <<<"$output")" = "0.135" ]
}

@test "normalize counts cached prompt tokens as input and reasoning as output" {
  local j="$TEST_TMPDIR/t.jsonl"
  # A real second opencode call: most of the prompt came from the cache.
  write_transcript "$j" \
    '{"type":"text","part":{"text":"x"}}' \
    '{"type":"step_finish","part":{"reason":"stop","cost":0,"tokens":{"total":7129,"input":209,"output":8,"reasoning":5,"cache":{"write":3,"read":6912}}}}'
  run shunt_opencode_normalize "$j"
  assert_success
  [ "$(jq -r '.usage.input' <<<"$output")" = "7124" ]
  [ "$(jq -r '.usage.output' <<<"$output")" = "13" ]
}

@test "normalize treats non-numeric token fields as zero" {
  local j="$TEST_TMPDIR/t.jsonl"
  write_transcript "$j" \
    '{"type":"text","part":{"text":"x"}}' \
    '{"type":"step_finish","part":{"reason":"stop","tokens":{"input":"7","output":null,"cache":"none"}}}'
  run shunt_opencode_normalize "$j"
  assert_success
  [ "$(jq -c '.usage' <<<"$output")" = '{"input":0,"output":0}' ]
}

@test "normalize omits cost when the provider reported none" {
  local j="$TEST_TMPDIR/t.jsonl"
  write_transcript "$j" \
    '{"type":"text","part":{"text":"hi"}}' \
    '{"type":"step_finish","part":{"reason":"stop","tokens":{"input":2,"output":3}}}'
  run shunt_opencode_normalize "$j"
  assert_success
  [ "$(jq 'has("cost")' <<<"$output")" = "false" ]
  [ "$(jq -r '.usage.input' <<<"$output")" = "2" ]
}

@test "normalize passes a non-stop finish reason through" {
  local j="$TEST_TMPDIR/t.jsonl"
  write_transcript "$j" \
    '{"type":"text","part":{"text":"cut"}}' \
    '{"type":"step_finish","part":{"reason":"length","tokens":{"input":1,"output":9}}}'
  run shunt_opencode_normalize "$j"
  assert_success
  [ "$(jq -r '.finish_reason' <<<"$output")" = "length" ]
}

@test "normalize yields empty text, no finish reason and no usage for a transcript without text or step_finish" {
  local j="$TEST_TMPDIR/t.jsonl"
  write_transcript "$j" '{"type":"other"}'
  run shunt_opencode_normalize "$j"
  assert_success
  [ "$(jq -r '.text' <<<"$output")" = "" ]
  [ "$(jq -r '.finish_reason' <<<"$output")" = "" ]
  [ "$(jq 'has("usage")' <<<"$output")" = "false" ]
}

@test "normalize copes with output that is not JSON" {
  local j="$TEST_TMPDIR/t.jsonl"
  echo 'not json at all' >"$j"
  run shunt_opencode_normalize "$j"
  assert_success
  [ "$(jq -r '.text' <<<"$output")" = "" ]
}

@test "shunt_extract_usage prints cost=0 when the normalized file has no cost" {
  echo '{"text":"x","finish_reason":"stop","usage":{"input":5,"output":6}}' >"$TEST_TMPDIR/n.json"
  run shunt_extract_usage "$TEST_TMPDIR/n.json"
  assert_output "input=5 output=6 cost=0"
}

@test "shunt_extract_usage prints the reported cost" {
  echo '{"text":"x","finish_reason":"stop","usage":{"input":5,"output":6},"cost":0.5}' >"$TEST_TMPDIR/n.json"
  run shunt_extract_usage "$TEST_TMPDIR/n.json"
  assert_output "input=5 output=6 cost=0.5"
}

@test "shunt_extract_text fails on empty text" {
  echo '{"text":"","finish_reason":"stop","usage":{"input":0,"output":0}}' >"$TEST_TMPDIR/n.json"
  run shunt_extract_text "$TEST_TMPDIR/n.json"
  assert_failure
  assert_output --partial "could not extract assistant text"
}

@test "shunt_transport_invoke defaults to the opencode transport and returns a normalized file" {
  write_stub_opencode
  unset SHUNT_TRANSPORT
  run shunt_transport_invoke a "question"
  assert_success
  [ "$(jq -r '.text' "$output")" = "stub answer" ]
  [ "$(jq -r '.finish_reason' "$output")" = "stop" ]
  [ "$(jq -r '.usage.input' "$output")" = "11" ]
  [ "$(jq -r '.cost' "$output")" = "0.25" ]
}

@test "shunt_transport_invoke accepts opencode by name and refuses an unknown transport" {
  write_stub_opencode
  SHUNT_TRANSPORT=opencode run shunt_transport_invoke a "question"
  assert_success
  SHUNT_TRANSPORT=bogus run shunt_transport_invoke a "question"
  assert_failure
  assert_output --partial "unknown transport 'bogus'"
}

@test "shunt_transport_invoke maps a failing opencode to the ERROR status" {
  write_stub_opencode
  printf '#!/bin/bash\nexit 7\n' >"$TEST_TMPDIR/bin/opencode"
  run shunt_transport_invoke a "question"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
}

@test "shunt_transport_invoke maps empty opencode output to the EMPTY status" {
  write_stub_opencode
  printf '#!/bin/bash\nexit 0\n' >"$TEST_TMPDIR/bin/opencode"
  run shunt_transport_invoke a "question"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_EMPTY" ]
}

@test "shunt_extract_usage prints nothing when the response has no usage" {
  echo '{"text":"x","finish_reason":""}' >"$TEST_TMPDIR/n.json"
  run shunt_extract_usage "$TEST_TMPDIR/n.json"
  assert_success
  assert_output ""
}

@test "sourcing the libs by a relative path ignores CDPATH" {
  mkdir -p "$TEST_TMPDIR/cdp/scripts/lib"
  cd "$REPO_ROOT"
  run env CDPATH="$TEST_TMPDIR/cdp" bash -c 'source scripts/lib/opencode.sh && source scripts/lib/transport.sh && type shunt_transport_invoke >/dev/null && type _shunt_oc_py >/dev/null'
  assert_success
}
