load 'test_helper'

setup() {
  ORIG_PATH="$PATH"
  shunt_test_setup
  export SHUNT_PROVIDERS_FILE="$TEST_TMPDIR/providers.json"
  export SHUNT_PROC_VERSION_FILE="$TEST_TMPDIR/proc-version"
  echo "Linux version 6.1 (gcc)" >"$SHUNT_PROC_VERSION_FILE"
  FAKE_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  export FAKE_STORE="$TEST_TMPDIR/store" FAKE_ARGV="$TEST_TMPDIR/argv"
  source "$REPO_ROOT/scripts/lib/providers.sh"
  SECRET="sk-super-secret-value-123"
}

teardown() {
  PATH="$ORIG_PATH"
  shunt_test_teardown
}

write_providers() {
  echo "$1" >"$SHUNT_PROVIDERS_FILE"
}

# fake_tool <name>: records argv, stores stdin on store/-w-less calls, prints on lookup.
fake_tool() {
  cat >"$FAKE_BIN/$1" <<'SH'
#!/bin/bash
echo "$0 $*" >>"$FAKE_ARGV"
case "$*" in
  *store*|*add-generic-password*|*" -w "*) cat >"$FAKE_STORE" 2>/dev/null || true ;;
  *) cat "$FAKE_STORE" 2>/dev/null ;;
esac
SH
  chmod +x "$FAKE_BIN/$1"
}

# Restricts PATH to the fake dir plus the basics, so real keyring tools never show up.
use_fake_path() {
  local d="$TEST_TMPDIR/basic" t
  mkdir -p "$d"
  for t in jq grep mktemp chmod cat dirname mv rm head bash python3; do ln -sf "$(command -v $t)" "$d/$t"; done
  PATH="$FAKE_BIN:$d"
}

@test "missing providers.json means transport opencode" {
  run shunt_provider_transport anything
  assert_success
  assert_output "opencode"
}

@test "provider absent from the file means transport opencode and key type none" {
  write_providers '{"version":1,"providers":{}}'
  run shunt_provider_transport other
  assert_output "opencode"
  run shunt_provider_key_type other
  assert_output "none"
}

@test "transport and base_url are read from the provider" {
  write_providers '{"version":1,"providers":{"p":{"transport":"http","base_url":"https://x/v1","key":{"type":"none"}}}}'
  run shunt_provider_transport p
  assert_output "http"
  run shunt_provider_base_url p
  assert_output "https://x/v1"
}

@test "unknown transport is rejected with a clear message" {
  write_providers '{"version":1,"providers":{"p":{"transport":"grpc"}}}'
  run shunt_provider_transport p
  assert_failure
  assert_output --partial 'unknown transport "grpc"'
}

@test "unknown key type is rejected with a clear message" {
  write_providers '{"version":1,"providers":{"p":{"transport":"http","key":{"type":"magic"}}}}'
  run shunt_provider_key_resolve p
  assert_failure
  assert_output --partial 'unknown key type "magic"'
}

@test "invalid JSON is rejected" {
  echo 'nope' >"$SHUNT_PROVIDERS_FILE"
  run shunt_providers_validate
  assert_failure
  assert_output --partial "invalid JSON"
}

@test "env key resolves from the named variable" {
  write_providers '{"providers":{"p":{"key":{"type":"env","ref":"MY_KEY_VAR"}}}}'
  MY_KEY_VAR="$SECRET" run shunt_provider_key_resolve p
  assert_success
  assert_output "$SECRET"
}

@test "env key unset errors naming the variable and not leaking anything" {
  write_providers '{"providers":{"p":{"key":{"type":"env","ref":"MY_KEY_VAR"}}}}'
  unset MY_KEY_VAR
  run shunt_provider_key_resolve p
  assert_failure
  assert_output --partial "MY_KEY_VAR"
}

@test "plaintext key resolves from the file" {
  write_providers "{\"providers\":{\"p\":{\"key\":{\"type\":\"plaintext\",\"ref\":\"$SECRET\"}}}}"
  run shunt_provider_key_resolve p
  assert_output "$SECRET"
}

@test "key type none resolves to nothing" {
  write_providers '{"providers":{"p":{"key":{"type":"none"}}}}'
  run shunt_provider_key_resolve p
  assert_success
  assert_output ""
}

@test "failure paths do not print the key" {
  write_providers "{\"providers\":{\"p\":{\"transport\":\"x\",\"key\":{\"type\":\"plaintext\",\"ref\":\"$SECRET\"}}}}"
  run shunt_provider_key_resolve p
  assert_failure
  refute_output --partial "$SECRET"
}

@test "backend detection prefers secret-tool, then security, then kwallet-query" {
  fake_tool kwallet-query
  use_fake_path
  run shunt_keyring_backend
  assert_output "kwallet-query"
  fake_tool security
  run shunt_keyring_backend
  assert_output "security"
  fake_tool secret-tool
  run shunt_keyring_backend
  assert_output "secret-tool"
}

@test "no backend prints nothing" {
  use_fake_path
  run shunt_keyring_backend
  assert_success
  assert_output ""
}

@test "WSL skips keyring detection" {
  fake_tool secret-tool
  use_fake_path
  echo "Linux version 5.15 microsoft-standard-WSL2" >"$SHUNT_PROC_VERSION_FILE"
  run shunt_keyring_backend
  assert_output ""
}

@test "secret-tool store and get round trip keeps the key out of argv" {
  fake_tool secret-tool
  use_fake_path
  printf '%s\n' "$SECRET" | shunt_keyring_store p
  run shunt_keyring_get p
  assert_output "$SECRET"
  run grep -c "$SECRET" "$FAKE_ARGV"
  assert_output "0"
  grep -q "account p" "$FAKE_ARGV"
}

@test "kwallet-query store and get round trip keeps the key out of argv" {
  fake_tool kwallet-query
  use_fake_path
  printf '%s\n' "$SECRET" | shunt_keyring_store p
  run shunt_keyring_get p
  assert_output "$SECRET"
  run grep -c "$SECRET" "$FAKE_ARGV"
  assert_output "0"
}

@test "security store and get round trip works (key in argv is the documented limitation)" {
  fake_tool security
  use_fake_path
  printf '%s\n' "$SECRET" | shunt_keyring_store p || true
  grep -q "agent-model-shunt/p" "$FAKE_ARGV"
}

@test "keyring key resolves and missing keyring entry errors without a value" {
  write_providers '{"providers":{"p":{"key":{"type":"keyring"}}}}'
  fake_tool secret-tool
  use_fake_path
  run shunt_provider_key_resolve p
  assert_failure
  assert_output --partial "shunt-models key set p"
  printf '%s\n' "$SECRET" | shunt_keyring_store p
  run shunt_provider_key_resolve p
  assert_output "$SECRET"
}

@test "plaintext warning mentions plain text" {
  run shunt_provider_plaintext_warning
  assert_output --partial "plain text"
}

@test "validate rejects a provider name outside the allowed charset" {
  local name
  for name in 'a;rm -rf x' '$(id)' 'a b' '-x'; do
    jq -n --arg n "$name" '{providers:{($n):{transport:"http",key:{type:"none"}}}}' >"$SHUNT_PROVIDERS_FILE"
    run shunt_providers_validate
    assert_failure
    assert_output --partial "provider name has characters other than"
  done
}

@test "validate rejects a provider name with a trailing newline" {
  jq -n --arg n $'ok\n' '{providers:{($n):{transport:"http",key:{type:"none"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run shunt_providers_validate
  assert_failure
  assert_output --partial "provider name has characters other than"
}

@test "validate names the offending provider, quoted, and says to edit providers.json" {
  jq -n '{providers:{"_old":{transport:"http",key:{type:"none"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run shunt_providers_validate
  assert_failure
  assert_output --partial '"_old"'
  assert_output --partial "edit providers.json"
  jq -n --arg n $'bad\nname' '{providers:{($n):{transport:"http",key:{type:"none"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run shunt_providers_validate
  assert_failure
  assert_output --partial '"bad\nname"'
}

