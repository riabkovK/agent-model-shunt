load 'test_helper'

bats_require_minimum_version 1.5.0

SHUNT_MODELS_BIN="$REPO_ROOT/scripts/shunt-models"

setup() {
  shunt_test_setup
  export SHUNT_PROVIDERS_FILE="$TEST_TMPDIR/providers.json"
}

teardown() {
  shunt_test_teardown
}

pfield() { jq -c ".providers.$1" "$SHUNT_PROVIDERS_FILE"; }

@test "provider set creates an http provider with an env key" {
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url https://api.acme.test/v1 --key env:ACME_KEY
  assert_success
  run pfield acme
  assert_output '{"transport":"http","base_url":"https://api.acme.test/v1","key":{"type":"env","ref":"ACME_KEY"},"healthcheck":true}'
  [ "$(stat -c %a "$SHUNT_PROVIDERS_FILE")" = "600" ]
}

@test "provider set http without a base_url fails and writes nothing" {
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --key none
  assert_failure
  assert_output --partial "base_url"
  [ ! -f "$SHUNT_PROVIDERS_FILE" ]
}

@test "provider set never accepts a key value on the command line" {
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url https://x --key plaintext:sk-secret
  assert_failure
  refute_output --partial "sk-secret"
  [ ! -f "$SHUNT_PROVIDERS_FILE" ]
}

@test "provider list shows name, transport, base_url and key type, never a key value" {
  echo '{"version":1,"providers":{"acme":{"transport":"http","base_url":"https://x","key":{"type":"plaintext","ref":"sk-secret"}},"envp":{"transport":"http","base_url":"https://y","key":{"type":"env","ref":"ENVP_KEY"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run "$SHUNT_MODELS_BIN" provider list
  assert_success
  assert_output --partial "acme"
  assert_output --partial "https://x"
  assert_output --partial "plaintext"
  assert_output --partial "env:ENVP_KEY"
  refute_output --partial "sk-secret"
}

@test "provider set rejects an invalid --healthcheck value" {
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url https://a.test/v1 --healthcheck maybe
  assert_failure
  assert_output --partial '--healthcheck must be on or off'
  [ ! -f "$SHUNT_PROVIDERS_FILE" ]
}
