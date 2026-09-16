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
