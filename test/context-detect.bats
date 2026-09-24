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
