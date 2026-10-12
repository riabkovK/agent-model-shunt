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
  export XDG_DATA_HOME="$TEST_TMPDIR/xdg-data"
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
  run --separate-stderr migrate --apply --yes --key-storage keyring
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
  run --separate-stderr migrate --apply --yes --key-storage plaintext
  assert_success
  refute_output --partial "$SECRET"
  assert_output --partial "plain text"
  [ "$(stat -c %a "$SHUNT_PROVIDERS_FILE")" = 600 ]
  run jq -r '.providers.acme | .key.type + " " + .key.ref' "$SHUNT_PROVIDERS_FILE"
  assert_output "plaintext $SECRET"
  no_secret_anywhere_but "$SHUNT_PROVIDERS_FILE"
}

@test "apply with env uses SHUNT_<PROVIDER>_KEY and copies nothing" {
  run --separate-stderr migrate --apply --yes --key-storage env
  assert_success
  assert_output --partial "SHUNT_ACME_KEY"
  run jq -c '.providers.acme.key' "$SHUNT_PROVIDERS_FILE"
  assert_output '{"type":"env","ref":"SHUNT_ACME_KEY"}'
  no_secret_anywhere_but ""
}

@test "apply with skip leaves the transport opencode, key pending, models untouched" {
  before=$(cat "$SHUNT_MODELS_FILE")
  run --separate-stderr migrate --apply --yes --key-storage skip
  assert_success
  assert_output --partial "key set acme"
  run jq -c '.providers.acme | [.transport, .key.type]' "$SHUNT_PROVIDERS_FILE"
  assert_output '["opencode","keyring"]'
  [ "$(cat "$SHUNT_MODELS_FILE")" = "$before" ]
  no_secret_anywhere_but ""
  # a second run has nothing new to write
  run --separate-stderr migrate --apply --yes --key-storage skip
  assert_output --partial "nothing to do"
}

@test "{env:NAME} becomes an env key with that ref" {
  write_opencode '{env:MY_ACME_TOKEN}'
  run --separate-stderr migrate --apply --yes
  assert_success
  run jq -c '.providers.acme | [.transport, .key]' "$SHUNT_PROVIDERS_FILE"
  assert_output '["http",{"type":"env","ref":"MY_ACME_TOKEN"}]'
}

@test "no apiKey gives key type none" {
  write_opencode -
  run --separate-stderr migrate --apply --yes
  assert_success
  run jq -c '.providers.acme.key' "$SHUNT_PROVIDERS_FILE"
  assert_output '{"type":"none"}'
}

@test "non-tty without --key-storage treats a literal key as skip and says so" {
  run --separate-stderr migrate --apply --yes
  assert_success
  [[ "$stderr" == *"treating it as skip"* ]]
  run jq -r '.providers.acme.transport' "$SHUNT_PROVIDERS_FILE"
  assert_output opencode
  no_secret_anywhere_but ""
}

@test "a bad base_url skips the provider with a message" {
  write_opencode - "ftp://api.acme.test/v1"
  run --separate-stderr migrate --apply --yes
  assert_success
  assert_output --partial "skipped"
  assert_output --partial "scheme"
  [ ! -f "$SHUNT_PROVIDERS_FILE" ]
}

@test "second run reports nothing to do" {
  run --separate-stderr migrate --apply --yes --key-storage keyring
  assert_success
  run --separate-stderr migrate --apply --yes --key-storage keyring
  assert_success
  assert_output --partial "nothing to do"
  run migrate
  assert_output --partial "nothing to do"
}

@test "unrelated providers, existing request_body and context_tokens are preserved" {
  jq -n '{version:1,providers:{keep:{transport:"http",base_url:"https://k.test/v1",key:{type:"none"}}}}' >"$SHUNT_PROVIDERS_FILE"
  jq '.models[0] += {request_body:{"reasoning_effort":"none"},context_tokens:1000}' "$SHUNT_MODELS_FILE" >"$TEST_TMPDIR/m" && mv "$TEST_TMPDIR/m" "$SHUNT_MODELS_FILE"
  run --separate-stderr migrate --apply --yes --key-storage env
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
  run --separate-stderr migrate --apply --yes
  assert_success
  assert_output --partial "131072 (detected from the provider)"
  run jq '.models[0].context_tokens' "$SHUNT_MODELS_FILE"
  assert_output 131072
}

@test "reasoning effort in the registry thinking_options is converted" {
  write_opencode -
  jq '.models[0] += {thinking:true,thinking_options:{reasoningEffort:"high"}}' "$SHUNT_MODELS_FILE" >"$TEST_TMPDIR/m" && mv "$TEST_TMPDIR/m" "$SHUNT_MODELS_FILE"
  run --separate-stderr migrate --apply --yes
  assert_success
  run jq -c '.models[0].request_body' "$SHUNT_MODELS_FILE"
  assert_output '{"reasoning_effort":"high"}'
}

@test "an unknown --key-storage is refused" {
  run --separate-stderr migrate --key-storage vault
  assert_failure
}

@test "apply without a tty and without --yes refuses and writes nothing" {
  before=$(cat "$SHUNT_MODELS_FILE")
  run --separate-stderr migrate --apply --key-storage keyring
  assert_failure
  [[ "$stderr" == *"--yes"* ]]
  [ "$(cat "$SHUNT_MODELS_FILE")" = "$before" ]
  [ -z "$(ls "$SHUNT_MODELS_FILE".bak-* 2>/dev/null)" ]
  [ ! -e "$FAKE_STORE" ]
}

@test "apply with --yes applies without a tty" {
  run --separate-stderr migrate --apply --yes --key-storage keyring
  assert_success
  [ "$(cat "$FAKE_STORE")" = "$SECRET" ]
}

@test "an OpenCode {file:path} apiKey is not copied as the literal key string" {
  write_opencode '{file:~/.secrets/acme-key}'
  run --separate-stderr migrate --apply --yes --key-storage plaintext
  run jq -r '.providers.acme | "\(.transport) \(.key.type) \(.key.ref)"' "$SHUNT_PROVIDERS_FILE"
  refute_output "http plaintext {file:~/.secrets/acme-key}"
}

@test "two providers whose names differ only in punctuation get distinct env refs" {
  jq -n --arg k "$SECRET" '{provider:{
      "a-b":{options:{baseURL:"https://ab1.test/v1",apiKey:$k},models:{m:{}}},
      "a.b":{options:{baseURL:"https://ab2.test/v1",apiKey:"sk-other-key-456"},models:{m:{}}}}}' \
    >"$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"
  jq -n '{version:1,active:null,models:[
    {id:"a-b/m",agent:"a1",enabled:true,roles:["bulk-read"]},{id:"a.b/m",agent:"a2",enabled:true,roles:["bulk-read"]}]}' >"$SHUNT_MODELS_FILE"
  run --separate-stderr migrate --apply --yes --key-storage env
  assert_success
  run jq -r '.providers["a-b"].key.ref, .providers["a.b"].key.ref' "$SHUNT_PROVIDERS_FILE"
  [ "${lines[0]}" != "${lines[1]}" ]
}

@test "a provider keyed through OpenCode auth.json is not migrated to http without a key and reported ok" {
  # OpenCode's documented custom-provider flow: `opencode auth login` stores the
  # key in auth.json, opencode.json has only the baseURL.
  export XDG_DATA_HOME="$TEST_TMPDIR/xdg-data"
  mkdir -p "$XDG_DATA_HOME/opencode"
  jq -n --arg k "$SECRET" '{acme:{type:"api",key:$k}}' >"$XDG_DATA_HOME/opencode/auth.json"
  write_opencode -
  jq -n '{version:1,active:null,models:[{id:"acme/m1",agent:"a1",enabled:true,thinking:false}]}' >"$SHUNT_MODELS_FILE"
  run --separate-stderr migrate --apply --yes
  assert_success
  run "$BIN" dashboard
  if jq -e '.providers.acme | .transport == "http" and .key.type == "none"' "$SHUNT_PROVIDERS_FILE" >/dev/null; then
    refute_output --partial "setup: ok"
  fi
}

@test "a dry run killed during context detection leaves no copy of a plaintext key in TMPDIR" {
  command -v setsid >/dev/null || skip "setsid not available"
  # acme is already on http with a plaintext key (state done), so the dry run
  # detects its model's context through a temp providers file.
  jq -n --arg k "$SECRET" '{version:1,providers:{acme:{transport:"http",
    base_url:"https://api.acme.test/v1",key:{type:"plaintext",ref:$k}}}}' >"$SHUNT_PROVIDERS_FILE"
  chmod 600 "$SHUNT_PROVIDERS_FILE"
  cat >"$TEST_TMPDIR/bin/curl" <<'SH'
#!/bin/bash
: >"$TEST_TMPDIR/curl-started"
exec sleep 30
SH
  export TEST_TMPDIR
  setsid "$BIN" --migrate-from-opencode </dev/null >/dev/null 2>&1 &
  pid=$!
  for i in $(seq 1 100); do
    [ -f "$TEST_TMPDIR/curl-started" ] && break
    sleep 0.05
  done
  kill -TERM -- -"$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  run grep -rlF "$SECRET" "$TMPDIR"
  assert_output ""
}

@test "a {file:path} apiKey is imported: ~ expanded, trailing newline stripped, key never shown" {
  export HOME="$TEST_TMPDIR/home"
  mkdir -p "$HOME/.secrets"
  printf '%s\n\n' "$SECRET" >"$HOME/.secrets/acme-key"
  write_opencode '{file:~/.secrets/acme-key}'
  run --separate-stderr migrate --key-storage plaintext
  assert_success
  refute_output --partial "$SECRET"
  assert_output --partial "apiKey file"
  run --separate-stderr migrate --apply --yes --key-storage plaintext
  assert_success
  refute_output --partial "$SECRET"
  run jq -r '.providers.acme | "\(.transport) \(.key.type) \(.key.ref)"' "$SHUNT_PROVIDERS_FILE"
  assert_output "http plaintext $SECRET"
}

@test "an unreadable {file:path} apiKey leaves the provider on opencode with a plan line" {
  write_opencode '{file:~/.secrets/missing-key}'
  run --separate-stderr migrate --apply --yes --key-storage plaintext
  assert_success
  assert_output --partial "not readable or is empty"
  assert_output --partial "stays on opencode"
  [ ! -f "$SHUNT_PROVIDERS_FILE" ] || [ "$(jq -r '.providers.acme.transport // "opencode"' "$SHUNT_PROVIDERS_FILE")" = opencode ]
}

@test "an OpenCode auth.json key is imported into the chosen storage and never shown" {
  mkdir -p "$XDG_DATA_HOME/opencode"
  jq -n --arg k "$SECRET" '{acme:{type:"api",key:$k}}' >"$XDG_DATA_HOME/opencode/auth.json"
  write_opencode -
  run --separate-stderr migrate --key-storage keyring
  assert_success
  refute_output --partial "$SECRET"
  assert_output --partial "auth.json"
  run --separate-stderr migrate --apply --yes --key-storage keyring
  assert_success
  refute_output --partial "$SECRET"
  [ "$(cat "$FAKE_STORE")" = "$SECRET" ]
  run jq -r '.providers.acme | "\(.transport) \(.key.type)"' "$SHUNT_PROVIDERS_FILE"
  assert_output "http keyring"
  no_secret_anywhere_but "$FAKE_STORE"
}

@test "an auth.json entry that is not an api key does not count as a key" {
  mkdir -p "$XDG_DATA_HOME/opencode"
  jq -n '{acme:{type:"oauth",access:"x"}}' >"$XDG_DATA_HOME/opencode/auth.json"
  write_opencode -
  run --separate-stderr migrate --apply --yes
  assert_success
  run jq -c '.providers.acme.key' "$SHUNT_PROVIDERS_FILE"
  assert_output '{"type":"none"}'
}

@test "a clashing default env ref gets a suffix and the plan says so" {
  jq -n --arg k "$SECRET" '{provider:{
      "a-b":{options:{baseURL:"https://ab1.test/v1",apiKey:$k},models:{m:{}}},
      "a.b":{options:{baseURL:"https://ab2.test/v1",apiKey:"sk-other-key-456"},models:{m:{}}}}}' \
    >"$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"
  jq -n '{version:1,active:null,models:[
    {id:"a-b/m",agent:"a1",enabled:true,roles:["bulk-read"]},{id:"a.b/m",agent:"a2",enabled:true,roles:["bulk-read"]}]}' >"$SHUNT_MODELS_FILE"
  run --separate-stderr migrate --key-storage env
  assert_success
  assert_output --partial "SHUNT_A_B_KEY_2"
  assert_output --partial "taken by another provider"
}

@test "plan hints use the absolute shunt-models path, not a relative one" {
  run --separate-stderr migrate --key-storage skip
  assert_success
  assert_output --partial "key set acme"
  refute_output --partial " scripts/shunt-models"
  assert_output --partial "$REPO_ROOT/scripts/shunt-models"
}

@test "context detection works for every model of a provider, not just the first" {
  jq -n '{version:1,active:null,models:[
    {id:"acme/m1",agent:"a1",enabled:true},{id:"acme/m2",agent:"a2",enabled:true}]}' >"$SHUNT_MODELS_FILE"
  write_opencode -
  printf '%s' '{"id":"m1","context_length":1111}' >"$FAKE_ROUTES/v1_models_m1"
  printf '%s' '{"id":"m2","context_length":2222}' >"$FAKE_ROUTES/v1_models_m2"
  run --separate-stderr migrate
  assert_success
  assert_output --partial "1111 (detected"
  assert_output --partial "2222 (detected"
}

# Adversary review of ad56036: every test below isolates HOME, XDG_* and TMPDIR.
isolate_home() {
  export HOME="$TEST_TMPDIR/home" XDG_CONFIG_HOME="$TEST_TMPDIR/xdg-config" XDG_CACHE_HOME="$TEST_TMPDIR/xdg-cache"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME/opencode"
}

@test "a default env ref is not handed out when a later provider's {env:NAME} already uses that name" {
  isolate_home
  jq -n --arg k "$SECRET" '{provider:{
      "a":{options:{baseURL:"https://a.test/v1",apiKey:$k},models:{m:{}}},
      "b":{options:{baseURL:"https://b.test/v1",apiKey:"{env:SHUNT_A_KEY}"},models:{m:{}}}}}' \
    >"$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"
  jq -n '{version:1,active:null,models:[
    {id:"a/m",agent:"a1",enabled:true},{id:"b/m",agent:"a2",enabled:true}]}' >"$SHUNT_MODELS_FILE"
  run --separate-stderr migrate --apply --yes --key-storage env
  assert_success
  run jq -r '[.providers.a.key.ref, .providers.b.key.ref] | unique | length' "$SHUNT_PROVIDERS_FILE"
  assert_output 2
}

@test "a non-string apiKey in opencode.json is not imported as a key" {
  isolate_home
  jq -n '{provider:{acme:{options:{baseURL:"https://api.acme.test/v1",apiKey:{nested:"x"}},models:{m1:{}}}}}' \
    >"$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"
  run --separate-stderr migrate --apply --yes --key-storage plaintext
  assert_success
  run jq -r '.providers.acme | "\(.transport) \(.key.type) \(.key.ref // "-")"' "$SHUNT_PROVIDERS_FILE"
  refute_output "http plaintext {"
}

@test "a whitespace-only auth.json key is not imported as a key" {
  isolate_home
  jq -n '{acme:{type:"api",key:"   "}}' >"$XDG_DATA_HOME/opencode/auth.json"
  write_opencode -
  run --separate-stderr migrate --apply --yes --key-storage plaintext
  assert_success
  run jq -r '.providers.acme.key | "\(.type) [\(.ref // "-")]"' "$SHUNT_PROVIDERS_FILE"
  refute_output "plaintext [   ]"
}

@test "a provider name outside the allowed charset is skipped with a reason, never in a hint" {
  jq -n '{provider:{"a;id":{options:{baseURL:"https://x.test/v1",apiKey:"sk-hostile-000"},models:{}}}}' \
    >"$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"
  jq -n '{version:1,active:null,models:[{id:"a;id/m",agent:"a1",enabled:true}]}' >"$SHUNT_MODELS_FILE"
  run migrate
  assert_output --partial "skipped, the provider name has characters other than"
  refute_output --partial "key set"
  refute_output --partial "sk-hostile-000"
}

@test "a non-string apiKey is not mentioned for a provider already on http" {
  jq -n '{provider:{acme:{options:{baseURL:"https://api.acme.test/v1",apiKey:123},models:{m1:{}}}}}' \
    >"$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"
  jq -n '{version:1,providers:{acme:{transport:"http",base_url:"https://api.acme.test/v1",key:{type:"none"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run --separate-stderr migrate
  assert_success
  assert_output --partial "already on the http transport"
  refute_output --partial "not imported as a key"
}

@test "a non-string apiKey is explained for a skipped provider without a doubled period" {
  local bad
  for bad in 123 '{}'; do
    jq -n --argjson k "$bad" '{provider:{
      "bad name":{options:{baseURL:"https://api.acme.test/v1",apiKey:$k},models:{m1:{}}}}}' \
      >"$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"
    echo '{"version":1,"active":null,"models":[{"id":"bad name/m1","agent":"a1","enabled":true}]}' >"$SHUNT_MODELS_FILE"
    run --separate-stderr migrate
    assert_success
    assert_output --partial "stays on opencode. the apiKey in opencode.json is not a string"
    refute_output --partial ".."
    refute_output --partial ". ."
  done
}
