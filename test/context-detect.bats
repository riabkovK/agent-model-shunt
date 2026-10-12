load 'test_helper'

bats_require_minimum_version 1.5.0

# Fake curl for context detection. It answers by URL: a file named after the
# request path (slashes turned into underscores) under $FAKE_ROUTES holds the
# body, an optional "<name>.code" file holds the status (default 200). No route
# means 404. Every call's argv is appended to $FAKE_CURL_ARGV, the -H @file
# contents are recorded.
setup() {
  ORIG_PATH="$PATH"
  shunt_test_setup
  export SHUNT_PROVIDERS_FILE="$TEST_TMPDIR/providers.json"
  export TMPDIR="$TEST_TMPDIR/tmp"
  export FAKE_ROUTES="$TEST_TMPDIR/routes"
  export FAKE_CURL_ARGV="$TEST_TMPDIR/curl-argv"
  export FAKE_CURL_HEADER_SEEN="$TEST_TMPDIR/curl-header-seen"
  mkdir -p "$TMPDIR" "$TEST_TMPDIR/bin" "$FAKE_ROUTES"
  export ACME_KEY="sk-super-secret-value-123"
  write_fake_curl
  PATH="$TEST_TMPDIR/bin:$PATH"
  jq -n '{version:1,models:[{id:"acme/m1",agent:"a1",enabled:true}]}' >"$SHUNT_MODELS_FILE"
  write_providers "https://api.acme.test/v1"
  BEFORE=$(cat "$SHUNT_MODELS_FILE")
}

teardown() {
  PATH="$ORIG_PATH"
  shunt_test_teardown
}

write_fake_curl() {
  cat >"$TEST_TMPDIR/bin/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_CURL_ARGV"
out="" prev="" url=""
for a in "$@"; do
  case "$prev" in
    -o) out="$a" ;;
    -H) case "$a" in @*) cp "${a#@}" "$FAKE_CURL_HEADER_SEEN" ;; esac ;;
  esac
  prev="$a"
  url="$a"
done
[ "${FAKE_CURL_EXIT:-0}" -eq 0 ] || exit "$FAKE_CURL_EXIT"
name=$(printf '%s' "${url#*://*/}" | tr '/' '_')
if [ -f "$FAKE_ROUTES/$name" ]; then
  cp "$FAKE_ROUTES/$name" "$out"
  cat "$FAKE_ROUTES/$name.code" 2>/dev/null || printf 200
else
  : >"$out"
  printf 404
fi
SH
  chmod +x "$TEST_TMPDIR/bin/curl"
}

# write_providers <base_url>
write_providers() {
  jq -n --arg u "$1" \
    '{version:1,providers:{acme:{transport:"http",base_url:$u,key:{type:"env",ref:"ACME_KEY"}}}}' >"$SHUNT_PROVIDERS_FILE"
}

# route <path-with-underscores> <json>
route() { printf '%s' "$2" >"$FAKE_ROUTES/$1"; }

detect() { "$REPO_ROOT/scripts/shunt-models" detect-context "$@"; }

registry_untouched() { [ "$(cat "$SHUNT_MODELS_FILE")" = "$BEFORE" ]; }

@test "detect: reads context_length from GET models/<model>" {
  route v1_models_m1 '{"id":"m1","context_length":131072}'
  run --separate-stderr detect acme/m1
  assert_success
  assert_output 131072
  registry_untouched
}

@test "detect: falls back to the models list entry with the matching id" {
  route v1_models '{"data":[{"id":"other","context_length":5},{"id":"m1","max_model_len":32768}]}'
  run detect acme/m1
  assert_success
  assert_output 32768
}

@test "detect: falls back to ollama api/show without the /v1 suffix" {
  route api_show '{"model_info":{"general.architecture":"qwen","qwen3.context_length":262144}}'
  run detect acme/m1
  assert_success
  assert_output 262144
  grep -q 'https://api.acme.test/api/show' "$FAKE_CURL_ARGV"
  grep -q -- '-X POST' "$FAKE_CURL_ARGV"
}

@test "detect: ollama num_ctx in parameters wins over the architecture maximum" {
  route api_show '{"parameters":"stop \"<x>\"\nnum_ctx                        131072\ntemperature 1","model_info":{"qwen3.context_length":262144}}'
  run detect acme/m1
  assert_success
  assert_output 131072
}

@test "detect: ollama without num_ctx uses the model_info maximum" {
  route api_show '{"parameters":"stop \"<x>\"","model_info":{"qwen3.context_length":262144}}'
  run detect acme/m1
  assert_output 262144
}

@test "detect: field precedence follows the documented order" {
  route v1_models_m1 '{"max_input_tokens":1,"context_window":3,"max_model_len":2,"context_length":4}'
  run detect acme/m1
  assert_output 4
  route v1_models_m1 '{"max_input_tokens":1,"context_window":3,"max_model_len":2}'
  run detect acme/m1
  assert_output 2
  route v1_models_m1 '{"max_input_tokens":1,"max_context_length":9,"context_window":3}'
  run detect acme/m1
  assert_output 3
}

@test "detect: skips a non-positive or non-integer value for the next field" {
  route v1_models_m1 '{"context_length":0,"max_model_len":"1000","context_window":1.5,"max_context_length":7000}'
  run detect acme/m1
  assert_output 7000
}

@test "detect: nothing found exits non-zero, says to enter it, writes nothing" {
  route v1_models '{"data":[{"id":"m1"}]}'
  run --separate-stderr detect acme/m1 --write
  assert_failure
  assert_output ""
  [[ "$stderr" == *"could not detect"* ]]
  [[ "$stderr" == *"shunt-models set-context acme/m1 <tokens>"* ]]
  registry_untouched
}

@test "detect: bad JSON, non-2xx and curl failure all mean not found" {
  route v1_models_m1 'not json'
  route v1_models '{"data":[{"id":"m1","context_length":100}]}'
  printf 500 >"$FAKE_ROUTES/v1_models.code"
  run detect acme/m1
  assert_failure
  FAKE_CURL_EXIT=28 run detect acme/m1
  assert_failure
  registry_untouched
}

@test "detect: --write stores context_tokens and the registry stays valid" {
  route v1_models_m1 '{"context_length":65536}'
  run detect acme/m1 --write
  assert_success
  assert_output --partial "65536"
  run jq -r '.models[0].context_tokens' "$SHUNT_MODELS_FILE"
  assert_output 65536
  run bash -c "source '$REPO_ROOT/scripts/lib/opencode.sh'; source '$REPO_ROOT/scripts/lib/models.sh'; shunt_models_validate"
  assert_success
}

@test "detect: without --write the registry is not changed" {
  route v1_models_m1 '{"context_length":65536}'
  run detect acme/m1
  assert_success
  registry_untouched
}

@test "detect: an unknown model with --write fails and writes nothing" {
  route v1_models_nope '{"context_length":65536}'
  run detect acme/nope --write
  assert_failure
  registry_untouched
}

@test "detect: the key goes in a header file, never in argv, and no temp file is left" {
  route v1_models_m1 '{"context_length":65536}'
  run detect acme/m1
  assert_success
  ! grep -q "$ACME_KEY" "$FAKE_CURL_ARGV"
  grep -q -- '-H @' "$FAKE_CURL_ARGV"
  [ "$(cat "$FAKE_CURL_HEADER_SEEN")" = "Authorization: Bearer $ACME_KEY" ]
  refute_output --partial "$ACME_KEY"
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "detect: no temp file is left after a failed detection" {
  run detect acme/m1
  assert_failure
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "detect: a model name with unsafe characters is not sent anywhere" {
  run detect 'acme/m 1?x=y'
  assert_failure
  [ ! -e "$FAKE_CURL_ARGV" ]
}

@test "set-context: stores a positive integer" {
  run "$REPO_ROOT/scripts/shunt-models" set-context acme/m1 8192
  assert_success
  run jq -r '.models[0].context_tokens' "$SHUNT_MODELS_FILE"
  assert_output 8192
}

@test "set-context: rejects zero, negative, decimal, text and huge values" {
  for bad in 0 -5 1.5 abc 08 1e3 9999999999999; do
    run "$REPO_ROOT/scripts/shunt-models" set-context acme/m1 "$bad"
    assert_failure
  done
  registry_untouched
}

@test "set-context: an unknown model fails" {
  run "$REPO_ROOT/scripts/shunt-models" set-context acme/nope 8192
  assert_failure
  assert_output --partial "not in the registry"
  registry_untouched
}

@test "detect: a model name with dot segments is not sent anywhere" {
  run detect 'acme/../../admin'
  assert_failure
  [ ! -e "$FAKE_CURL_ARGV" ]
}

@test "detect: a provider value beyond the digit limit is not written" {
  route v1_models_m1 '{"context_length":100000000000000000000}'
  run detect acme/m1 --write
  assert_failure
  registry_untouched
}

# breaker_with_failures: an open breaker for acme/m1 (both roles) and another model
breaker_with_failures() {
  echo '{"version":1,"models":{"acme/m1":{"failures":3,"cooldown_until":9999999999},"acme/m1#code-write":{"failures":3,"cooldown_until":9999999999},"other/x":{"failures":1,"cooldown_until":0}}}' \
    >"$SHUNT_BREAKER_STATE_FILE"
}

@test "set-context: clears the model's breaker state, keeping other models'" {
  breaker_with_failures
  run "$REPO_ROOT/scripts/shunt-models" set-context acme/m1 8192
  assert_success
  run jq -c '.models | keys' "$SHUNT_BREAKER_STATE_FILE"
  assert_output '["other/x"]'
}

@test "set-context: a rejected value keeps the breaker state" {
  breaker_with_failures
  run "$REPO_ROOT/scripts/shunt-models" set-context acme/m1 0
  assert_failure
  run jq -r '.models["acme/m1"].failures' "$SHUNT_BREAKER_STATE_FILE"
  assert_output 3
}

@test "detect: --write clears the model's breaker state" {
  breaker_with_failures
  route v1_models_m1 '{"context_length":65536}'
  run detect acme/m1 --write
  assert_success
  run jq -c '.models | keys' "$SHUNT_BREAKER_STATE_FILE"
  assert_output '["other/x"]'
}

@test "detect: without --write or on failure the breaker state stays" {
  breaker_with_failures
  route v1_models_m1 '{"context_length":65536}'
  run detect acme/m1
  assert_success
  rm "$FAKE_ROUTES/v1_models_m1"
  run detect acme/m1 --write
  assert_failure
  run jq -r '.models["acme/m1"].failures' "$SHUNT_BREAKER_STATE_FILE"
  assert_output 3
}

# hang_curl: replaces the fake curl with one that touches $TEST_TMPDIR/curl-started
# and then hangs, so a test can kill the caller while a request is in flight.
hang_curl() {
  cat >"$TEST_TMPDIR/bin/curl" <<'SH'
#!/bin/bash
: >"$TEST_TMPDIR/curl-started"
exec sleep 30
SH
  chmod +x "$TEST_TMPDIR/bin/curl"
  export TEST_TMPDIR
}

# kill_group_when_curl_starts <pid>: TERMs the process group (what Ctrl-C or a
# tool timeout does to the whole tree) once the hanging curl has started.
kill_group_when_curl_starts() {
  local i
  for i in $(seq 1 100); do
    [ -f "$TEST_TMPDIR/curl-started" ] && break
    sleep 0.05
  done
  kill -TERM -- -"$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

@test "detect: killing detect-context mid-request leaves no auth header file with the key in TMPDIR" {
  command -v setsid >/dev/null || skip "setsid not available"
  hang_curl
  setsid "$REPO_ROOT/scripts/shunt-models" detect-context acme/m1 >/dev/null 2>&1 &
  kill_group_when_curl_starts "$!"
  run grep -rlF "$ACME_KEY" "$TMPDIR"
  assert_output ""
}

@test "detect: a 401 answer is reported as an auth failure with exit code 3, not as a missing window" {
  route v1_models_m1 '{"error":"unauthorized"}'
  printf 401 >"$FAKE_ROUTES/v1_models_m1.code"
  run --separate-stderr detect acme/m1
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"auth failed"* ]]
  [[ "$stderr" == *"re-enter the key through /model-config"* ]]
  [[ "$stderr" != *"could not detect"* ]]
  [[ "$stderr" != *"$ACME_KEY"* ]]
  registry_untouched
}

@test "detect: a 403 on the models list is also an auth failure" {
  printf 403 >"$FAKE_ROUTES/v1_models.code"
  route v1_models '{"error":"forbidden"}'
  run --separate-stderr detect acme/m1
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"auth failed"* ]]
}

@test "detect: a 404 everywhere is still the plain could-not-detect failure with exit code 1" {
  run --separate-stderr detect acme/m1
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"could not detect the context window"* ]]
}

@test "detect: a caller's EXIT trap survives shunt_models_detect_context" {
  route v1_models_m1 '{"id":"m1","context_length":4096}'
  run bash -c '
    source "$1/scripts/lib/opencode.sh"; source "$1/scripts/lib/context-detect.sh"
    trap "echo caller-trap-ran" EXIT
    shunt_models_detect_context acme/m1 >/dev/null
    trap -p EXIT' _ "$REPO_ROOT"
  assert_output --partial "caller-trap-ran"
}

@test "detect: a 403 on models/<model> alone (gateway route miss) does not stop the models list fallback" {
  export HOME="$TEST_TMPDIR/home" XDG_CONFIG_HOME="$TEST_TMPDIR/xdg-config" XDG_DATA_HOME="$TEST_TMPDIR/xdg-data" XDG_CACHE_HOME="$TEST_TMPDIR/xdg-cache"
  mkdir -p "$HOME"
  route v1_models_m1 '{"message":"Missing Authentication Token"}'
  printf 403 >"$FAKE_ROUTES/v1_models_m1.code"
  route v1_models '{"data":[{"id":"m1","context_length":32768}]}'
  run --separate-stderr detect acme/m1
  assert_success
  assert_output 32768
}

@test "detect: curl gets --max-filesize and an over-limit answer counts as not found" {
  route v1_models_m1 "$(printf '{"context_length":131072,"pad":"%s"}' "$(printf 'x%.0s' $(seq 1 3000))")"
  SHUNT_HTTP_MAX_RESPONSE_BYTES=1000 run --separate-stderr detect acme/m1
  assert_failure
  [[ "$stderr" == *"larger than 1000 bytes"* ]]
  grep -q -- '--max-filesize 1000' "$FAKE_CURL_ARGV"
}

@test "detect: curl exit 63 prints the same larger-than note as the post-download check" {
  FAKE_CURL_EXIT=63 SHUNT_HTTP_MAX_RESPONSE_BYTES=1000 run --separate-stderr detect acme/m1
  assert_failure
  [[ "$stderr" == *"larger than 1000 bytes"* ]]
}

@test "context-detect.sh sources transport-http.sh itself when sourced alone" {
  run bash -c 'source "$1/scripts/lib/context-detect.sh"; type _shunt_http_too_large >/dev/null && type _shunt_http_max_response_bytes >/dev/null' _ "$REPO_ROOT"
  assert_success
}

@test "detect: an id missing from the registry is refused before any request" {
  run ! detect acme/ghost
  [ ! -e "$FAKE_CURL_ARGV" ]
}
