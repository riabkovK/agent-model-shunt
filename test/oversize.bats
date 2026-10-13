load 'test_helper'
load 'http_fake'

bats_require_minimum_version 1.5.0

# Input too large for a model is not the model's fault: the model refuses with
# SHUNT_TRY_INVOKE_OVERSIZE, the failover loop moves on without a breaker
# failure, and when no model can take the input the call ends with a message
# telling Claude to read the file itself.

setup() {
  ORIG_PATH="$PATH"
  shunt_test_setup
  export SHUNT_PROVIDERS_FILE="$TEST_TMPDIR/providers.json"
  export TMPDIR="$TEST_TMPDIR/tmp"
  export FAKE_CURL_BODY="$TEST_TMPDIR/curl-body"
  export FAKE_OPENCODE_CALLS="$TEST_TMPDIR/opencode-calls"
  export ACME_KEY="sk-test-key"
  mkdir -p "$TMPDIR" "$TEST_TMPDIR/bin"
  write_fake_opencode
  PATH="$TEST_TMPDIR/bin:$PATH"
  source "$REPO_ROOT/scripts/lib/opencode.sh"
  unset SHUNT_TRANSPORT
  echo '{"choices":[{"message":{"content":"from http"},"finish_reason":"stop"}]}' >"$FAKE_CURL_BODY"
  fake_http_start
  jq -n --arg u "$FAKE_BASE" '{version:1,providers:{acme:{transport:"http",base_url:$u,
    key:{type:"env",ref:"ACME_KEY"}}}}' >"$SHUNT_PROVIDERS_FILE"
  # p/two runs through the opencode transport (no providers.json entry).
  mkdir -p "$SHUNT_AGENTS_DIR"
  printf -- '---\nmodel: p/two\n---\nagent\n' >"$SHUNT_AGENTS_DIR/shunt-bulk-reader-p-two.md"
  shunt_write_provider p
}

teardown() {
  stop_http_server
  PATH="$ORIG_PATH"
  shunt_test_teardown
}

# write_fake_opencode: records one line per call in FAKE_OPENCODE_CALLS and
# answers "from opencode".
write_fake_opencode() {
  cat >"$TEST_TMPDIR/bin/opencode" <<'SH'
#!/bin/bash
echo call >>"$FAKE_OPENCODE_CALLS"
echo '{"type":"text","part":{"text":"from opencode"}}'
echo '{"type":"step_finish","part":{"reason":"stop","tokens":{"input":1,"output":1}}}'
SH
  chmod +x "$TEST_TMPDIR/bin/opencode"
  export SHUNT_OPENCODE_BIN="$TEST_TMPDIR/bin/opencode"
}

# write_registry <models-json-array>
write_registry() {
  jq -n --argjson m "$1" '{version:1,active:$m[0].id,models:$m}' >"$SHUNT_MODELS_FILE"
}

HTTP_FAIL='{"id":"acme/m1","agent":"shunt-bulk-reader-acme-m1","context_tokens":1000,"oversize_policy":"fail"}'
OPENCODE_MODEL='{"id":"p/two","agent":"shunt-bulk-reader-p-two"}'

# make_file <path> <lines>: a file of that many short lines.
make_file() {
  seq 1 "$2" | sed 's/^/l/' >"$1"
}

opencode_calls() {
  [ -f "$FAKE_OPENCODE_CALLS" ] && wc -l <"$FAKE_OPENCODE_CALLS" | tr -d ' ' || echo 0
}

@test "an http model with oversize_policy fail refuses with OVERSIZE and sends nothing" {
  write_registry "[$HTTP_FAIL]"
  make_file "$TEST_TMPDIR/big.txt" 2000
  run shunt_transport_invoke shunt-bulk-reader-acme-m1 "q" "$TEST_TMPDIR/big.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]
  assert_output --partial "too large"
  [ "$(request_count)" -eq 0 ]
}

@test "an oversize refusal leaves the breaker untouched" {
  write_registry "[$HTTP_FAIL,$OPENCODE_MODEL]"
  make_file "$TEST_TMPDIR/big.txt" 1500
  shunt_invoke_with_failover "q" "$TEST_TMPDIR/big.txt" 2>/dev/null
  run shunt_breaker_status "acme/m1"
  assert_output "failures=0 open=false"
}

@test "failover moves from an oversize http model to the next model" {
  write_registry "[$HTTP_FAIL,$OPENCODE_MODEL]"
  make_file "$TEST_TMPDIR/big.txt" 1500
  shunt_invoke_with_failover "q" "$TEST_TMPDIR/big.txt" 2>"$TEST_TMPDIR/err"
  [ "$SHUNT_INVOKE_AGENT_USED" = "p/two" ]
  [ "$(shunt_extract_text "$SHUNT_INVOKE_OUT_FILE")" = "from opencode" ]
  [ "$(opencode_calls)" = 1 ]
  run cat "$TEST_TMPDIR/err"
  assert_output --partial "acme/m1 failed: input too large for this model"
  refute_output --partial "opencode error"
}

@test "the opencode transport refuses a file over the line limit without calling opencode" {
  write_registry "[$OPENCODE_MODEL]"
  make_file "$TEST_TMPDIR/big.txt" 2001
  run shunt_transport_invoke shunt-bulk-reader-p-two "q" "$TEST_TMPDIR/big.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]
  assert_output --partial "too large"
  [ "$(opencode_calls)" = 0 ]
}

@test "the opencode transport refuses a file over the byte limit without calling opencode" {
  write_registry "[$OPENCODE_MODEL]"
  head -c 51201 /dev/zero | tr '\0' 'x' | fold -w 100 >"$TEST_TMPDIR/big.txt"
  run shunt_transport_invoke shunt-bulk-reader-p-two "q" "$TEST_TMPDIR/big.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]
  [ "$(opencode_calls)" = 0 ]
}

@test "the opencode transport refuses a line longer than opencode keeps" {
  write_registry "[$OPENCODE_MODEL]"
  head -c 2001 /dev/zero | tr '\0' 'x' >"$TEST_TMPDIR/long.txt"
  echo >>"$TEST_TMPDIR/long.txt"
  run shunt_transport_invoke shunt-bulk-reader-p-two "q" "$TEST_TMPDIR/long.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]
  [ "$(opencode_calls)" = 0 ]
}

@test "the opencode transport refuses input over a known context budget" {
  write_registry '[{"id":"p/two","agent":"shunt-bulk-reader-p-two","context_tokens":1000}]'
  make_file "$TEST_TMPDIR/mid.txt" 500
  run shunt_transport_invoke shunt-bulk-reader-p-two "q" "$TEST_TMPDIR/mid.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]
  assert_output --partial "budget 600"
  [ "$(opencode_calls)" = 0 ]
}

@test "the opencode transport sends a file within its limits" {
  write_registry "[$OPENCODE_MODEL]"
  make_file "$TEST_TMPDIR/ok.txt" 100
  run shunt_transport_invoke shunt-bulk-reader-p-two "q" "$TEST_TMPDIR/ok.txt"
  assert_success
  [ "$(opencode_calls)" = 1 ]
}

@test "every candidate oversize ends with Claude reading the file itself" {
  write_registry "[$HTTP_FAIL,$OPENCODE_MODEL]"
  make_file "$TEST_TMPDIR/big.txt" 3486
  run shunt_invoke_with_failover "q" "$TEST_TMPDIR/big.txt"
  assert_failure
  assert_output --partial "no delegate model can take this input"
  assert_output --partial "Read the file directly"
  refute_output --partial "all delegate models in the registry failed"
  [ "$(opencode_calls)" = 0 ]
  run shunt_breaker_status "p/two"
  assert_output --partial "failures=0"
}

@test "a mix of oversize and real failures also ends with Claude reading the file" {
  write_registry "[$HTTP_FAIL,$OPENCODE_MODEL]"
  printf '#!/bin/bash\nexit 1\n' >"$TEST_TMPDIR/bin/opencode"
  make_file "$TEST_TMPDIR/big.txt" 1500
  run shunt_invoke_with_failover "q" "$TEST_TMPDIR/big.txt"
  assert_failure
  assert_output --partial "no delegate model can take this input"
  assert_output --partial "Read the file directly"
  run shunt_breaker_status "p/two"
  assert_output --partial "failures=1"
  run shunt_breaker_status "acme/m1"
  assert_output --partial "failures=0"
}

@test "the failure note names the reason per status and transport" {
  write_registry "[$HTTP_FAIL,$OPENCODE_MODEL]"
  run _shunt_note_failure "acme/m1" "$SHUNT_TRY_INVOKE_OVERSIZE" shunt-bulk-reader-acme-m1
  assert_output "shunt: acme/m1 failed: input too large for this model"
  run _shunt_note_failure "acme/m1" "$SHUNT_TRY_INVOKE_ERROR" shunt-bulk-reader-acme-m1
  assert_output "shunt: acme/m1 failed: HTTP request error"
  run _shunt_note_failure "p/two" "$SHUNT_TRY_INVOKE_ERROR" shunt-bulk-reader-p-two
  assert_output "shunt: p/two failed: opencode error"
}
