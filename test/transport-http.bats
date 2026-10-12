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
# body as $FAKE_CURL_SENT.<n> and argv as $FAKE_CURL_ARGV.<n>, advances the fake
# clock file FAKE_CLOCK (when set) by FAKE_CURL_ADVANCE seconds, and answers request FAKE_CURL_FAIL_AT with
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
cp "$FAKE_CURL_ARGV" "$FAKE_CURL_ARGV.$n"
[ -z "${FAKE_CLOCK:-}" ] || echo $(( $(cat "$FAKE_CLOCK") + ${FAKE_CURL_ADVANCE:-0} )) >"$FAKE_CLOCK"
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

# write_registry_role <request_body-json> <role_request_body-json>
write_registry_role() {
  jq -n --argjson rb "$1" --argjson rrb "$2" '{version:1,models:[
    {id:"acme/m1",agent:"shunt-bulk-reader-acme-m1",enabled:true,request_body:$rb,role_request_body:$rrb}]}' >"$SHUNT_MODELS_FILE"
}

@test "role_request_body of the bulk-read role wins over request_body and keeps the other keys" {
  write_registry_role '{"temperature":0.2,"reasoning_effort":"high"}' '{"bulk-read":{"reasoning_effort":"none"},"code-write":{"temperature":0.9}}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(jq -r '.reasoning_effort' "$FAKE_CURL_SENT")" = "none" ]
  [ "$(jq -r '.temperature' "$FAKE_CURL_SENT")" = "0.2" ]
}

@test "role_request_body of the code-write role applies to the code-writer agent only" {
  write_registry_role '{"temperature":0.2}' '{"bulk-read":{"reasoning_effort":"none"},"code-write":{"temperature":0.9}}'
  run shunt_transport_invoke "shunt-code-writer-acme-m1" "q"
  assert_success
  [ "$(jq -r '.temperature' "$FAKE_CURL_SENT")" = "0.9" ]
  [ "$(jq -r 'has("reasoning_effort")' "$FAKE_CURL_SENT")" = "false" ]
}

@test "role_request_body without an entry for the role leaves request_body as is" {
  write_registry_role '{"temperature":0.2}' '{"code-write":{"temperature":0.9}}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(jq -r '.temperature' "$FAKE_CURL_SENT")" = "0.2" ]
}

@test "role_request_body cannot replace the model or messages" {
  write_registry_role '{}' '{"bulk-read":{"model":"evil","messages":[]}}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(jq -r '.model' "$FAKE_CURL_SENT")" = "m1" ]
  [ "$(jq -r '.messages | length' "$FAKE_CURL_SENT")" = "2" ]
}

@test "a role_request_body that is not an object of objects is a config error" {
  write_registry_role '{}' '{"bulk-read":"none"}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_failure
  assert_output --partial "role_request_body must be a JSON object of JSON objects"
  write_registry_role '{}' '[1]'
  run shunt_transport_invoke "$AGENT" "q"
  assert_failure
  assert_output --partial "role_request_body must be a JSON object of JSON objects"
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

@test "thinking off sends thinking_off_options translated to snake_case body fields" {
  write_registry_thinking false null '{"reasoningEffort":"none"}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(jq -r '.reasoning_effort' "$FAKE_CURL_SENT")" = "none" ]
  [ "$(jq 'has("reasoningEffort")' "$FAKE_CURL_SENT")" = "false" ]
}

@test "thinking off without off options adds no thinking field" {
  write_registry_thinking false '{"reasoningEffort":"high"}' null
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(jq -c 'del(.model, .messages)' "$FAKE_CURL_SENT")" = "{}" ]
}

@test "thinking on sends thinking_options and ignores the off options" {
  write_registry_thinking true '{"reasoningEffort":"high","budgetTokens":2048}' '{"reasoningEffort":"none"}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(jq -r '.reasoning_effort' "$FAKE_CURL_SENT")" = "high" ]
  [ "$(jq -r '.budget_tokens' "$FAKE_CURL_SENT")" = "2048" ]
}

@test "thinking on with null options adds no thinking field" {
  write_registry_thinking true null '{"reasoningEffort":"none"}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(jq -c 'del(.model, .messages)' "$FAKE_CURL_SENT")" = "{}" ]
}

@test "a thinking-derived field wins over the same field in request_body, other fields stay" {
  write_registry_thinking false null '{"reasoningEffort":"none"}' '{"reasoning_effort":"low","temperature":0.2}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(jq -r '.reasoning_effort' "$FAKE_CURL_SENT")" = "none" ]
  [ "$(jq -r '.temperature' "$FAKE_CURL_SENT")" = "0.2" ]
}

@test "thinking on: the on options win over request_body.reasoning_effort" {
  write_registry_thinking true '{"reasoningEffort":"high"}' '{"reasoningEffort":"none"}' '{"reasoning_effort":"low"}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(jq -r '.reasoning_effort' "$FAKE_CURL_SENT")" = "high" ]
}

@test "role_request_body overrides both request_body and thinking-derived fields" {
  write_registry_thinking false null '{"reasoningEffort":"none","topK":5}' '{"reasoning_effort":"low"}' \
    '{"bulk-read":{"reasoning_effort":"medium"}}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(jq -r '.reasoning_effort' "$FAKE_CURL_SENT")" = "medium" ]
  [ "$(jq -r '.top_k' "$FAKE_CURL_SENT")" = "5" ]
}

@test "thinking options that are not an object are a config error" {
  write_registry_thinking false null '"none"'
  run shunt_transport_invoke "$AGENT" "q"
  assert_failure
  assert_output --partial "thinking_off_options must be a JSON object"
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
  assert_failure "$SHUNT_TRY_INVOKE_CONFIG"
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

@test "401 and 403 map to the AUTH status with a re-enter-key message" {
  local code
  for code in 401 403; do
    FAKE_CURL_CODE=$code run --separate-stderr shunt_transport_invoke "$AGENT" "q"
    [ "$status" -eq "$SHUNT_TRY_INVOKE_AUTH" ]
    [[ "$stderr" == *"auth failed for provider acme"* ]]
    # Absolute path: hooks run in the user's project, not the plugin root.
    [[ "$stderr" == *"/model-config"* ]]
    [[ "$stderr" == *"! $REPO_ROOT/scripts/shunt-models key set acme"* ]]
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

@test "guard: too big with oversize_policy fail returns OVERSIZE and sends nothing" {
  write_sized_registry 1000 '"fail"'
  run shunt_transport_invoke "$AGENT" "$(big_question 6000)"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]
  assert_output --partial "acme/m1"
  assert_output --partial "too large"
  assert_output --partial "budget 600"
  [ ! -f "$FAKE_CURL_ARGV" ]
}

@test "guard: a question that alone exceeds the budget fails without chunking (no policy)" {
  write_sized_registry 1000 null
  run shunt_transport_invoke "$AGENT" "$(big_question 6000)"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]
  assert_output --partial "leave no room"
  refute_output --partial "not implemented"
  [ ! -f "$FAKE_CURL_ARGV" ]
}

@test "guard: explicit fail does not mention chunking" {
  write_sized_registry 1000 '"fail"'
  run shunt_transport_invoke "$AGENT" "$(big_question 6000)"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]
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
  [ "$status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]
  assert_output --partial "leave no room"
  [ ! -f "$FAKE_CURL_ARGV" ]
}

@test "guard: the code-writer role always fails when too big, even with map_reduce" {
  write_sized_registry 1000 '"map_reduce"'
  run shunt_transport_invoke "shunt-code-writer-acme-m1" "$(big_question 6000)"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]
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
  [ "$status" -eq "$SHUNT_TRY_INVOKE_CONFIG" ]
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
  [ "$status" -eq "$SHUNT_TRY_INVOKE_CONFIG" ]
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
  local f="$TEST_TMPDIR/u.txt" c="$TEST_TMPDIR/chunk" joined="$TEST_TMPDIR/joined" ch k i n
  for ch in é я € 😀; do
    for k in 0 1 2 3; do
      utf8_line "$f" $(( 200 - k )) "$ch"
      _CH_FILE=() _CH_START=() _CH_END=() _CH_OFF=() _CH_LEN=() _CH_PART=() _CH_OF=()
      _shunt_http_plan_file "$f" 200
      n=${#_CH_FILE[@]}
      [ "$n" -gt 1 ]
      : >"$joined"
      for (( i = 0; i < n; i++ )); do
        _shunt_http_write_chunk "$i" "$c"
        [ "$(wc -c <"$c")" -le 200 ]
        iconv -f UTF-8 -t UTF-8 "$c" >/dev/null
        cat "$c" >>"$joined"
      done
      cmp "$joined" "$f"
    done
  done
}

@test "chunking: split UTF-8 chunks reach the model as valid UTF-8" {
  write_sized_registry 6000 null
  utf8_line "$TEST_TMPDIR/u2.txt" 1 "😀" 4000
  run shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/u2.txt"
  assert_success
  local i n
  n=$(request_count)
  [ "$n" -gt 2 ]
  for (( i = 1; i < n; i++ )); do
    iconv -f UTF-8 -t UTF-8 "$FAKE_CURL_SENT.$i" >/dev/null
    # jq turns invalid UTF-8 into U+FFFD replacement characters.
    [ "$(grep -c $'\xef\xbf\xbd' "$FAKE_CURL_SENT.$i")" -eq 0 ]
  done
}

# sent_text_bytes <n>: bytes of the decoded system and user messages of the
# n-th request, the size the oversize guard estimates tokens from.
sent_text_bytes() {
  jq -j '.messages[0].content + .messages[1].content' "$FAKE_CURL_SENT.$1" | wc -c
}

@test "chunking: no chunk request exceeds the budget with a long question, long file name and escaped content" {
  write_sized_registry 6000 null
  local dir="$TEST_TMPDIR" seg i n q
  seg=$(head -c 200 /dev/zero | tr '\0' d)
  for i in 1 2 3 4 5 6; do dir="$dir/$seg"; done
  mkdir -p "$dir"
  # Every line is quotes, backslashes, tabs and \u0001 control characters.
  awk 'BEGIN { for (i = 1; i <= 400; i++) { s = ""
    for (j = 0; j < 20; j++) s = s "\"\\\t\001"; print s } }' >"$dir/esc.txt"
  q="$(big_question 2000) \"quoted\" back\\slash"
  run --separate-stderr shunt_transport_invoke "$AGENT" "$q" "$dir/esc.txt"
  assert_success
  n=$(request_count)
  [ "$n" -gt 2 ]
  for (( i = 1; i < n; i++ )); do
    [ "$(sent_text_bytes "$i")" -le 10800 ]
  done
  # One long line split by bytes carries the longest chunk note.
  head -c 30000 /dev/zero | tr '\0' '"' >"$dir/one.txt"
  echo 0 >"$FAKE_CURL_COUNT"
  run --separate-stderr shunt_transport_invoke "$AGENT" "$q" "$dir/one.txt"
  assert_success
  n=$(request_count)
  [ "$n" -gt 2 ]
  for (( i = 1; i < n; i++ )); do
    [ "$(sent_text_bytes "$i")" -le 10800 ]
  done
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
  [ "$status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]
  [ ! -f "$FAKE_CURL_ARGV" ]
}

@test "chunking: explicit fail policy sends nothing for a big file" {
  write_sized_registry 6000 '"fail"'
  make_lines "$TEST_TMPDIR/big.txt" 300
  run shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]
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
  [ "$status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]
  assert_output --partial "limit"
  [ ! -f "$FAKE_CURL_ARGV" ]
}

# ---- total deadline (SHUNT_TOTAL_TIMEOUT_SECONDS) ----------------------------

# use_fake_clock <seconds-per-request>: the transport's clock reads FAKE_CLOCK,
# which starts at 0 and only moves when the fake curl answers a request.
use_fake_clock() {
  export FAKE_CLOCK="$TEST_TMPDIR/clock" FAKE_CURL_ADVANCE="$1"
  echo 0 >"$FAKE_CLOCK"
  _shunt_http_now() { _SHUNT_HTTP_NOW=$(cat "$FAKE_CLOCK"); }
}

# max_time_of <n>: the --max-time argument of the n-th request.
max_time_of() {
  grep -A1 -x -- '--max-time' "$FAKE_CURL_ARGV.$1" | tail -n1
}

@test "total deadline: hit between chunks stops further requests with DEADLINE" {
  write_sized_registry 6000 null
  make_lines "$TEST_TMPDIR/big.txt" 300
  use_fake_clock 10
  export SHUNT_TOTAL_TIMEOUT_SECONDS=25
  run --separate-stderr shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_DEADLINE" ]
  [ "$(request_count)" -eq 3 ]
  [[ "$stderr" == *"total deadline of 25s (SHUNT_TOTAL_TIMEOUT_SECONDS)"* ]]
  [[ "$stderr" == *"3 of 4 chunks finished"* ]]
  [[ "$stderr" != *L0001* ]]
}

@test "total deadline: each request's max-time is capped at the remaining time" {
  write_sized_registry 6000 null
  make_lines "$TEST_TMPDIR/big.txt" 300
  use_fake_clock 10
  export SHUNT_TIMEOUT_SECONDS=12 SHUNT_TOTAL_TIMEOUT_SECONDS=30
  run --separate-stderr shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_DEADLINE" ]
  [ "$(request_count)" -eq 3 ]
  [ "$(max_time_of 1)" = 12 ]
  [ "$(max_time_of 2)" = 12 ]
  [ "$(max_time_of 3)" = 10 ]
}

@test "total deadline: defaults to three times the per-request timeout" {
  write_sized_registry 6000 null
  make_lines "$TEST_TMPDIR/big.txt" 300
  use_fake_clock 10
  unset SHUNT_TOTAL_TIMEOUT_SECONDS
  export SHUNT_TIMEOUT_SECONDS=10
  run --separate-stderr shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_DEADLINE" ]
  [ "$(request_count)" -eq 3 ]
  [[ "$stderr" == *"total deadline of 30s"* ]]
}

@test "total deadline: a chunked call within the deadline succeeds" {
  write_sized_registry 6000 null
  make_lines "$TEST_TMPDIR/big.txt" 300
  use_fake_clock 10
  export SHUNT_TOTAL_TIMEOUT_SECONDS=60
  run --separate-stderr shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  assert_success
  [ "$(request_count)" -eq 5 ]
  [ "$(max_time_of 5)" = 20 ]
}

@test "total deadline: a non-chunked call keeps the per-request timeout" {
  unset SHUNT_TOTAL_TIMEOUT_SECONDS
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(max_time_of 1)" = 300 ]
  SHUNT_TOTAL_TIMEOUT_SECONDS=5000 run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(max_time_of 2)" = 300 ]
}

@test "total deadline: a smaller total also caps a non-chunked call" {
  SHUNT_TOTAL_TIMEOUT_SECONDS=7 run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(max_time_of 1)" = 7 ]
}

@test "total deadline: a curl timeout under the capped max-time names the total deadline" {
  export FAKE_CURL_EXIT=28 SHUNT_TOTAL_TIMEOUT_SECONDS=7
  run --separate-stderr shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_DEADLINE" ]
  [[ "$stderr" == *"total deadline of 7s"* ]]
}

@test "total deadline: a plain per-request curl timeout does not blame the total deadline" {
  export FAKE_CURL_EXIT=28
  run --separate-stderr shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_TIMEOUT" ]
  [[ "$stderr" != *"total deadline"* ]]
}

@test "total deadline: an invalid SHUNT_TOTAL_TIMEOUT_SECONDS is a config error and sends nothing" {
  local v
  for v in 0 abc -5 1.5 ' 3' 0000 1234567890; do
    SHUNT_TOTAL_TIMEOUT_SECONDS="$v" run --separate-stderr shunt_transport_invoke "$AGENT" "q"
    [ "$status" -eq "$SHUNT_TRY_INVOKE_CONFIG" ]
    [[ "$stderr" == *"SHUNT_TOTAL_TIMEOUT_SECONDS must be a positive whole number"* ]]
  done
  [ ! -f "$FAKE_CURL_ARGV" ]
}

@test "total deadline: the failover line names the total deadline, not the per-request timeout" {
  export FAKE_CURL_EXIT=28 SHUNT_TOTAL_TIMEOUT_SECONDS=7
  run --separate-stderr shunt_invoke_with_failover "q"
  assert_failure
  [[ "$stderr" == *"shunt: acme/m1 failed: total deadline reached (SHUNT_TOTAL_TIMEOUT_SECONDS)"* ]]
  [[ "$stderr" != *"timed out after"* ]]
}

@test "total deadline: a plain per-request timeout still names SHUNT_TIMEOUT_SECONDS in the failover line" {
  export FAKE_CURL_EXIT=28
  run --separate-stderr shunt_invoke_with_failover "q"
  assert_failure
  [[ "$stderr" == *"shunt: acme/m1 failed: timed out after 300s"* ]]
}

# ---- adversarial: hostile usage fields and breaker accounting -----------------

@test "hostile: a non-numeric usage token count is not passed on as a string to the usage log" {
  ok_body 'hi' stop '{"usage":{"prompt_tokens":"lots","completion_tokens":{"a":1}}}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(jq -r '.usage.input | type' "$output")" = "number" ]
  [ "$(jq -r '.usage.output | type' "$output")" = "number" ]
}

@test "hostile: one reply with a string token count does not break usage-report for the whole log" {
  export SHUNT_DEBUG_LOG_PATH="$TEST_TMPDIR/usage.jsonl"
  echo 'some file' >"$TEST_TMPDIR/f.txt"
  ok_body 'hi' stop
  out1=$(shunt_transport_invoke "$AGENT" "q")
  shunt_log_usage "acme/m1" "$out1" "q" "$TEST_TMPDIR/f.txt"
  ok_body 'hi' stop '{"usage":{"prompt_tokens":"lots","completion_tokens":5}}'
  out2=$(shunt_transport_invoke "$AGENT" "q")
  shunt_log_usage "acme/m1" "$out2" "q" "$TEST_TMPDIR/f.txt"
  run "$REPO_ROOT/scripts/usage-report" "$SHUNT_DEBUG_LOG_PATH"
  assert_success
}

two_http_models() {
  jq -n '{version:1,models:[
    {id:"acme/m1",agent:"shunt-bulk-reader-acme-m1",enabled:true,priority:1},
    {id:"acme/m2",agent:"shunt-bulk-reader-acme-m2",enabled:true,priority:2}]}' >"$SHUNT_MODELS_FILE"
}

breaker_failures() {
  jq -r --arg k "$1" '.[$k].failures // .models[$k].failures // 0' "$SHUNT_BREAKER_STATE_FILE" 2>/dev/null || echo 0
}

@test "breaker: an unset key env var is not counted as a model failure (like a 401 is not)" {
  two_http_models
  unset ACME_KEY
  run --separate-stderr shunt_invoke_role_with_failover bulk-read shunt_models_agent_for "" "q"
  assert_failure
  [ "$(breaker_failures acme/m1)" = 0 ]
  [ "$(breaker_failures acme/m2)" = 0 ]
}

@test "breaker: an invalid SHUNT_TOTAL_TIMEOUT_SECONDS is not counted as a model failure" {
  two_http_models
  export SHUNT_TOTAL_TIMEOUT_SECONDS=abc
  run --separate-stderr shunt_invoke_role_with_failover bulk-read shunt_models_agent_for "" "q"
  assert_failure
  [ "$(breaker_failures acme/m1)" = 0 ]
  [ "$(breaker_failures acme/m2)" = 0 ]
}

# ---- fixes: usage cleaning, CONFIG status, bash 3.2 set -u ---------------------

@test "usage: fractional, negative and huge token counts become whole non-negative numbers" {
  ok_body 'hi' stop '{"usage":{"prompt_tokens":12.7,"completion_tokens":-3},"cost":-1}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(jq -c '.usage' "$output")" = '{"input":12,"output":0}' ]
  [ "$(jq 'has("cost")' "$output")" = "false" ]
}

@test "usage: a command substitution in a token count never reaches bash arithmetic" {
  export SHUNT_PWNED="$TEST_TMPDIR/pwned"
  ok_body 'hi' stop '{"usage":{"prompt_tokens":"x[$(date>$SHUNT_PWNED)]","completion_tokens":2}}'
  run shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ ! -e "$SHUNT_PWNED" ]
  [ "$(jq -c '.usage' "$output")" = '{"input":0,"output":2}' ]
}

@test "agg_add: a non-numeric value in a normalized file counts as 0 and runs nothing" {
  export SHUNT_PWNED="$TEST_TMPDIR/pwned"
  jq -n '{text:"t",finish_reason:"stop",usage:{input:"x[$(date>$SHUNT_PWNED)]",output:"1.5"}}' >"$TEST_TMPDIR/n.json"
  _shunt_http_agg_reset
  _shunt_http_agg_add "$TEST_TMPDIR/n.json"
  [ ! -e "$SHUNT_PWNED" ]
  [ "$_SHUNT_HTTP_AGG_IN" = 0 ]
  [ "$_SHUNT_HTTP_AGG_OUT" = 0 ]
}

@test "config: a missing key returns the CONFIG status and sends nothing" {
  unset ACME_KEY
  run --separate-stderr shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_CONFIG" ]
  [ ! -e "$FAKE_CURL_COUNT" ]
}

@test "config: a CONFIG failure fails over to the next model and records no breaker failure" {
  two_http_models
  unset ACME_KEY
  run --separate-stderr shunt_invoke_role_with_failover bulk-read shunt_models_agent_for "" "q"
  assert_failure
  [[ "$stderr" == *"shunt: acme/m1 failed: config problem"* ]]
  [[ "$stderr" == *"shunt: acme/m2 failed: config problem"* ]]
  [ "$(breaker_failures acme/m1)" = 0 ]
}

@test "config: a real model failure (HTTP 500) still records a breaker failure" {
  two_http_models
  export FAKE_CURL_CODE=500
  run --separate-stderr shunt_invoke_role_with_failover bulk-read shunt_models_agent_for "" "q"
  assert_failure
  [ "$(breaker_failures acme/m1)" = 1 ]
}

@test "config: the non-failover path names an http failure, not opencode" {
  export FAKE_CURL_CODE=500
  run --separate-stderr shunt_invoke "$AGENT" "q"
  assert_failure
  [[ "$stderr" != *"opencode run failed"* ]]
  [[ "$stderr" == *"HTTP request"* ]]
}

@test "set -u: a call with key type none (empty header array) works under nounset" {
  write_providers "https://api.acme.test/v1" '{"type":"none"}'
  run bash -uc '
    source "$1/scripts/lib/opencode.sh"
    out=$(shunt_transport_invoke "$2" "q") && jq -r .text "$out"
  ' _ "$REPO_ROOT" "$AGENT"
  assert_success
  assert_output "hello there"
}

# ---- review fixes: auth temp file failure, status 1 wording, context_tokens ---

@test "auth: a failing mktemp for the header file returns ERROR with a clear message" {
  printf '#!/bin/bash\ncase "$*" in *shunt-auth*) exit 1 ;; esac\nexec /usr/bin/env -i PATH="%s" mktemp "$@"\n' "$ORIG_PATH" >"$TEST_TMPDIR/bin/mktemp"
  chmod +x "$TEST_TMPDIR/bin/mktemp"
  run --separate-stderr shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  [[ "$stderr" == *"cannot create a temp file for the auth header"* ]]
  [[ "$stderr" != *"$SECRET"* ]]
  [ ! -e "$FAKE_CURL_COUNT" ]
}

@test "invoke: status 1 (unknown agent) does not claim an HTTP request failed" {
  run --separate-stderr shunt_invoke "shunt-bulk-reader-nope" "q"
  [ "$status" -eq 1 ]
  [[ "$stderr" != *"HTTP request"* ]]
  [[ "$stderr" == *"could not be run"* ]]
}

@test "guard: a non-plain context_tokens (1e30) is rejected by the registry validation" {
  write_sized_registry 1e30 null
  run shunt_models_validate
  [ "$status" -ne 0 ]
  assert_output --partial "invalid context_tokens"
}

@test "guard: a non-plain context_tokens reaching the guard returns CONFIG, no arithmetic error" {
  local v
  for v in 1e+30 1.5 -3 abc 1234567890123; do
    _SHUNT_HTTP_ID=acme/m1 _SHUNT_HTTP_CONTEXT_TOKENS="$v" _SHUNT_HTTP_ROLE=bulk-reader
    run --separate-stderr _shunt_http_guard_size 100
    [ "$status" -eq "$SHUNT_TRY_INVOKE_CONFIG" ]
    [[ "$stderr" == *"invalid context_tokens"* ]]
    [[ "$stderr" != *"syntax error"* ]]
  done
}

# ---- adversary review of 6b9e6f6: config errors vs the breaker, key scrubbing ---

@test "adversary: an invalid providers.json is a config problem and records no breaker failure" {
  two_http_models
  printf '{"version":1,"providers":' >"$SHUNT_PROVIDERS_FILE"
  run --separate-stderr shunt_invoke_role_with_failover bulk-read shunt_models_agent_for "" "q"
  assert_failure
  [ "$(breaker_failures acme/m1)" = 0 ]
  [ "$(breaker_failures acme/m2)" = 0 ]
}

@test "adversary: a SHUNT_TIMEOUT_SECONDS curl cannot parse is a config problem and records no breaker failure" {
  two_http_models
  mv "$TEST_TMPDIR/bin/curl" "$TEST_TMPDIR/bin/curl-fake"
  # Real curl: --max-time abc -> "expected a proper numerical parameter", exit 2.
  cat >"$TEST_TMPDIR/bin/curl" <<'SH'
#!/bin/bash
prev=""
for a in "$@"; do
  if [ "$prev" = --max-time ] && ! [[ "$a" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "curl: option --max-time: expected a proper numerical parameter" >&2; exit 2
  fi
  prev="$a"
done
exec "$(dirname "$0")/curl-fake" "$@"
SH
  chmod +x "$TEST_TMPDIR/bin/curl"
  export SHUNT_TIMEOUT_SECONDS=abc
  run --separate-stderr shunt_invoke_role_with_failover bulk-read shunt_models_agent_for "" "q"
  assert_failure
  [ "$(breaker_failures acme/m1)" = 0 ]
  [ "$(breaker_failures acme/m2)" = 0 ]
}

@test "adversary: a context_tokens of 1e5 that passes registry validation is not refused by the http guard" {
  write_sized_registry 1e5 null
  run shunt_models_validate
  assert_success
  run --separate-stderr shunt_transport_invoke "$AGENT" "q"
  [ "$status" -ne "$SHUNT_TRY_INVOKE_CONFIG" ]
  assert_success
}

@test "adversary: a context_tokens of 128000.0 does not crash the opencode transport guard with an arithmetic error" {
  write_sized_registry 128000.0 null
  run shunt_models_validate
  assert_success
  _shunt_http_resolve "$AGENT"
  run --separate-stderr _shunt_opencode_guard_size "$AGENT" "q"
  [[ "$stderr" != *"syntax error"* ]]
  [[ "$stderr" != *"invalid"* ]]
  assert_success
}

# Deliberate design decision: a 401/403 says the key is wrong, not that the model
# is unhealthy, so it never counts toward the circuit breaker. The user fixes the
# key, nothing is paused behind their back. Do not "fix" this into a breaker failure.
@test "adversary: a provider that keeps answering 403 records no breaker failure (intentional) and says why" {
  two_http_models
  export FAKE_CURL_CODE=403
  local i
  for i in 1 2 3 4 5 6; do
    run --separate-stderr shunt_invoke_role_with_failover bulk-read shunt_models_agent_for "" "q"
    assert_failure
  done
  [ "$(breaker_failures acme/m1)" = 0 ]
  [ "$(breaker_failures acme/m2)" = 0 ]
  # Every call still fails over: both models are reached each time.
  [ "$(cat "$FAKE_CURL_COUNT")" -eq 12 ]
  [[ "$stderr" == *"auth failed for provider acme"* ]]
}

@test "adversary: a key echoed JSON-escaped in an HTTP 400 body is not printed on stderr" {
  export ACME_KEY="sk-live/abcdef0123456789secret"
  export FAKE_CURL_CODE=400
  printf '{"error":{"message":"invalid request for key sk-live\\/abcdef0123456789secret"}}' >"$FAKE_CURL_BODY"
  run --separate-stderr shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  [[ "$stderr" != *"abcdef0123456789secret"* ]]
}

@test "an error body echoing a non-ASCII key as \\uXXXX escapes is redacted" {
  local key=$'k\xc3\xa9y-123-\xf0\x9f\x94\x91'
  export ACME_KEY="$key"
  printf '{"error":"bad %s %s"}' 'kéy-123-🔑' 'kéy-123-🔑' >"$FAKE_CURL_BODY"
  FAKE_CURL_CODE=400 run --separate-stderr shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  [[ "$stderr" == *"bad"* ]]
  [[ "$stderr" != *'u00e9'* ]]
  [[ "$stderr" != *'u00E9'* ]]
  [[ "$stderr" != *'123'* ]]
}

@test "curl exit 63 maps to ERROR naming the response size cap" {
  FAKE_CURL_EXIT=63 SHUNT_HTTP_MAX_RESPONSE_BYTES=1000 run --separate-stderr shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  [[ "$stderr" == *"response larger than 1000 bytes"* ]]
}

@test "a reply bigger than the cap without a Content-Length is an ERROR after the download" {
  ok_body "$(printf 'x%.0s' $(seq 1 3000))" stop
  SHUNT_HTTP_MAX_RESPONSE_BYTES=1000 run --separate-stderr shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  [[ "$stderr" == *"response larger than 1000 bytes"* ]]
}

@test "the request curl gets --max-filesize with the default 16 MiB cap" {
  run shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq 0 ]
  grep -qx -- '--max-filesize' "$FAKE_CURL_ARGV"
  grep -qx '16777216' "$FAKE_CURL_ARGV"
}

@test "a 401 with an oversized body is still an auth failure" {
  export FAKE_CURL_CODE=401
  printf 'x%.0s' $(seq 1 3000) >"$FAKE_CURL_BODY"
  SHUNT_HTTP_MAX_RESPONSE_BYTES=1000 run --separate-stderr shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_AUTH" ]
}

@test "a 429 with an oversized body is reported as HTTP 429, not as a too-large reply" {
  export FAKE_CURL_CODE=429
  printf 'x%.0s' $(seq 1 3000) >"$FAKE_CURL_BODY"
  SHUNT_HTTP_MAX_RESPONSE_BYTES=1000 run --separate-stderr shunt_transport_invoke "$AGENT" "q"
  [[ "$stderr" == *"answered HTTP 429"* ]]
}

@test "an error body echoing the key with mixed-case hex escapes, ASCII as \\u00XX or control chars is redacted" {
  local key=$'ab\tc-é-KEY123' body
  export ACME_KEY="$key"
  # mixed-case hex for the e-acute, and every character written as \u00xx
  body='{"e":"x ab\tc-\u00E9-KEY123 y \u0061\u0062\u0009\u0063\u002d\u00e9\u002d\u004b\u0045\u0059\u0031\u0032\u0033 z"}'
  printf '%s' "$body" >"$FAKE_CURL_BODY"
  FAKE_CURL_CODE=400 run --separate-stderr shunt_transport_invoke "$AGENT" "q"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_ERROR" ]
  [[ "$stderr" == *"x [redacted] y"* ]]
  [[ "$stderr" != *"KEY123"* ]]
  [[ "$stderr" != *"EY123"* ]]
  [[ "$stderr" != *"\\u0033"* ]]
}
