load 'test_helper'
load 'http_fake'

bats_require_minimum_version 1.5.0

setup() {
  ORIG_PATH="$PATH"
  shunt_test_setup
  export SHUNT_PROVIDERS_FILE="$TEST_TMPDIR/providers.json"
  export TMPDIR="$TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR" "$TEST_TMPDIR/bin"
  export FAKE_CURL_BODY="$TEST_TMPDIR/curl-body"
  unset FAKE_CURL_FAIL_AT
  export FAKE_CURL_CODE=200
  export FAKE_CURL_EXIT=0
  export ACME_KEY="sk-super-secret-value-123"
  SECRET="$ACME_KEY"
  PATH="$TEST_TMPDIR/bin:$PATH"
  source "$REPO_ROOT/scripts/lib/py.sh"
  export SHUNT_PROMPTS_DIR="$REPO_ROOT/prompts"
  unset SHUNT_TRANSPORT
  AGENT="shunt-bulk-reader-acme-m1"
  ok_body 'hello there' stop
  fake_http_start
  write_registry
  write_providers "https://api.acme.test/v1" '{"type":"env","ref":"ACME_KEY"}'
}

teardown() {
  stop_http_server
  PATH="$ORIG_PATH"
  shunt_test_teardown
}

# write_registry [request_body-json]
write_registry() {
  local rb="${1:-null}"
  jq -n --argjson rb "$rb" '{version:1,models:[
    ({id:"acme/m1",agent:"shunt-bulk-reader-acme-m1",enabled:true}
      + (if $rb == null then {} else {request_body:$rb} end))]}' >"$SHUNT_MODELS_FILE"
}

# write_providers <base_url> <key-json>: https://api.acme.test/v1 means the local fake provider.
write_providers() {
  local url="$1"
  # The default test URL stands for the local fake provider.
  [ "$url" != "https://api.acme.test/v1" ] || url="$FAKE_BASE"
  jq -n --arg u "$url" --argjson k "$2" \
    '{version:1,providers:{acme:{transport:"http",base_url:$u,key:$k}}}' >"$SHUNT_PROVIDERS_FILE"
}

# ok_body <text> <finish_reason> [extra-json-object-merged-into-root]
ok_body() {
  local extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  jq -n --arg t "$1" --arg f "$2" --argjson x "$extra" \
    '{choices:[{message:{role:"assistant",content:$t},finish_reason:$f}],
      usage:{prompt_tokens:12,completion_tokens:5}} + $x' >"$FAKE_CURL_BODY"
}

# write_registry_role <request_body-json> <role_request_body-json>
write_registry_role() {
  jq -n --argjson rb "$1" --argjson rrb "$2" '{version:1,models:[
    {id:"acme/m1",agent:"shunt-bulk-reader-acme-m1",enabled:true,request_body:$rb,role_request_body:$rrb}]}' >"$SHUNT_MODELS_FILE"
}

# write_registry_thinking <thinking> <thinking_options-json> <thinking_off_options-json> [request_body-json] [role_request_body-json]
write_registry_thinking() {
  jq -n --argjson t "$1" --argjson on "$2" --argjson off "$3" \
    --argjson rb "${4:-null}" --argjson rrb "${5:-null}" '{version:1,models:[
    ({id:"acme/m1",agent:"shunt-bulk-reader-acme-m1",enabled:true,
      thinking:$t,thinking_options:$on,thinking_off_options:$off}
      + (if $rb == null then {} else {request_body:$rb} end)
      + (if $rrb == null then {} else {role_request_body:$rrb} end))]}' >"$SHUNT_MODELS_FILE"
}

@test "rendered agent files carry the text of the prompts files" {
  export SHUNT_AGENTS_DIR="$TEST_TMPDIR/agents"
  shunt_py models materialize -- acme/m1
  tail -n 4 "$SHUNT_AGENTS_DIR/shunt-bulk-reader-acme-m1.md" | diff - "$REPO_ROOT/prompts/bulk-reader.md"
  tail -n 45 "$SHUNT_AGENTS_DIR/shunt-code-writer-acme-m1.md" | diff - "$REPO_ROOT/prompts/code-writer.md"
}

# The registry is resolved once per delegated call: the dispatcher, the system
# prompt and the request body all share one lookup of the model for the agent.
count_registry_lookups() {
  LOOKUPS_FILE="$TEST_TMPDIR/lookups"
  : >"$LOOKUPS_FILE"
  export FAKE_LOOKUPS="$LOOKUPS_FILE"
}

# Oversize guard. write_sized_registry <context_tokens|null> <oversize_policy|null>
# rewrites the registry with the two optional fields. big_question <chars> prints
# a question of that many bytes.
write_sized_registry() {
  jq -n --argjson ct "$1" --argjson op "$2" '{version:1,models:[
    {id:"acme/m1",agent:"shunt-bulk-reader-acme-m1",enabled:true}
      + (if $ct == null then {} else {context_tokens:$ct} end)
      + (if $op == null then {} else {oversize_policy:$op} end)]}' >"$SHUNT_MODELS_FILE"
}

big_question() {
  head -c "$1" /dev/zero | tr '\0' 'x'
}

# guard_size <context_tokens> <oversize_policy> <role> <bytes>: the size guard of
# transport_http.py on a resolved model (the guard moved from bash to Python).
guard_size() {
  python3 -B -c '
import sys
sys.path.insert(0, sys.argv[1])
from shunt import transport_http as t
setup = t._Setup("acme/m1", sys.argv[4], "acme", "http://x", False, {}, b"", sys.argv[2], sys.argv[3])
try:
    t._guard_size(setup, int(sys.argv[5]))
except t._Stop as stop:
    sys.exit(stop.status)
' "$REPO_ROOT/scripts/py" "$1" "$2" "$3" "$4"
}

# opencode_guard <agent> <question>: the size guard of the opencode transport (opencode_cli.py)
# on the registry entry of <agent>.
opencode_guard() {
  python3 -B -c '
import os, sys
sys.path.insert(0, sys.argv[1])
from shunt import opencode_cli, transport
from shunt import transport_reply as reply
found = transport.resolve(sys.argv[2], os.environ)
try:
    opencode_cli.guard_size(sys.argv[2], sys.argv[3], [], found.model_id, found.context_tokens)
except reply.Abort as stop:
    sys.exit(stop.status)
' "$REPO_ROOT/scripts/py" "$1" "$2"
}

@test "guard: an unknown oversize_policy at runtime is a config failure and sends nothing" {
  # Validation rejects such a registry, so exercise the guard on resolved state.
  run guard_size 1000 bogus bulk-reader 6000
  [ "$status" -eq 7 ]  # the config status of transport_reply.py
  assert_output --partial "invalid oversize_policy"
  [ "$(request_count)" -eq 0 ]
}

# map_reduce chunking. Model context 6000 tokens gives a 10800 byte budget (60
# percent, 3 bytes per token). make_lines <file> <count> writes count lines of
# exactly 100 bytes each ("L0001 xxx...").
make_lines() {
  awk -v n="$2" 'BEGIN { pad = sprintf("%93s", ""); gsub(/ /, "x", pad)
    for (i = 1; i <= n; i++) printf "L%04d %s\n", i, pad }' >"$1"
}

# sent_prompt <n>: the user message of the n-th request.
sent_prompt() {
  jq -r '.messages[1].content' "$FAKE_CURL_SENT.$1"
}

# utf8_line <file> <prefix-bytes> <char> [count]: one line of prefix-bytes "a",
# then the multi-byte char count (300) times, so a 200-byte split lands inside
# a character.
utf8_line() {
  local i
  { head -c "$2" /dev/zero | tr '\0' a
    for (( i = 0; i < ${4:-300}; i++ )); do printf '%s' "$3"; done
    printf '\n'; } >"$1"
}

@test "chunking: a line split by bytes never cuts a UTF-8 character" {
  local f="$TEST_TMPDIR/u.txt" ch k
  for ch in é я € 😀; do
    for k in 0 1 2 3; do
      utf8_line "$f" $(( 200 - k )) "$ch"
      chunk_py '
from shunt import chunk_plan as c
f, budget = sys.argv[1], 200
plan = c.plan_file(f, budget, 10**6)
assert len(plan) > 1
joined = b""
for i, (s, e, o, n) in enumerate(plan):
    piece = c.write_chunk(c.Chunk(f, s, e, o, n, i + 1, len(plan)))
    assert len(piece) <= budget
    piece.decode("utf-8")
    joined += piece
assert joined == open(f, "rb").read()' "$f"
    done
  done
}

# sent_text_bytes <n>: bytes of the decoded system and user messages of the
# n-th request, the size the oversize guard estimates tokens from.
sent_text_bytes() {
  jq -j '.messages[0].content + .messages[1].content' "$FAKE_CURL_SENT.$1" | wc -c
}

# ---- total deadline (SHUNT_TOTAL_TIMEOUT_SECONDS) ----------------------------

# use_fake_clock <seconds-per-request>: the transport's clock reads FAKE_CLOCK,
# which starts at 0 and only moves when a request is sent (test/fake_shunt_main.py).
use_fake_clock() {
  export FAKE_CLOCK="$TEST_TMPDIR/clock" FAKE_CURL_ADVANCE="$1"
  echo 0 >"$FAKE_CLOCK"
}

# ---- adversarial: hostile usage fields and breaker accounting -----------------

two_http_models() {
  jq -n '{version:1,models:[
    {id:"acme/m1",agent:"shunt-bulk-reader-acme-m1",enabled:true,priority:1},
    {id:"acme/m2",agent:"shunt-bulk-reader-acme-m2",enabled:true,priority:2}]}' >"$SHUNT_MODELS_FILE"
}

breaker_failures() {
  jq -r --arg k "$1" '.[$k].failures // .models[$k].failures // 0' "$SHUNT_BREAKER_STATE_FILE" 2>/dev/null || echo 0
}

# ---- fixes: usage cleaning, CONFIG status, bash 3.2 set -u ---------------------

@test "agg_add: a non-numeric value in a normalized file counts as 0 and runs nothing" {
  export SHUNT_PWNED="$TEST_TMPDIR/pwned"
  chunk_py '
from shunt import chunking
usage = chunking.Usage()
usage.add({"text": "t", "usage": {"input": "x[$(date>$SHUNT_PWNED)]", "output": "1.5"}})
assert (usage.tokens_in, usage.tokens_out) == (0, 0)'
  [ ! -e "$SHUNT_PWNED" ]
}

# ---- review fixes: auth temp file failure, status 1 wording, context_tokens ---

@test "guard: a non-plain context_tokens (1e30) is rejected by the registry validation" {
  write_sized_registry 1e30 null
  run shunt_py models validate
  [ "$status" -ne 0 ]
  assert_output --partial "invalid context_tokens"
}

@test "guard: a non-plain context_tokens reaching the guard returns CONFIG, no arithmetic error" {
  local v
  for v in 1e+30 1.5 -3 abc 1234567890123; do
    run --separate-stderr guard_size "$v" "" bulk-reader 100
    [ "$status" -eq 7 ]  # the config status of transport_reply.py
    [[ "$stderr" == *"invalid context_tokens"* ]]
    [[ "$stderr" != *"syntax error"* ]]
  done
}

# ---- adversary review of 6b9e6f6: config errors vs the breaker, key scrubbing ---

@test "adversary: a context_tokens of 128000.0 does not crash the opencode transport guard with an arithmetic error" {
  write_sized_registry 128000.0 null
  run shunt_py models validate
  assert_success
  run --separate-stderr opencode_guard "$AGENT" "q"
  [[ "$stderr" != *"syntax error"* ]]
  [[ "$stderr" != *"invalid"* ]]
  assert_success
}
