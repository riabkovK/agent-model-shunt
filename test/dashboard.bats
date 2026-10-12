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
  assert_line "breaker threshold=3 default=3 cooldown_seconds=300 default=300 status=enabled"
  assert_line "self_fix_retries=1 default=1"
  assert_line "first_choice bulk-read none"
  assert_line "first_choice code-write none"
  assert_line "opencode config=absent importable=none"
  refute_line --partial "provider "
  refute_line --partial "model "
  assert_equal "${lines[-1]}" "setup: empty"
}

@test "dashboard with an empty registry file is still empty" {
  write_models '{"version":1,"active":null,"models":[]}'
  run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line "registry: ok"
  assert_equal "${lines[-1]}" "setup: empty"
}

@test "dashboard lists providers and models and is ok when everything is set" {
  write_providers "$ACME_HTTP_ENV"
  write_models "$ONE_MODEL"
  ACME_KEY=secret-value-123 run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line "provider acme transport=http base_url=https://api.acme.test/v1 key=env:ACME_KEY key_present=yes"
  assert_line "model acme/m1 enabled=yes active=yes roles=bulk-read,code-write thinking=off thinking_off=none context_tokens=128000 oversize_policy=map_reduce(default) provider_transport=http"
  assert_line "breaker_state acme/m1 bulk-read failures=0 open=false"
  assert_line "breaker_state acme/m1 code-write failures=0 open=false"
  assert_line "first_choice bulk-read acme/m1"
  assert_line "first_choice code-write acme/m1"
  refute_line --partial "issue "
  refute_output --partial "secret-value-123"
  assert_equal "${lines[-1]}" "setup: ok"
}

@test "dashboard never prints a stored plaintext key" {
  write_providers '{"version":1,"providers":{"acme":{"transport":"http","base_url":"https://api.acme.test/v1","key":{"type":"plaintext","ref":"plain-secret-456"}}}}'
  write_models "$ONE_MODEL"
  run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line "provider acme transport=http base_url=https://api.acme.test/v1 key=plaintext key_present=yes"
  refute_output --partial "plain-secret-456"
  assert_equal "${lines[-1]}" "setup: ok"
}

@test "dashboard flags an http provider without a key as incomplete" {
  write_providers "$ACME_HTTP_ENV"
  write_models "$ONE_MODEL"
  run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line --partial "key_present=no"
  assert_line "issue key-missing acme"
  assert_equal "${lines[-1]}" "setup: incomplete"
}

@test "dashboard flags an http model without context_tokens as incomplete" {
  write_providers '{"version":1,"providers":{"acme":{"transport":"http","base_url":"http://localhost:11434/v1","key":{"type":"none"}}}}'
  write_models '{"version":1,"active":null,"models":[{"id":"acme/m1","agent":"a1","enabled":true,"thinking":false,"roles":["bulk-read"]}]}'
  run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line --partial "key=none key_present=yes"
  assert_line --partial "context_tokens=unset"
  assert_line "issue context-missing acme/m1"
  assert_equal "${lines[-1]}" "setup: incomplete"
}

@test "dashboard flags a registry with no enabled bulk-read model" {
  write_models '{"version":1,"active":"oc/m2","models":[{"id":"oc/m2","agent":"a2","enabled":false,"thinking":true,"thinking_off_options":{"reasoningEffort":"none"},"roles":["code-write"],"context_tokens":8000,"oversize_policy":"fail"}]}'
  run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line "model oc/m2 enabled=no active=yes roles=code-write thinking=on thinking_off=set context_tokens=8000 oversize_policy=fail provider_transport=opencode"
  assert_line "breaker_state oc/m2 code-write failures=0 open=false"
  refute_line --partial "breaker_state oc/m2 bulk-read"
  assert_line "issue no-bulk-read-model -"
  assert_equal "${lines[-1]}" "setup: incomplete"
}

@test "dashboard flags providers without any model" {
  write_providers "$ACME_HTTP_ENV"
  ACME_KEY=k run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line "issue no-models -"
  assert_equal "${lines[-1]}" "setup: incomplete"
}

@test "dashboard offers the opencode migration for registry models on opencode providers" {
  write_models '{"version":1,"active":null,"models":[{"id":"oc/m2","agent":"a2","enabled":true,"thinking":false,"roles":["bulk-read"]}]}'
  jq -n '{provider: {oc: {options: {baseURL: "https://oc.test/v1", apiKey: "oc-literal-789"}}, unused: {}}}' \
    >"$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"
  run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line "opencode config=present importable=oc"
  refute_output --partial "oc-literal-789"
  assert_equal "${lines[-1]}" "setup: opencode-importable"
}

@test "dashboard does not offer the migration over an invalid providers file" {
  write_models '{"version":1,"active":null,"models":[{"id":"oc/m2","agent":"a2","enabled":true,"thinking":false,"roles":["bulk-read"]}]}'
  write_providers '{"version":1,"providers":{"oc":{"transport":"ftp"}}}'
  jq -n '{provider: {oc: {options: {baseURL: "https://oc.test/v1"}}}}' \
    >"$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"
  run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line "issue providers-invalid providers.json"
  assert_equal "${lines[-1]}" "setup: incomplete"
}

@test "dashboard does not offer the migration once a provider is on http" {
  write_providers "$ACME_HTTP_ENV"
  write_models '{"version":1,"active":null,"models":[{"id":"acme/m1","agent":"a1","enabled":true,"thinking":false,"roles":["bulk-read"],"context_tokens":1000}]}'
  jq -n '{provider: {acme: {options: {baseURL: "https://api.acme.test/v1"}}}}' \
    >"$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"
  ACME_KEY=k run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line "opencode config=present importable=none"
  assert_equal "${lines[-1]}" "setup: ok"
}

@test "dashboard reports an invalid registry and an invalid providers file" {
  write_models '{not json'
  write_providers '{"version":1,"providers":{"acme":{"transport":"ftp"}}}'
  run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line "registry: invalid"
  assert_line "providers_file: invalid"
  assert_line "provider acme invalid"
  assert_line "issue registry-invalid models.json"
  assert_line "issue providers-invalid providers.json"
  assert_equal "${lines[-1]}" "setup: incomplete"
}

@test "dashboard shows configured breaker, open state and self-fix retries" {
  write_models "$ONE_MODEL"
  echo '{"threshold":999999999,"cooldown_seconds":60}' >"$SHUNT_BREAKER_CONFIG_FILE"
  echo '{"self_fix_retries":4}' >"$SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE"
  run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line "breaker threshold=999999999 default=3 cooldown_seconds=60 default=300 status=disabled"
  assert_line "self_fix_retries=4 default=1"
}

@test "dashboard shows an open bulk-read breaker" {
  write_models "$ONE_MODEL"
  echo '{"models":{"acme/m1":{"failures":3,"cooldown_until":99999999999}}}' >"$SHUNT_BREAKER_STATE_FILE"
  run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line "breaker_state acme/m1 bulk-read failures=3 open=true"
}

@test "dashboard takes no arguments" {
  run "$SHUNT_MODELS_BIN" dashboard extra
  assert_failure
  assert_output --partial "usage: shunt-models dashboard"
}

@test "thinking counts as on only for boolean true" {
  write_models '{"version":1,"active":null,"models":[{"id":"oc/m2","agent":"a2","enabled":true,"thinking":"on","roles":["bulk-read"]}]}'
  run "$SHUNT_MODELS_BIN" dashboard
  assert_success
  assert_line --partial "model oc/m2 "
  assert_line --partial "thinking=off"
}
