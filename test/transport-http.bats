load 'test_helper'

bats_require_minimum_version 1.5.0

setup() {
  ORIG_PATH="$PATH"
  shunt_test_setup
  export SHUNT_PROVIDERS_FILE="$TEST_TMPDIR/providers.json"
  export TMPDIR="$TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR" "$TEST_TMPDIR/bin"
  export FAKE_CURL_ARGV="$TEST_TMPDIR/curl-argv"
  export FAKE_CURL_SENT="$TEST_TMPDIR/curl-sent"
  export FAKE_CURL_HEADER_SEEN="$TEST_TMPDIR/curl-header-seen"
  export FAKE_CURL_HEADER_PATH="$TEST_TMPDIR/curl-header-path"
  export FAKE_CURL_BODY="$TEST_TMPDIR/curl-body"
  export FAKE_CURL_COUNT="$TEST_TMPDIR/curl-count"
  unset FAKE_CURL_FAIL_AT
  export FAKE_CURL_CODE=200
  export FAKE_CURL_EXIT=0
  export ACME_KEY="sk-super-secret-value-123"
  SECRET="$ACME_KEY"
  write_fake_curl
  PATH="$TEST_TMPDIR/bin:$PATH"
  source "$REPO_ROOT/scripts/lib/opencode.sh"
  unset SHUNT_TRANSPORT
  AGENT="shunt-bulk-reader-acme-m1"
  write_registry
  write_providers "https://api.acme.test/v1" '{"type":"env","ref":"ACME_KEY"}'
  ok_body 'hello there' stop
}

teardown() {
  PATH="$ORIG_PATH"
  shunt_test_teardown
}

# write_fake_curl: also counts requests (FAKE_CURL_COUNT), keeps every request
# body as $FAKE_CURL_SENT.<n>, and answers request FAKE_CURL_FAIL_AT with
# FAKE_CURL_FAIL_CODE instead of FAKE_CURL_CODE. Records argv (one arg per line), the request body file and the
# -H @file header file contents, and answers with FAKE_CURL_BODY / _CODE / _EXIT.
write_fake_curl() {
  cat >"$TEST_TMPDIR/bin/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >"$FAKE_CURL_ARGV"
out="" prev=""
for a in "$@"; do
  case "$prev" in
    -o) out="$a" ;;
    --data-binary) cp "${a#@}" "$FAKE_CURL_SENT" ;;
    -H) case "$a" in @*) echo "${a#@}" >"$FAKE_CURL_HEADER_PATH"; cp "${a#@}" "$FAKE_CURL_HEADER_SEEN" ;; esac ;;
  esac
  prev="$a"
done
n=$(( $(cat "$FAKE_CURL_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$FAKE_CURL_COUNT"
cp "$FAKE_CURL_SENT" "$FAKE_CURL_SENT.$n"
[ "$FAKE_CURL_EXIT" -eq 0 ] || exit "$FAKE_CURL_EXIT"
[ -z "$out" ] || cp "$FAKE_CURL_BODY" "$out"
if [ "$n" = "${FAKE_CURL_FAIL_AT:-}" ]; then printf '%s' "$FAKE_CURL_FAIL_CODE"; else printf '%s' "$FAKE_CURL_CODE"; fi
SH
  chmod +x "$TEST_TMPDIR/bin/curl"
}

# write_registry [request_body-json]
write_registry() {
  local rb="${1:-null}"
  jq -n --argjson rb "$rb" '{version:1,models:[
    ({id:"acme/m1",agent:"shunt-bulk-reader-acme-m1",enabled:true}
      + (if $rb == null then {} else {request_body:$rb} end))]}' >"$SHUNT_MODELS_FILE"
}

# write_providers <base_url> <key-json>
write_providers() {
  jq -n --arg u "$1" --argjson k "$2" \
    '{version:1,providers:{acme:{transport:"http",base_url:$u,key:$k}}}' >"$SHUNT_PROVIDERS_FILE"
}

# ok_body <text> <finish_reason> [extra-json-object-merged-into-root]
ok_body() {
  jq -n --arg t "$1" --arg f "$2" --argjson x "${3:-{\}}" \
    '{choices:[{message:{role:"assistant",content:$t},finish_reason:$f}],
      usage:{prompt_tokens:12,completion_tokens:5}} + $x' >"$FAKE_CURL_BODY"
}

@test "success returns the normalized response without cost" {
  run shunt_transport_invoke "$AGENT" "the question"
  assert_success
  [ "$(jq -r '.text' "$output")" = "hello there" ]
  [ "$(jq -r '.finish_reason' "$output")" = "stop" ]
  [ "$(jq -r '.usage.input' "$output")" = "12" ]
  [ "$(jq -r '.usage.output' "$output")" = "5" ]
  [ "$(jq 'has("cost")' "$output")" = "false" ]
}

@test "cost is included when the provider sent one" {
  ok_body 'hi' stop '{"usage":{"prompt_tokens":1,"completion_tokens":2,"cost":0.0125}}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(jq -r '.cost' "$output")" = "0.0125" ]
}

@test "posts to base_url/chat/completions with the model, prompt and no max_tokens" {
  run shunt_transport_invoke "$AGENT" "the question"
  assert_success
  grep -qx 'https://api.acme.test/v1/chat/completions' "$FAKE_CURL_ARGV"
  [ "$(jq -r '.model' "$FAKE_CURL_SENT")" = "m1" ]
  [ "$(jq -r '.messages[1].role' "$FAKE_CURL_SENT")" = "user" ]
  [ "$(jq -r '.messages[1].content' "$FAKE_CURL_SENT")" = "the question" ]
  [ "$(jq 'has("max_tokens")' "$FAKE_CURL_SENT")" = "false" ]
  [ "$(jq 'has("stream")' "$FAKE_CURL_SENT")" = "false" ]
}

@test "attached files are appended to the prompt" {
  printf 'file body line\n' >"$TEST_TMPDIR/f.txt"
  run shunt_transport_invoke "$AGENT" "the question" "$TEST_TMPDIR/f.txt"
  assert_success
  jq -r '.messages[1].content' "$FAKE_CURL_SENT" | grep -q 'file body line'
}

@test "request_body from the registry is merged verbatim" {
  write_registry '{"temperature":0.2,"reasoning":{"effort":"low"}}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(jq -r '.temperature' "$FAKE_CURL_SENT")" = "0.2" ]
  [ "$(jq -r '.reasoning.effort' "$FAKE_CURL_SENT")" = "low" ]
  [ "$(jq -r '.model' "$FAKE_CURL_SENT")" = "m1" ]
}

@test "request_body cannot replace the model or messages" {
  write_registry '{"model":"evil","messages":[]}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(jq -r '.model' "$FAKE_CURL_SENT")" = "m1" ]
  [ "$(jq -r '.messages | length' "$FAKE_CURL_SENT")" = "2" ]
}

@test "the bulk-reader agent sends prompts/bulk-reader.md as the system message" {
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(jq -r '.messages[0].role' "$FAKE_CURL_SENT")" = "system" ]
  [ "$(jq -r '.messages[0].content' "$FAKE_CURL_SENT")" = "$(<"$REPO_ROOT/prompts/bulk-reader.md")" ]
}

@test "the code-writer agent sends prompts/code-writer.md as the system message" {
  run shunt_transport_invoke "shunt-code-writer-acme-m1" "q"
  assert_success
  [ "$(jq -r '.messages[0].role' "$FAKE_CURL_SENT")" = "system" ]
  [ "$(jq -r '.messages[0].content' "$FAKE_CURL_SENT")" = "$(<"$REPO_ROOT/prompts/code-writer.md")" ]
  jq -r '.messages[0].content' "$FAKE_CURL_SENT" | grep -q '^<SHUNT-CODE>$'
}

@test "a missing role prompt file is a config error and sends no request" {
  export SHUNT_PROMPTS_DIR="$TEST_TMPDIR/no-prompts"
  run shunt_transport_invoke "$AGENT" "q"
  assert_failure 1
  assert_output --partial "bulk-reader prompt is missing"
  [ ! -e "$FAKE_CURL_ARGV" ]
}

@test "rendered agent files carry the text of the prompts files" {
  export SHUNT_AGENTS_DIR="$TEST_TMPDIR/agents"
  shunt_models_materialize_agent acme/m1
  tail -n 4 "$SHUNT_AGENTS_DIR/shunt-bulk-reader-acme-m1.md" | diff - "$REPO_ROOT/prompts/bulk-reader.md"
  tail -n 45 "$SHUNT_AGENTS_DIR/shunt-code-writer-acme-m1.md" | diff - "$REPO_ROOT/prompts/code-writer.md"
}

@test "the key is only in the header file, never in argv, and there is no -L" {
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  ! grep -qF "$SECRET" "$FAKE_CURL_ARGV"
  ! grep -qx -- '-L' "$FAKE_CURL_ARGV"
  ! grep -qx -- '--location' "$FAKE_CURL_ARGV"
  grep -qx -- '--max-time' "$FAKE_CURL_ARGV"
  grep -qx -- '--data-binary' "$FAKE_CURL_ARGV"
  grep -qF "Authorization: Bearer $SECRET" "$FAKE_CURL_HEADER_SEEN"
}

@test "the header file and temp files are removed after success" {
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ ! -e "$(cat "$FAKE_CURL_HEADER_PATH")" ]
  # Only the normalized output file remains in TMPDIR.
  [ "$(ls "$TMPDIR" | wc -l)" -eq 1 ]
}

@test "the header file and temp files are removed after a failure" {
  FAKE_CURL_CODE=500 run shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  [ ! -e "$(cat "$FAKE_CURL_HEADER_PATH")" ]
  [ "$(ls "$TMPDIR" | wc -l)" -eq 0 ]
}

@test "a key type none sends no Authorization header" {
  write_providers "https://api.acme.test/v1" '{"type":"none"}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ ! -e "$FAKE_CURL_HEADER_SEEN" ]
}

@test "curl exit 28 maps to the TIMEOUT status" {
  FAKE_CURL_EXIT=28 run shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_TIMEOUT" ]
}

@test "another curl failure maps to the ERROR status" {
  FAKE_CURL_EXIT=7 run shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  refute_output --partial "$SECRET"
}

@test "429 and 5xx map to the ERROR status" {
  local code
  for code in 429 500 502 503; do
    FAKE_CURL_CODE=$code run shunt_transport_invoke "$AGENT" "q"
    [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  done
}

@test "400, 404 and 413 map to ERROR with a sanitized truncated body excerpt" {
  local code long
  long=$(printf 'x%.0s' $(seq 1 1000))
  printf '{"error":"bad\x1b[31m request %s %s"}' "$SECRET" "$long" >"$FAKE_CURL_BODY"
  for code in 400 404 413; do
    FAKE_CURL_CODE=$code run --separate-stderr shunt_transport_invoke "$AGENT" "q"
    [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
    [[ "$stderr" == *"bad"* ]]
    [[ "$stderr" != *"$SECRET"* ]]
    [[ "$stderr" != *$'\x1b'* ]]
    [ "${#stderr}" -lt 500 ]
  done
}

@test "401 and 403 map to the AUTH status with a check-key message" {
  local code
  for code in 401 403; do
    FAKE_CURL_CODE=$code run --separate-stderr shunt_transport_invoke "$AGENT" "q"
    [ "$status" -eq "$SHUNT_TRY_INVOKE_AUTH" ]
    [[ "$stderr" == *"auth failed for provider acme, check key via model-config"* ]]
    [[ "$stderr" != *"$SECRET"* ]]
  done
}

@test "empty text maps to the EMPTY status" {
  ok_body '' stop
  run shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_EMPTY" ]
}

@test "a finish_reason other than stop is a model failure" {
  ok_body 'cut off' length
  run shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
}

@test "a 200 with a body that is not a chat completion is a model failure" {
  echo 'not json' >"$FAKE_CURL_BODY"
  run shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
}

@test "explicit http is allowed for a non-loopback host" {
  write_providers "http://api.acme.test/v1" '{"type":"none"}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  grep -qFx 'http://api.acme.test/v1/chat/completions' "$FAKE_CURL_ARGV"
}

@test "a scheme-less base_url gets https prepended and curl receives it" {
  local url
  for url in api.acme.test/v1 10.0.0.5:8000/v1 acme.test; do
    write_providers "$url" '{"type":"none"}'
    run shunt_transport_invoke "$AGENT" "q"
    assert_success
    grep -qFx "https://${url%/}/chat/completions" "$FAKE_CURL_ARGV"
  done
}

@test "a scheme-less base_url that cannot be reached names the provider and URL" {
  write_providers "10.0.0.5:8000/v1" '{"type":"none"}'
  FAKE_CURL_EXIT=7
  run shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  assert_output --partial "provider 'acme': cannot reach https://10.0.0.5:8000/v1"
  assert_output --partial "https was assumed"
}

@test "an explicit http base_url that cannot be reached has no https hint" {
  write_providers "http://10.0.0.5:8000/v1" '{"type":"none"}'
  FAKE_CURL_EXIT=7
  run shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  refute_output --partial "https was assumed"
}

@test "http is allowed for loopback hosts" {
  local url
  for url in http://localhost:11434/v1 http://127.0.0.1:8000/v1 'http://[::1]:8000/v1'; do
    write_providers "$url" '{"type":"none"}'
    run shunt_transport_invoke "$AGENT" "q"
    assert_success
    grep -qFx "$url/chat/completions" "$FAKE_CURL_ARGV"
  done
}

@test "a userinfo trick cannot pass as loopback" {
  write_providers "http://localhost@evil.test/v1" '{"type":"none"}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_failure
  [ ! -e "$FAKE_CURL_ARGV" ]
}

@test "other schemes and a missing base_url are refused" {
  write_providers "ftp://api.acme.test/v1" '{"type":"none"}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_failure
  write_providers "" '{"type":"none"}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_failure
  [ ! -e "$FAKE_CURL_ARGV" ]
}

@test "a missing key is a config failure and makes no request" {
  unset ACME_KEY
  run shunt_transport_invoke "$AGENT" "q"
  assert_failure
  [ ! -e "$FAKE_CURL_ARGV" ]
}

@test "dispatch: a model whose provider has transport opencode uses opencode" {
  jq -n '{version:1,providers:{acme:{transport:"opencode"}}}' >"$SHUNT_PROVIDERS_FILE"
  printf '#!/bin/bash\necho OC\n' >"$TEST_TMPDIR/bin/opencode"
  chmod +x "$TEST_TMPDIR/bin/opencode"
  export SHUNT_OPENCODE_BIN="$TEST_TMPDIR/bin/opencode"
  mkdir -p "$SHUNT_AGENTS_DIR"
  printf -- '---\nmodel: acme/m1\n---\n' >"$SHUNT_AGENTS_DIR/$AGENT.md"
  run shunt_transport_invoke "$AGENT" "q"
  [ ! -e "$FAKE_CURL_ARGV" ]
}

@test "dispatch: a missing providers.json means opencode" {
  rm -f "$SHUNT_PROVIDERS_FILE"
  run shunt_transport_for_agent "$AGENT"
  assert_output "opencode"
}

@test "dispatch: a model without a provider entry means opencode" {
  jq -n '{version:1,providers:{other:{transport:"http"}}}' >"$SHUNT_PROVIDERS_FILE"
  run shunt_transport_for_agent "$AGENT"
  assert_output "opencode"
}

@test "dispatch: an agent that is not in the registry means opencode" {
  run shunt_transport_for_agent "legacy-agent"
  assert_output "opencode"
}

@test "dispatch: the SHUNT_TRANSPORT override wins over the provider" {
  SHUNT_TRANSPORT=opencode run shunt_transport_for_agent "$AGENT"
  assert_output "opencode"
}

@test "dispatch: an http provider selects http" {
  run shunt_transport_for_agent "$AGENT"
  assert_output "http"
}

@test "dispatch: the code-writer agent of a model resolves to the same provider" {
  run shunt_transport_for_agent "shunt-code-writer-acme-m1"
  assert_output "http"
}

@test "failover: an auth failure skips to the next model and is not recorded in the breaker" {
  jq -n '{version:1,models:[
    {id:"acme/m1",agent:"shunt-bulk-reader-acme-m1",enabled:true,priority:1},
    {id:"acme/m2",agent:"shunt-bulk-reader-acme-m2",enabled:true,priority:2}]}' >"$SHUNT_MODELS_FILE"
  # First call gets 401, the second 200.
  cat >"$TEST_TMPDIR/bin/curl" <<'SH'
#!/bin/bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
n=$(cat "$FAKE_CURL_COUNT" 2>/dev/null || echo 0); echo $((n + 1)) >"$FAKE_CURL_COUNT"
if [ "$n" -eq 0 ]; then printf '{}' >"$out"; printf 401; else cp "$FAKE_CURL_BODY" "$out"; printf 200; fi
SH
  export FAKE_CURL_COUNT="$TEST_TMPDIR/count"
  shunt_invoke_role_with_failover bulk-read shunt_models_agent_for "" "q"
  [ "$SHUNT_INVOKE_AGENT_USED" = "acme/m2" ]
  [ "$(jq -r '.text' "$SHUNT_INVOKE_OUT_FILE")" = "hello there" ]
  run shunt_breaker_is_open "acme/m1"
  assert_failure
  run bash -c "cat '$SHUNT_BREAKER_STATE_FILE' 2>/dev/null | jq -r 'keys[]?' | grep -c 'acme/m1'"
  assert_output "0"
}

# The registry is resolved once per delegated call: the dispatcher, the system
# prompt and the request body all share one lookup of the model for the agent.
count_registry_lookups() {
  LOOKUPS_FILE="$TEST_TMPDIR/lookups"
  : >"$LOOKUPS_FILE"
  eval "_orig_$(declare -f shunt_models_available)"
  shunt_models_available() { echo x >>"$LOOKUPS_FILE"; _orig_shunt_models_available "$@"; }
}

@test "one bulk-reader call looks the model up in the registry exactly once" {
  count_registry_lookups
  shunt_transport_invoke "$AGENT" "q"
  [ "$(wc -l <"$LOOKUPS_FILE")" -eq 1 ]
}

@test "one code-writer call looks the model up in the registry exactly once" {
  count_registry_lookups
  shunt_transport_invoke "shunt-code-writer-acme-m1" "q"
  [ "$(wc -l <"$LOOKUPS_FILE")" -eq 1 ]
}

@test "a second call after the registry changed does not reuse the old lookup" {
  shunt_transport_invoke "$AGENT" "q"
  write_registry '{"reasoning_effort":"none"}'
  shunt_transport_invoke "$AGENT" "q"
  [ "$(jq -r '.reasoning_effort' "$FAKE_CURL_SENT")" = "none" ]
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

@test "guard: a request within 60 percent of context_tokens is sent" {
  write_sized_registry 100000 '"fail"'
  run shunt_transport_invoke "$AGENT" "$(big_question 6000)"
  assert_success
  [ -f "$FAKE_CURL_SENT" ]
}

@test "guard: too big with oversize_policy fail returns ERROR and sends nothing" {
  write_sized_registry 1000 '"fail"'
  run shunt_transport_invoke "$AGENT" "$(big_question 6000)"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  assert_output --partial "acme/m1"
  assert_output --partial "too large"
  assert_output --partial "budget 600"
  [ ! -f "$FAKE_CURL_ARGV" ]
}

@test "guard: a question that alone exceeds the budget fails without chunking (no policy)" {
  write_sized_registry 1000 null
  run shunt_transport_invoke "$AGENT" "$(big_question 6000)"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  assert_output --partial "leave no room"
  refute_output --partial "not implemented"
  [ ! -f "$FAKE_CURL_ARGV" ]
}

@test "guard: explicit fail does not mention chunking" {
  write_sized_registry 1000 '"fail"'
  run shunt_transport_invoke "$AGENT" "$(big_question 6000)"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  refute_output --partial "chunk"
}

@test "resolve: an entry without an agent keeps its later columns" {
  jq -n '{version:1,models:[{id:"acme/m1",enabled:true,context_tokens:1000,
    request_body:{reasoning_effort:"low"},oversize_policy:"fail"}]}' >"$SHUNT_MODELS_FILE"
  _shunt_http_resolve "shunt-code-writer-acme-m1"
  [ "$_SHUNT_HTTP_ID" = "acme/m1" ]
  [ "$_SHUNT_HTTP_ROLE" = code-writer ]
  [ "$_SHUNT_HTTP_REQUEST_BODY" = '{"reasoning_effort":"low"}' ]
  [ "$_SHUNT_HTTP_CONTEXT_TOKENS" = 1000 ]
  [ "$_SHUNT_HTTP_OVERSIZE_POLICY" = fail ]
}

@test "guard: a question that alone exceeds the budget fails without chunking (map_reduce)" {
  write_sized_registry 1000 '"map_reduce"'
  run shunt_transport_invoke "$AGENT" "$(big_question 6000)"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  assert_output --partial "leave no room"
  [ ! -f "$FAKE_CURL_ARGV" ]
}

@test "guard: the code-writer role always fails when too big, even with map_reduce" {
  write_sized_registry 1000 '"map_reduce"'
  run shunt_transport_invoke "shunt-code-writer-acme-m1" "$(big_question 6000)"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  assert_output --partial "too large"
  refute_output --partial "not implemented"
  [ ! -f "$FAKE_CURL_ARGV" ]
}

@test "guard: no context_tokens and a small request is sent" {
  write_sized_registry null null
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ -f "$FAKE_CURL_SENT" ]
}

@test "guard: no context_tokens and a big request fails with the config message" {
  write_sized_registry null '"fail"'
  run shunt_transport_invoke "$AGENT" "$(big_question 20000)"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  assert_output --partial "model acme/m1 has no context_tokens"
  assert_output --partial "shunt-models detect-context acme/m1 --write"
  assert_output --partial "shunt-models set-context acme/m1 <tokens>"
  [ ! -f "$FAKE_CURL_ARGV" ]
}

@test "guard: an unknown oversize_policy at runtime is a config failure and sends nothing" {
  # Validation rejects such a registry, so exercise the guard on resolved state.
  _SHUNT_HTTP_ID="acme/m1" _SHUNT_HTTP_ROLE=bulk-reader
  _SHUNT_HTTP_CONTEXT_TOKENS=1000 _SHUNT_HTTP_OVERSIZE_POLICY=bogus
  run _shunt_http_guard_size 6000
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  assert_output --partial "invalid oversize_policy"
  [ ! -f "$FAKE_CURL_ARGV" ]
}

@test "guard: the size check does not add a registry lookup" {
  write_sized_registry 1000 '"fail"'
  count_registry_lookups
  shunt_transport_invoke "$AGENT" "$(big_question 6000)" || true
  [ "$(wc -l <"$LOOKUPS_FILE")" -eq 1 ]
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

request_count() {
  cat "$FAKE_CURL_COUNT" 2>/dev/null || echo 0
}

@test "chunking: one big file gives n chunk requests plus one merge request" {
  write_sized_registry 6000 null
  make_lines "$TEST_TMPDIR/big.txt" 300
  run --separate-stderr shunt_transport_invoke "$AGENT" "the question" "$TEST_TMPDIR/big.txt"
  assert_success
  [ "$(request_count)" -eq 5 ]
  sent_prompt 1 | grep -q "part 1 of 4 of $TEST_TMPDIR/big.txt, lines 1-"
  sent_prompt 4 | grep -q "part 4 of 4 of $TEST_TMPDIR/big.txt, lines .*-300"
  sent_prompt 5 | grep -q "the question"
  sent_prompt 5 | grep -q "partial answer 4 of 4"
  [ "$(jq -r '.text' "$output")" = "hello there" ]
  [ "$(jq -r '.finish_reason' "$output")" = "stop" ]
}

@test "chunking: neighbouring chunks overlap by 20 lines" {
  write_sized_registry 6000 null
  make_lines "$TEST_TMPDIR/big.txt" 300
  run shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  assert_success
  local end1 start2
  end1=$(sent_prompt 1 | grep -o '^L[0-9]*' | tail -n1 | tr -d L)
  start2=$(sent_prompt 2 | grep -o '^L[0-9]*' | head -n1 | tr -d L)
  [ $(( 10#$end1 - 10#$start2 + 1 )) -eq 20 ]
}

@test "chunking: files that fit alone but not together are never mixed" {
  write_sized_registry 6000 null
  make_lines "$TEST_TMPDIR/a.txt" 60
  make_lines "$TEST_TMPDIR/b.txt" 60
  run shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/a.txt" "$TEST_TMPDIR/b.txt"
  assert_success
  [ "$(request_count)" -eq 3 ]
  sent_prompt 1 | grep -q -- "--- file: $TEST_TMPDIR/a.txt ---"
  ! sent_prompt 1 | grep -q "b.txt ---"
  sent_prompt 2 | grep -q -- "--- file: $TEST_TMPDIR/b.txt ---"
  ! sent_prompt 2 | grep -q "a.txt ---"
  sent_prompt 1 | grep -q "part 1 of 1 of $TEST_TMPDIR/a.txt"
}

@test "chunking: two files that fit together go in one request" {
  write_sized_registry 6000 null
  make_lines "$TEST_TMPDIR/a.txt" 40
  make_lines "$TEST_TMPDIR/b.txt" 40
  run shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/a.txt" "$TEST_TMPDIR/b.txt"
  assert_success
  [ "$(request_count)" -eq 1 ]
}

@test "chunking: a line longer than the budget is split by bytes" {
  write_sized_registry 6000 null
  head -c 30000 /dev/zero | tr '\0' 'y' >"$TEST_TMPDIR/long.txt"
  run shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/long.txt"
  assert_success
  [ "$(request_count)" -ge 4 ]
  sent_prompt 1 | grep -q "line 1, bytes 1-"
}

@test "chunking: usage and cost are summed over every request" {
  write_sized_registry 6000 null
  ok_body 'part' stop '{"usage":{"prompt_tokens":12,"completion_tokens":5,"cost":0.01}}'
  make_lines "$TEST_TMPDIR/big.txt" 300
  run --separate-stderr shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  assert_success
  [ "$(jq -r '.usage.input' "$output")" -eq 60 ]
  [ "$(jq -r '.usage.output' "$output")" -eq 25 ]
  [ "$(jq -r '.cost' "$output")" = "0.05" ]
}

@test "chunking: a failing chunk aborts and later chunks are not requested" {
  write_sized_registry 6000 null
  make_lines "$TEST_TMPDIR/big.txt" 300
  FAKE_CURL_FAIL_AT=2 FAKE_CURL_FAIL_CODE=500 run shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  [ "$(request_count)" -eq 2 ]
}

@test "chunking: an auth failure in a chunk keeps the AUTH status" {
  write_sized_registry 6000 null
  make_lines "$TEST_TMPDIR/big.txt" 300
  FAKE_CURL_FAIL_AT=1 FAKE_CURL_FAIL_CODE=401 run shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_AUTH" ]
  [ "$(request_count)" -eq 1 ]
}

@test "chunking: a failing merge request fails the call" {
  write_sized_registry 6000 null
  make_lines "$TEST_TMPDIR/big.txt" 300
  FAKE_CURL_FAIL_AT=5 FAKE_CURL_FAIL_CODE=500 run shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
}

@test "chunking: partial answers too big for one merge are merged in groups" {
  write_sized_registry 6000 null
  ok_body "$(big_question 3000)" stop
  make_lines "$TEST_TMPDIR/big.txt" 300
  run shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  assert_success
  # 4 chunks, one group merge of 3 partials (the 4th is carried over), 1 final merge
  [ "$(request_count)" -eq 6 ]
}

@test "chunking: merging deeper than the depth cap fails with a model failure" {
  write_sized_registry 6000 null
  # Two partials fit in one merge request, three do not: 17 chunks need 4 rounds.
  ok_body "$(big_question 4000)" stop
  make_lines "$TEST_TMPDIR/big.txt" 1500
  run shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  assert_output --partial "merge"
  assert_output --partial "depth"
}

@test "chunking: the code-writer role still fails when too big" {
  write_sized_registry 6000 null
  make_lines "$TEST_TMPDIR/big.txt" 300
  run shunt_transport_invoke "shunt-code-writer-acme-m1" "q" "$TEST_TMPDIR/big.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  [ ! -f "$FAKE_CURL_ARGV" ]
}

@test "chunking: explicit fail policy sends nothing for a big file" {
  write_sized_registry 6000 '"fail"'
  make_lines "$TEST_TMPDIR/big.txt" 300
  run shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  [ ! -f "$FAKE_CURL_ARGV" ]
}

@test "chunking: adds no registry lookups" {
  write_sized_registry 6000 null
  make_lines "$TEST_TMPDIR/big.txt" 300
  count_registry_lookups
  shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  [ "$(wc -l <"$LOOKUPS_FILE")" -eq 1 ]
}

@test "chunking: leaves no temp files behind, on success or failure" {
  write_sized_registry 6000 null
  make_lines "$TEST_TMPDIR/big.txt" 300
  shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt" >/dev/null
  FAKE_CURL_FAIL_AT=3 FAKE_CURL_FAIL_CODE=500 shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt" || true
  [ -z "$(find "$TMPDIR" -name 'shunt-http.*')" ]
}

@test "chunking: more chunks than the limit fails before any request" {
  write_sized_registry 6000 null
  make_lines "$TEST_TMPDIR/huge.txt" 12000
  run shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/huge.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  assert_output --partial "limit"
  [ ! -f "$FAKE_CURL_ARGV" ]
}
