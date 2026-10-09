load 'test_helper'

bats_require_minimum_version 1.5.0

BIN="$REPO_ROOT/scripts/shunt-models"

# Fake curl (no route: 404, so detection fails unless a test adds a route) and
# a fake secret-tool that records its argv and what it was given on stdin.
setup() {
  ORIG_PATH="$PATH"
  shunt_test_setup
  export SHUNT_PROVIDERS_FILE="$TEST_TMPDIR/providers.json"
  export SHUNT_PROC_VERSION_FILE="$TEST_TMPDIR/proc-version"
  echo "Linux version 6.1" >"$SHUNT_PROC_VERSION_FILE"
  export TMPDIR="$TEST_TMPDIR/tmp"
  export FAKE_ROUTES="$TEST_TMPDIR/routes" FAKE_ARGV="$TEST_TMPDIR/argv" FAKE_STORE="$TEST_TMPDIR/store"
  mkdir -p "$TMPDIR" "$TEST_TMPDIR/bin" "$FAKE_ROUTES"
  SECRET="sk-super-secret-value-123"
  cat >"$TEST_TMPDIR/bin/curl" <<'SH'
#!/bin/bash
out="" prev="" url=""
for a in "$@"; do
  [ "$prev" = -o ] && out="$a"
  prev="$a"; url="$a"
done
name=$(printf '%s' "${url#*://*/}" | tr '/' '_')
if [ -f "$FAKE_ROUTES/$name" ]; then cp "$FAKE_ROUTES/$name" "$out"; printf 200
else : >"$out"; printf 404; fi
SH
  cat >"$TEST_TMPDIR/bin/secret-tool" <<'SH'
#!/bin/bash
echo "$*" >>"$FAKE_ARGV"
[ "$1" = store ] && cat >"$FAKE_STORE"
exit 0
SH
  chmod +x "$TEST_TMPDIR/bin/curl" "$TEST_TMPDIR/bin/secret-tool"
  PATH="$TEST_TMPDIR/bin:$PATH"
  write_opencode "$SECRET"
  jq -n '{version:1,active:null,models:[
    {id:"acme/m1",agent:"a1",enabled:true,thinking:false},
    {id:"other/x",agent:"a2",enabled:true}]}' >"$SHUNT_MODELS_FILE"
}

teardown() {
  PATH="$ORIG_PATH"
  shunt_test_teardown
}

# write_opencode <apiKey|-> [baseURL]   ("-" means no apiKey)
write_opencode() {
  jq -n --arg k "$1" --arg u "${2:-https://api.acme.test/v1}" '
    {provider:{
      acme:{npm:"x",options:({baseURL:$u} + (if $k == "-" then {} else {apiKey:$k} end)),
        models:{m1:{limit:{context:65536,output:4096},options:{reasoningEffort:"low"}}}},
      unused:{options:{baseURL:"https://unused.test/v1",apiKey:"sk-unused-000"},models:{}}}}' \
    >"$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"
}

migrate() { "$BIN" --migrate-from-opencode "$@" </dev/null; }

no_secret_anywhere_but() {
  # $1: file allowed to hold the key (or empty)
  local f
  for f in "$SHUNT_PROVIDERS_FILE" "$SHUNT_MODELS_FILE" "$FAKE_ARGV" "$FAKE_STORE" "$SHUNT_PROVIDERS_FILE".bak-* "$SHUNT_MODELS_FILE".bak-*; do
    [ -f "$f" ] || continue
    [ "$f" = "${1:-}" ] && continue
    ! grep -qF "$SECRET" "$f"
  done
}

@test "dry run changes nothing, prints a plan and never the key" {
  before=$(cat "$SHUNT_MODELS_FILE")
  run --separate-stderr migrate --key-storage env
  assert_success
  refute_output --partial "$SECRET"
  assert_output --partial "dry run"
  assert_output --partial "provider acme"
  assert_output --partial "context_tokens 65536 (from opencode.json, not verified)"
  assert_output --partial '{"reasoning_effort":"low"}'
  refute_output --partial "unused"
  [ "$(cat "$SHUNT_MODELS_FILE")" = "$before" ]
  [ ! -f "$SHUNT_PROVIDERS_FILE" ]
  ! ls "$SHUNT_MODELS_FILE".bak-* 2>/dev/null
  no_secret_anywhere_but ""
}

@test "apply with keyring writes providers and models, backs up, key only via stdin" {
  before=$(cat "$SHUNT_MODELS_FILE")
  run --separate-stderr migrate --apply --key-storage keyring
  assert_success
  refute_output --partial "$SECRET"
  [ "$(cat "$FAKE_STORE")" = "$SECRET" ]
  [ "$(cat "$(ls "$SHUNT_MODELS_FILE".bak-*)")" = "$before" ]
  run jq -c '.providers.acme' "$SHUNT_PROVIDERS_FILE"
  assert_output '{"transport":"http","base_url":"https://api.acme.test/v1","key":{"type":"keyring"}}'
  run jq -c '.models[0] | [.request_body, .context_tokens]' "$SHUNT_MODELS_FILE"
  assert_output '[{"reasoning_effort":"low"},65536]'
  run jq -c '.models[1] | [.request_body, .context_tokens]' "$SHUNT_MODELS_FILE"
  assert_output '[null,null]'
  no_secret_anywhere_but "$FAKE_STORE"
  grep -q "$SECRET" "$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"
}

@test "apply with plaintext stores the key mode 600 and warns" {
  run --separate-stderr migrate --apply --key-storage plaintext
  assert_success
  refute_output --partial "$SECRET"
  assert_output --partial "plain text"
  [ "$(stat -c %a "$SHUNT_PROVIDERS_FILE")" = 600 ]
  run jq -r '.providers.acme | .key.type + " " + .key.ref' "$SHUNT_PROVIDERS_FILE"
  assert_output "plaintext $SECRET"
  no_secret_anywhere_but "$SHUNT_PROVIDERS_FILE"
}

@test "apply with env uses SHUNT_<PROVIDER>_KEY and copies nothing" {
  run --separate-stderr migrate --apply --key-storage env
  assert_success
  assert_output --partial "SHUNT_ACME_KEY"
  run jq -c '.providers.acme.key' "$SHUNT_PROVIDERS_FILE"
  assert_output '{"type":"env","ref":"SHUNT_ACME_KEY"}'
  no_secret_anywhere_but ""
}

@test "apply with skip leaves the transport opencode, key pending, models untouched" {
  before=$(cat "$SHUNT_MODELS_FILE")
  run --separate-stderr migrate --apply --key-storage skip
  assert_success
  assert_output --partial "key set acme"
  run jq -c '.providers.acme | [.transport, .key.type]' "$SHUNT_PROVIDERS_FILE"
  assert_output '["opencode","keyring"]'
  [ "$(cat "$SHUNT_MODELS_FILE")" = "$before" ]
  no_secret_anywhere_but ""
  # a second run has nothing new to write
  run --separate-stderr migrate --apply --key-storage skip
  assert_output --partial "nothing to do"
}

@test "{env:NAME} becomes an env key with that ref" {
  write_opencode '{env:MY_ACME_TOKEN}'
  run --separate-stderr migrate --apply
  assert_success
  run jq -c '.providers.acme | [.transport, .key]' "$SHUNT_PROVIDERS_FILE"
  assert_output '["http",{"type":"env","ref":"MY_ACME_TOKEN"}]'
}

@test "no apiKey gives key type none" {
  write_opencode -
  run --separate-stderr migrate --apply
  assert_success
  run jq -c '.providers.acme.key' "$SHUNT_PROVIDERS_FILE"
  assert_output '{"type":"none"}'
}

@test "non-tty without --key-storage treats a literal key as skip and says so" {
  run --separate-stderr migrate --apply
  assert_success
  [[ "$stderr" == *"treating it as skip"* ]]
  run jq -r '.providers.acme.transport' "$SHUNT_PROVIDERS_FILE"
  assert_output opencode
  no_secret_anywhere_but ""
}

@test "a bad base_url skips the provider with a message" {
  write_opencode - "ftp://api.acme.test/v1"
  run --separate-stderr migrate --apply
  assert_success
  assert_output --partial "skipped"
  assert_output --partial "scheme"
  [ ! -f "$SHUNT_PROVIDERS_FILE" ]
}

@test "second run reports nothing to do" {
  run --separate-stderr migrate --apply --key-storage keyring
  assert_success
  run --separate-stderr migrate --apply --key-storage keyring
  assert_success
  assert_output --partial "nothing to do"
  run migrate
  assert_output --partial "nothing to do"
}

@test "unrelated providers, existing request_body and context_tokens are preserved" {
  jq -n '{version:1,providers:{keep:{transport:"http",base_url:"https://k.test/v1",key:{type:"none"}}}}' >"$SHUNT_PROVIDERS_FILE"
  jq '.models[0] += {request_body:{"reasoning_effort":"none"},context_tokens:1000}' "$SHUNT_MODELS_FILE" >"$TEST_TMPDIR/m" && mv "$TEST_TMPDIR/m" "$SHUNT_MODELS_FILE"
  run --separate-stderr migrate --apply --key-storage env
  assert_success
  run jq -c '.providers.keep' "$SHUNT_PROVIDERS_FILE"
  assert_output '{"transport":"http","base_url":"https://k.test/v1","key":{"type":"none"}}'
  ls "$SHUNT_PROVIDERS_FILE".bak-*
  run jq -c '.models[0] | [.request_body, .context_tokens]' "$SHUNT_MODELS_FILE"
  assert_output '[{"reasoning_effort":"none"},1000]'
}

@test "context comes from the provider when it reports one" {
  write_opencode -
  printf '%s' '{"id":"m1","context_length":131072}' >"$FAKE_ROUTES/v1_models_m1"
  run --separate-stderr migrate --apply
  assert_success
  assert_output --partial "131072 (detected from the provider)"
  run jq '.models[0].context_tokens' "$SHUNT_MODELS_FILE"
  assert_output 131072
}

@test "reasoning effort in the registry thinking_options is converted" {
  write_opencode -
  jq '.models[0] += {thinking:true,thinking_options:{reasoningEffort:"high"}}' "$SHUNT_MODELS_FILE" >"$TEST_TMPDIR/m" && mv "$TEST_TMPDIR/m" "$SHUNT_MODELS_FILE"
  run --separate-stderr migrate --apply
  assert_success
  run jq -c '.models[0].request_body' "$SHUNT_MODELS_FILE"
  assert_output '{"reasoning_effort":"high"}'
}

@test "an unknown --key-storage is refused" {
  run --separate-stderr migrate --key-storage vault
  assert_failure
}
