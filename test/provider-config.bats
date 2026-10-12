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
  assert_output '{"transport":"http","base_url":"https://api.acme.test/v1","key":{"type":"env","ref":"ACME_KEY"}}'
  [ "$(stat -c %a "$SHUNT_PROVIDERS_FILE")" = "600" ]
}

@test "provider set keeps other providers and the version" {
  echo '{"version":1,"providers":{"other":{"transport":"opencode"}}}' >"$SHUNT_PROVIDERS_FILE"
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url http://localhost:11434/v1 --key none
  assert_success
  run jq -c '[.version, (.providers | keys)]' "$SHUNT_PROVIDERS_FILE"
  assert_output '[1,["acme","other"]]'
}

@test "provider set http without a base_url fails and writes nothing" {
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --key none
  assert_failure
  assert_output --partial "base_url"
  [ ! -f "$SHUNT_PROVIDERS_FILE" ]
}

@test "provider set rejects a base_url without http:// or https://" {
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url api.acme.test --key none
  assert_failure
  assert_output --partial "http://"
  [ ! -f "$SHUNT_PROVIDERS_FILE" ]
}

@test "provider set matches the transport as a whole word, not a substring of the list" {
  run "$SHUNT_MODELS_BIN" provider set acme --transport "http opencode" --base-url https://x --key none
  assert_failure
  run "$SHUNT_MODELS_BIN" provider set acme --transport "http " --base-url https://x --key none
  assert_failure
  [ ! -f "$SHUNT_PROVIDERS_FILE" ]
}

@test "provider set prints one usage line for a missing name and for a dangling option" {
  run --separate-stderr "$SHUNT_MODELS_BIN" provider set
  assert_failure
  local first="$stderr"
  run --separate-stderr "$SHUNT_MODELS_BIN" provider set acme --transport
  assert_failure
  [ "$stderr" = "$first" ]
}

@test "provider set rejects an unknown transport, key type or env var name" {
  run "$SHUNT_MODELS_BIN" provider set acme --transport ftp --base-url https://x --key none
  assert_failure
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url https://x --key vault
  assert_failure
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url https://x --key 'env:1BAD'
  assert_failure
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url https://x --key 'env:A;rm'
  assert_failure
  [ ! -f "$SHUNT_PROVIDERS_FILE" ]
}

@test "provider set never accepts a key value on the command line" {
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url https://x --key plaintext:sk-secret
  assert_failure
  refute_output --partial "sk-secret"
  [ ! -f "$SHUNT_PROVIDERS_FILE" ]
}

@test "provider set rejects unknown options and missing values" {
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url https://x --api-key foo
  assert_failure
  run "$SHUNT_MODELS_BIN" provider set acme --transport
  assert_failure
  run "$SHUNT_MODELS_BIN" provider set
  assert_failure
}

@test "provider set keyring and plaintext print the key set hint" {
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url https://x --key keyring
  assert_success
  assert_output --partial "! $REPO_ROOT/scripts/shunt-models key set acme"
  run "$SHUNT_MODELS_BIN" provider set bolt --transport http --base-url https://y --key plaintext
  assert_success
  assert_output --partial "! $REPO_ROOT/scripts/shunt-models key set bolt"
  run pfield bolt
  assert_output '{"transport":"http","base_url":"https://y","key":{"type":"plaintext"}}'
}

@test "provider set updating only the base_url keeps transport and key" {
  echo '{"version":1,"providers":{"acme":{"transport":"http","base_url":"https://old","key":{"type":"env","ref":"ACME_KEY"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run "$SHUNT_MODELS_BIN" provider set acme --base-url https://new
  assert_success
  run pfield acme
  assert_output '{"transport":"http","base_url":"https://new","key":{"type":"env","ref":"ACME_KEY"}}'
}

@test "provider set changing the key type away from plaintext drops the stored key" {
  echo '{"version":1,"providers":{"acme":{"transport":"http","base_url":"https://x","key":{"type":"plaintext","ref":"sk-secret"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run "$SHUNT_MODELS_BIN" provider set acme --key keyring
  assert_success
  refute_output --partial "sk-secret"
  run pfield acme
  assert_output '{"transport":"http","base_url":"https://x","key":{"type":"keyring"}}'
}

@test "provider set keeping plaintext keeps the stored key" {
  echo '{"version":1,"providers":{"acme":{"transport":"http","base_url":"https://x","key":{"type":"plaintext","ref":"sk-secret"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run "$SHUNT_MODELS_BIN" provider set acme --base-url https://y
  assert_success
  run jq -r '.providers.acme.key.ref' "$SHUNT_PROVIDERS_FILE"
  assert_output "sk-secret"
}

@test "provider set opencode needs no base_url and a new provider needs a transport" {
  run "$SHUNT_MODELS_BIN" provider set oc --transport opencode
  assert_success
  run jq -r '.providers.oc.transport' "$SHUNT_PROVIDERS_FILE"
  assert_output "opencode"
  run "$SHUNT_MODELS_BIN" provider set fresh --base-url https://x
  assert_failure
  assert_output --partial "--transport"
}

@test "provider set refuses to edit an invalid providers file" {
  echo 'not json' >"$SHUNT_PROVIDERS_FILE"
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url https://x --key none
  assert_failure
  run cat "$SHUNT_PROVIDERS_FILE"
  assert_output "not json"
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

@test "provider list with no providers file says so" {
  run "$SHUNT_MODELS_BIN" provider list
  assert_success
  assert_output --partial "no providers"
}

@test "oversize-policy stores fail and map_reduce, --clear removes it" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  run "$SHUNT_MODELS_BIN" oversize-policy p/one fail
  assert_success
  run jq -r '.models[0].oversize_policy' "$SHUNT_MODELS_FILE"
  assert_output "fail"
  run "$SHUNT_MODELS_BIN" oversize-policy p/one map_reduce
  assert_success
  run jq -r '.models[0].oversize_policy' "$SHUNT_MODELS_FILE"
  assert_output "map_reduce"
  run "$SHUNT_MODELS_BIN" oversize-policy p/one --clear
  assert_success
  run jq -r '.models[0] | has("oversize_policy")' "$SHUNT_MODELS_FILE"
  assert_output "false"
}

@test "oversize-policy rejects an unknown value, an unknown model and missing args" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  BEFORE=$(cat "$SHUNT_MODELS_FILE")
  run "$SHUNT_MODELS_BIN" oversize-policy p/one truncate
  assert_failure
  run "$SHUNT_MODELS_BIN" oversize-policy p/nope fail
  assert_failure
  run "$SHUNT_MODELS_BIN" oversize-policy p/one
  assert_failure
  [ "$(cat "$SHUNT_MODELS_FILE")" = "$BEFORE" ]
}

@test "oversize-policy clears the model's breaker state, keeping other models'" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  echo '{"version":1,"models":{"p/one":{"failures":3,"cooldown_until":9999999999},"p/one#code-write":{"failures":3,"cooldown_until":9999999999},"p/two":{"failures":1,"cooldown_until":0}}}' \
    >"$SHUNT_BREAKER_STATE_FILE"
  run "$SHUNT_MODELS_BIN" oversize-policy p/one fail
  assert_success
  run jq -c '.models | keys' "$SHUNT_BREAKER_STATE_FILE"
  assert_output '["p/two"]'
}

@test "a failed oversize-policy keeps the breaker state" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  echo '{"version":1,"models":{"p/one":{"failures":3,"cooldown_until":9999999999}}}' >"$SHUNT_BREAKER_STATE_FILE"
  run "$SHUNT_MODELS_BIN" oversize-policy p/one bogus
  assert_failure
  run jq -r '.models["p/one"].failures' "$SHUNT_BREAKER_STATE_FILE"
  assert_output "3"
}

# --- adversarial review: reproductions (expected to fail until fixed) ---

@test "provider set: base_url with user:pass@ is refused, not stored and printed by provider list" {
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url 'https://user:sk-TESTONLY-NOTREAL@api.acme.test/v1' --key none
  assert_failure
  run "$SHUNT_MODELS_BIN" provider list
  refute_output --partial "sk-TESTONLY-NOTREAL"
}

@test "provider set: base_url with a control character (ESC) is refused" {
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url $'https://api.acme.test\e]0;pwn\a/v1' --key none
  assert_failure
  [ ! -f "$SHUNT_PROVIDERS_FILE" ]
}

@test "provider set: base_url with an empty host (https:///v1) is refused" {
  run "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url 'https:///v1' --key none
  assert_failure
  [ ! -f "$SHUNT_PROVIDERS_FILE" ]
}

@test "provider set: an empty --base-url value is refused, not silently ignored" {
  "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url https://api.acme.test/v1 --key none
  run "$SHUNT_MODELS_BIN" provider set acme --base-url ''
  assert_failure
}

@test "provider set: an empty --transport value is refused, not silently ignored" {
  "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url https://api.acme.test/v1 --key none
  run "$SHUNT_MODELS_BIN" provider set acme --transport ''
  assert_failure
}

@test "provider set: concurrent sets of different providers lose none of them" {
  echo '{"version":1,"providers":{}}' >"$SHUNT_PROVIDERS_FILE"
  local i
  for i in $(seq 1 20); do
    "$SHUNT_MODELS_BIN" provider set "p$i" --transport opencode >/dev/null 2>&1 &
  done
  wait
  run jq '.providers | length' "$SHUNT_PROVIDERS_FILE"
  assert_output "20"
}

@test "provider set: refuses a providers file whose key entry is not an object" {
  echo '{"version":1,"providers":{"acme":{"transport":"http","base_url":"https://x","key":"sk-TESTONLY-NOTREAL"}}}' >"$SHUNT_PROVIDERS_FILE"
  BEFORE=$(cat "$SHUNT_PROVIDERS_FILE")
  run "$SHUNT_MODELS_BIN" provider set acme --base-url https://y
  assert_failure
  [ "$(cat "$SHUNT_PROVIDERS_FILE")" = "$BEFORE" ]
}

@test "provider list: one provider with a non-object key does not hide the others" {
  echo '{"version":1,"providers":{"bad":{"transport":"http","base_url":"https://x","key":"sk-TESTONLY-NOTREAL"},"good":{"transport":"opencode"}}}' >"$SHUNT_PROVIDERS_FILE"
  run "$SHUNT_MODELS_BIN" provider list
  assert_output --partial "good"
  refute_output --partial "sk-TESTONLY-NOTREAL"
}

@test "SKILL flow: add works for an http provider configured only with provider set" {
  "$SHUNT_MODELS_BIN" provider set acme --transport http --base-url http://127.0.0.1:9/v1 --key none
  [ ! -f "$SHUNT_OPENCODE_CONFIG_HOME/opencode.json" ]
  run "$SHUNT_MODELS_BIN" add acme/m1
  assert_success
  run jq -r '.models[0].id' "$SHUNT_MODELS_FILE"
  assert_output "acme/m1"
}

@test "the mkdir lock fallback keeps the caller's EXIT trap and removes its lock dir" {
  echo '{"version":1,"providers":{}}' >"$SHUNT_PROVIDERS_FILE"
  # A PATH without flock forces the mkdir lock.
  mkdir -p "$TEST_TMPDIR/noflock"
  local tool
  for tool in bash jq dirname mkdir rmdir mktemp sleep; do ln -s "$(command -v $tool)" "$TEST_TMPDIR/noflock/$tool"; done
  run env PATH="$TEST_TMPDIR/noflock" bash -c '
    source "$1/scripts/lib/providers.sh"
    trap "echo caller-trap-ran" EXIT
    shunt_providers_lock
    [ -d "$SHUNT_PROVIDERS_FILE.lock.d" ] || echo no-lock-dir
    shunt_providers_unlock
    [ ! -d "$SHUNT_PROVIDERS_FILE.lock.d" ] || echo lock-dir-left
    trap -p EXIT' _ "$REPO_ROOT"
  assert_output --partial "caller-trap-ran"
  refute_output --partial "no-lock-dir"
  refute_output --partial "lock-dir-left"
}

@test "the mkdir lock fallback is released and the caller's trap runs when the shell exits holding it" {
  echo '{"version":1,"providers":{}}' >"$SHUNT_PROVIDERS_FILE"
  mkdir -p "$TEST_TMPDIR/noflock"
  local tool
  for tool in bash jq dirname mkdir rmdir mktemp sleep; do ln -s "$(command -v $tool)" "$TEST_TMPDIR/noflock/$tool"; done
  run env PATH="$TEST_TMPDIR/noflock" bash -c '
    source "$1/scripts/lib/providers.sh"
    trap "echo caller-trap-ran" EXIT
    shunt_providers_lock
    exit 0' _ "$REPO_ROOT"
  assert_output --partial "caller-trap-ran"
  [ ! -d "$SHUNT_PROVIDERS_FILE.lock.d" ]
}

@test "plaintext store with an empty stdin fails cleanly under set -e instead of aborting" {
  echo '{"version":1,"providers":{"p":{"transport":"http","base_url":"https://p.test/v1","key":{"type":"plaintext"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run bash -c 'set -e; source "$1/scripts/lib/providers.sh"; shunt_provider_plaintext_store p </dev/null; echo reached' _ "$REPO_ROOT"
  assert_output --partial "reached"
}
