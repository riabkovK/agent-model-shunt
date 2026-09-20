load 'test_helper'

SHUNT_MODELS_BIN="$REPO_ROOT/scripts/shunt-models"

setup() {
  shunt_test_setup
}

teardown() {
  shunt_test_teardown
}

@test "add creates the registry and materializes an agent file" {
  shunt_write_provider "p"
  run "$SHUNT_MODELS_BIN" add "p/m"
  assert_success
  [ -f "$SHUNT_MODELS_FILE" ]
  run jq -r '.models | length' "$SHUNT_MODELS_FILE"
  assert_output "1"
  run jq -r '.models[0].id' "$SHUNT_MODELS_FILE"
  assert_output "p/m"
  local agent
  agent=$(jq -r '.models[0].agent' "$SHUNT_MODELS_FILE")
  [ -f "$SHUNT_AGENTS_DIR/$agent.md" ]
}

@test "add refuses a model whose provider is missing from opencode.json" {
  echo '{"provider":{}}' >"$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"
  run "$SHUNT_MODELS_BIN" add "missing-provider/m"
  assert_failure
  assert_output --partial "missing-provider"
}

@test "add refuses a duplicate id" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/m"
  run "$SHUNT_MODELS_BIN" add "p/m"
  assert_failure
}

@test "add preserves an existing valid registry on a rejected edit" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/m"
  local before
  before=$(cat "$SHUNT_MODELS_FILE")
  run "$SHUNT_MODELS_BIN" add "p/m"
  assert_failure
  [ "$(cat "$SHUNT_MODELS_FILE")" = "$before" ]
}

@test "remove drops a model from the registry" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  run "$SHUNT_MODELS_BIN" remove "p/one"
  assert_success
  run jq -r '.models | length' "$SHUNT_MODELS_FILE"
  assert_output "1"
  run jq -r '.models[0].id' "$SHUNT_MODELS_FILE"
  assert_output "p/two"
}

@test "remove deletes the model's materialized agent file" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  local one_agent two_agent
  one_agent=$(jq -r '.models[] | select(.id == "p/one") | .agent' "$SHUNT_MODELS_FILE")
  two_agent=$(jq -r '.models[] | select(.id == "p/two") | .agent' "$SHUNT_MODELS_FILE")
  [ -f "$SHUNT_AGENTS_DIR/$one_agent.md" ]

  run "$SHUNT_MODELS_BIN" remove "p/one"
  assert_success
  [ ! -f "$SHUNT_AGENTS_DIR/$one_agent.md" ]
  [ -f "$SHUNT_AGENTS_DIR/$two_agent.md" ]
}

@test "remove drops the model's circuit breaker state, keeping other models'" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  echo '{"version":1,"models":{"p/one":{"failures":3,"cooldown_until":9999999999},"p/two":{"failures":1,"cooldown_until":0}}}' \
    >"$SHUNT_BREAKER_STATE_FILE"

  run "$SHUNT_MODELS_BIN" remove "p/one"
  assert_success
  run jq -r '.models | has("p/one")' "$SHUNT_BREAKER_STATE_FILE"
  assert_output "false"
  run jq -r '.models["p/two"].failures' "$SHUNT_BREAKER_STATE_FILE"
  assert_output "1"
}

@test "remove succeeds when there is no breaker state file or agent file" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  local agent
  agent=$(jq -r '.models[] | select(.id == "p/one") | .agent' "$SHUNT_MODELS_FILE")
  rm -f "$SHUNT_AGENTS_DIR/$agent.md" "$SHUNT_BREAKER_STATE_FILE"

  run "$SHUNT_MODELS_BIN" remove "p/one"
  assert_success
  [ ! -f "$SHUNT_BREAKER_STATE_FILE" ]
}

@test "remove allows dropping the last model, leaving a valid empty registry" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/only"
  local agent
  agent=$(jq -r '.models[0].agent' "$SHUNT_MODELS_FILE")

  run "$SHUNT_MODELS_BIN" remove "p/only"
  assert_success
  run jq -r '.models | length' "$SHUNT_MODELS_FILE"
  assert_output "0"
  [ ! -f "$SHUNT_AGENTS_DIR/$agent.md" ]
  run "$SHUNT_MODELS_BIN" status
  assert_success
  run "$SHUNT_MODELS_BIN" add "p/again"
  assert_success
}

@test "add records the model as enabled" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/m"
  run jq -r '.models[0].enabled' "$SHUNT_MODELS_FILE"
  assert_output "true"
}

@test "disable and enable flip one model's flag without touching the rest" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"

  run "$SHUNT_MODELS_BIN" disable "p/one"
  assert_success
  run jq -r '.models[] | select(.id == "p/one") | .enabled' "$SHUNT_MODELS_FILE"
  assert_output "false"
  run jq -r '.models[] | select(.id == "p/two") | .enabled' "$SHUNT_MODELS_FILE"
  assert_output "true"

  run "$SHUNT_MODELS_BIN" enable "p/one"
  assert_success
  run jq -r '.models[] | select(.id == "p/one") | .enabled' "$SHUNT_MODELS_FILE"
  assert_output "true"
}

@test "disable keeps the model's position, agent file and active marker" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  "$SHUNT_MODELS_BIN" activate "p/one"
  local agent
  agent=$(jq -r '.models[0].agent' "$SHUNT_MODELS_FILE")

  "$SHUNT_MODELS_BIN" disable "p/one"
  run jq -r '.models[0].id' "$SHUNT_MODELS_FILE"
  assert_output "p/one"
  run jq -r '.active' "$SHUNT_MODELS_FILE"
  assert_output "p/one"
  [ -f "$SHUNT_AGENTS_DIR/$agent.md" ]
}

@test "disable and enable refuse an id not in the registry" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  run "$SHUNT_MODELS_BIN" disable "p/missing"
  assert_failure
  run "$SHUNT_MODELS_BIN" enable "p/missing"
  assert_failure
}

@test "disable and enable treat a registry entry with no enabled field as enabled" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  local tmp
  tmp=$(jq 'del(.models[0].enabled)' "$SHUNT_MODELS_FILE") && echo "$tmp" >"$SHUNT_MODELS_FILE"
  run "$SHUNT_MODELS_BIN" status
  assert_output --partial "enabled"
  refute_output --partial "disabled"
}

@test "status marks a disabled model" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" disable "p/one"
  run "$SHUNT_MODELS_BIN" status
  assert_success
  assert_output --partial "disabled"
}

@test "status names the first choice, which is the active model when it is enabled" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  "$SHUNT_MODELS_BIN" activate "p/two"
  run "$SHUNT_MODELS_BIN" status
  assert_success
  assert_output --partial "first choice: p/two"
}

@test "status shows the next enabled model as first choice when the active one is disabled" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  "$SHUNT_MODELS_BIN" activate "p/one"
  "$SHUNT_MODELS_BIN" disable "p/one"
  run "$SHUNT_MODELS_BIN" status
  assert_success
  assert_output --partial "active (skipped, disabled)"
  assert_output --partial "first choice: p/two"
}

@test "status says reads are not redirected when every model is disabled" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" disable "p/one"
  run "$SHUNT_MODELS_BIN" status
  assert_success
  assert_output --partial "no enabled models (large reads are not redirected)"
  refute_output --partial "first choice"
}

@test "activate refuses a disabled model" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" disable "p/one"
  run "$SHUNT_MODELS_BIN" activate "p/one"
  assert_failure
  assert_output --partial "disabled"
}

@test "remove clears active when removing the active model" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  "$SHUNT_MODELS_BIN" activate "p/one"
  run "$SHUNT_MODELS_BIN" remove "p/one"
  assert_success
  run jq -r '.active // "null"' "$SHUNT_MODELS_FILE"
  assert_output "null"
}

@test "reorder moves a model to the given 1-based position" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  "$SHUNT_MODELS_BIN" add "p/three"
  run "$SHUNT_MODELS_BIN" reorder "p/three" 1
  assert_success
  run jq -r '.models[0].id' "$SHUNT_MODELS_FILE"
  assert_output "p/three"
}

@test "activate sets the active model" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  run "$SHUNT_MODELS_BIN" activate "p/one"
  assert_success
  run jq -r '.active' "$SHUNT_MODELS_FILE"
  assert_output "p/one"
}

@test "activate refuses an id not in the registry" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  run "$SHUNT_MODELS_BIN" activate "p/unknown"
  assert_failure
}

@test "thinking on with options sets the flag and merges options into the agent file" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  run "$SHUNT_MODELS_BIN" thinking "p/one" on '{"reasoningEffort":"high"}'
  assert_success
  run jq -r '.models[0].thinking' "$SHUNT_MODELS_FILE"
  assert_output "true"
  run jq -c '.models[0].thinking_options' "$SHUNT_MODELS_FILE"
  assert_output '{"reasoningEffort":"high"}'
  local agent
  agent=$(jq -r '.models[0].agent' "$SHUNT_MODELS_FILE")
  run grep -c "^reasoningEffort: high$" "$SHUNT_AGENTS_DIR/$agent.md"
  assert_output "1"
}

@test "thinking off clears the flag and options and re-materializes without them" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" thinking "p/one" on '{"reasoningEffort":"high"}'
  run "$SHUNT_MODELS_BIN" thinking "p/one" off
  assert_success
  run jq -r '.models[0].thinking' "$SHUNT_MODELS_FILE"
  assert_output "false"
  run jq -r '.models[0].thinking_options' "$SHUNT_MODELS_FILE"
  assert_output "null"
  local agent
  agent=$(jq -r '.models[0].agent' "$SHUNT_MODELS_FILE")
  run grep -c "reasoningEffort" "$SHUNT_AGENTS_DIR/$agent.md"
  assert_output "0"
}

@test "thinking refuses an invalid state" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  run "$SHUNT_MODELS_BIN" thinking "p/one" maybe
  assert_failure
}

@test "thinking refuses invalid options JSON" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  run "$SHUNT_MODELS_BIN" thinking "p/one" on "not json"
  assert_failure
}

@test "thinking refuses an id not in the registry" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  run "$SHUNT_MODELS_BIN" thinking "p/unknown" on
  assert_failure
}

@test "list prints registered ids" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  run "$SHUNT_MODELS_BIN" list
  assert_success
  assert_line --partial "p/one"
  assert_line --partial "p/two"
}

@test "sync re-materializes all agent files" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  local agent
  agent=$(jq -r '.models[0].agent' "$SHUNT_MODELS_FILE")
  rm -f "$SHUNT_AGENTS_DIR/$agent.md"
  run "$SHUNT_MODELS_BIN" sync
  assert_success
  [ -f "$SHUNT_AGENTS_DIR/$agent.md" ]
}
