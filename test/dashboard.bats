load 'test_helper'

bats_require_minimum_version 1.5.0

SHUNT_MODELS_BIN="$REPO_ROOT/scripts/shunt-models"

setup() {
  shunt_test_setup
  export SHUNT_PROVIDERS_FILE="$TEST_TMPDIR/providers.json"
  unset ACME_KEY
}

teardown() {
  shunt_test_teardown
}

write_models() {
  printf '%s\n' "$1" >"$SHUNT_MODELS_FILE"
}

write_providers() {
  printf '%s\n' "$1" >"$SHUNT_PROVIDERS_FILE"
}

ACME_HTTP_ENV='{"version":1,"providers":{"acme":{"transport":"http","base_url":"https://api.acme.test/v1","key":{"type":"env","ref":"ACME_KEY"}}}}'
ONE_MODEL='{"version":1,"active":"acme/m1","models":[{"id":"acme/m1","agent":"a1","enabled":true,"thinking":false,"thinking_options":null,"thinking_off_options":null,"roles":["bulk-read","code-write"],"context_tokens":128000}]}'

@test "dashboard with nothing configured reports setup empty and defaults" {
  run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line "registry: missing"
  assert_line "providers_file: missing"
  assert_line "breaker threshold=3 default=3 cooldown_seconds=300 default=300 unreachable_cooldown_seconds=120 default=120 status=enabled"
  assert_line "self_fix_retries=1 default=1"
  assert_line "first_choice bulk-read none"
  assert_line "first_choice code-write none"
  assert_line "opencode config=absent importable=none"
  refute_line --partial "provider "
  refute_line --partial "model "
  assert_equal "${lines[${#lines[@]}-1]}" "setup: empty"
}

@test "dashboard lists providers and models and is ok when everything is set" {
  write_providers "$ACME_HTTP_ENV"
  write_models "$ONE_MODEL"
  ACME_KEY=secret-value-123 run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line "provider acme transport=http base_url=https://api.acme.test/v1 key=env:ACME_KEY key_present=yes healthcheck=off"
  assert_line "model acme/m1 enabled=yes active=yes roles=bulk-read,code-write thinking=off thinking_off=none context_tokens=128000 oversize_policy=map_reduce(default) provider_transport=http"
  assert_line "breaker_state acme/m1 bulk-read failures=0 open=false"
  assert_line "breaker_state acme/m1 code-write failures=0 open=false"
  assert_line "first_choice bulk-read acme/m1"
  assert_line "first_choice code-write acme/m1"
  refute_line --partial "issue "
  refute_output --partial "secret-value-123"
  assert_equal "${lines[${#lines[@]}-1]}" "setup: ok"
}

@test "dashboard never prints a stored plaintext key" {
  write_providers '{"version":1,"providers":{"acme":{"transport":"http","base_url":"https://api.acme.test/v1","key":{"type":"plaintext","ref":"plain-secret-456"}}}}'
  write_models "$ONE_MODEL"
  run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line "provider acme transport=http base_url=https://api.acme.test/v1 key=plaintext key_present=yes healthcheck=off"
  refute_output --partial "plain-secret-456"
  assert_equal "${lines[${#lines[@]}-1]}" "setup: ok"
}

@test "dashboard takes no arguments" {
  run "$SHUNT_MODELS_BIN" dashboard extra
  assert_failure
  assert_output --partial "usage: shunt-models dashboard"
}
