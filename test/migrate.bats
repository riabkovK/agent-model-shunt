load 'test_helper'

bats_require_minimum_version 1.5.0

BIN="$REPO_ROOT/scripts/shunt-models"

# A local scripted HTTP server (test/py/httpserver.py, no route: 404, so detection
# fails unless a test adds a route) and
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
  cat >"$TEST_TMPDIR/bin/secret-tool" <<'SH'
#!/bin/bash
echo "$*" >>"$FAKE_ARGV"
[ "$1" = store ] && cat >"$FAKE_STORE"
exit 0
SH
  chmod +x "$TEST_TMPDIR/bin/secret-tool"
  start_http_server "$FAKE_ROUTES"
  PATH="$TEST_TMPDIR/bin:$PATH"
  write_opencode "$SECRET"
  jq -n '{version:1,active:null,models:[
    {id:"acme/m1",agent:"a1",enabled:true,thinking:false},
    {id:"other/x",agent:"a2",enabled:true}]}' >"$SHUNT_MODELS_FILE"
}

teardown() {
  stop_http_server
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
  assert_output '{"transport":"http","base_url":"https://api.acme.test/v1","key":{"type":"keyring"},"healthcheck":true}'
  run jq -c '.models[0] | [.request_body, .context_tokens]' "$SHUNT_MODELS_FILE"
  assert_output '[{"reasoning_effort":"low"},65536]'
  run jq -c '.models[1] | [.request_body, .context_tokens]' "$SHUNT_MODELS_FILE"
  assert_output '[null,null]'
  no_secret_anywhere_but "$FAKE_STORE"
  grep -q "$SECRET" "$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"
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

@test "plan hints use the absolute shunt-models path, not a relative one" {
  run --separate-stderr migrate --key-storage skip
  assert_success
  assert_output --partial "key set acme"
  refute_output --partial " scripts/shunt-models"
  assert_output --partial "$REPO_ROOT/scripts/shunt-models"
}

# Adversary review of ad56036: every test below isolates HOME, XDG_* and TMPDIR.
isolate_home() {
  export HOME="$TEST_TMPDIR/home" XDG_CONFIG_HOME="$TEST_TMPDIR/xdg-config" XDG_CACHE_HOME="$TEST_TMPDIR/xdg-cache"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME/opencode"
}
