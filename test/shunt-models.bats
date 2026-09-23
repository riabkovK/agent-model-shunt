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

@test "thinking off with options stores them and renders them into both agent files" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  run "$SHUNT_MODELS_BIN" thinking "p/one" off '{"reasoningEffort":"none"}'
  assert_success
  run jq -r '.models[0].thinking' "$SHUNT_MODELS_FILE"
  assert_output "false"
  run jq -c '.models[0].thinking_off_options' "$SHUNT_MODELS_FILE"
  assert_output '{"reasoningEffort":"none"}'
  run grep -c "^reasoningEffort: none$" "$SHUNT_AGENTS_DIR/shunt-bulk-reader-p-one.md"
  assert_output "1"
  run grep -c "^reasoningEffort: none$" "$SHUNT_AGENTS_DIR/shunt-code-writer-p-one.md"
  assert_output "1"
}

@test "thinking off refuses off options that are not valid JSON" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  run "$SHUNT_MODELS_BIN" thinking "p/one" off "not json"
  assert_failure
  assert_output --partial "valid JSON"
  run jq -c '.models[0].thinking_off_options' "$SHUNT_MODELS_FILE"
  assert_output "null"
}

@test "thinking off refuses off options that are not a JSON object" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  run "$SHUNT_MODELS_BIN" thinking "p/one" off '["none"]'
  assert_failure
  assert_output --partial "JSON object"
  run "$SHUNT_MODELS_BIN" thinking "p/one" off '"none"'
  assert_failure
  run "$SHUNT_MODELS_BIN" thinking "p/one" off 'null'
  assert_failure
}

@test "thinking off without options keeps stored off options" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" thinking "p/one" off '{"reasoningEffort":"none"}'
  run "$SHUNT_MODELS_BIN" thinking "p/one" off
  assert_success
  run jq -c '.models[0].thinking_off_options' "$SHUNT_MODELS_FILE"
  assert_output '{"reasoningEffort":"none"}'
  run grep -c "^reasoningEffort: none$" "$SHUNT_AGENTS_DIR/shunt-bulk-reader-p-one.md"
  assert_output "1"
}

@test "thinking off with an empty object clears stored off options" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" thinking "p/one" off '{"reasoningEffort":"none"}'
  run "$SHUNT_MODELS_BIN" thinking "p/one" off '{}'
  assert_success
  run jq -c '.models[0].thinking_off_options' "$SHUNT_MODELS_FILE"
  assert_output "null"
  run grep -c "reasoningEffort" "$SHUNT_AGENTS_DIR/shunt-bulk-reader-p-one.md"
  assert_output "0"
  run grep -c "reasoningEffort" "$SHUNT_AGENTS_DIR/shunt-code-writer-p-one.md"
  assert_output "0"
}

@test "thinking on keeps stored off options and does not render them" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" thinking "p/one" off '{"reasoningEffort":"none"}'
  run "$SHUNT_MODELS_BIN" thinking "p/one" on '{"reasoningEffort":"high"}'
  assert_success
  run jq -c '.models[0].thinking_off_options' "$SHUNT_MODELS_FILE"
  assert_output '{"reasoningEffort":"none"}'
  run grep -c "^reasoningEffort: none$" "$SHUNT_AGENTS_DIR/shunt-bulk-reader-p-one.md"
  assert_output "0"
  run grep -c "^reasoningEffort: high$" "$SHUNT_AGENTS_DIR/shunt-bulk-reader-p-one.md"
  assert_output "1"
  run "$SHUNT_MODELS_BIN" thinking "p/one" off
  assert_success
  run grep -c "^reasoningEffort: none$" "$SHUNT_AGENTS_DIR/shunt-code-writer-p-one.md"
  assert_output "1"
}

@test "thinking off works on a registry entry that has no thinking_off_options field" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  local legacy
  legacy=$(jq -c 'del(.models[0].thinking_off_options)' "$SHUNT_MODELS_FILE")
  echo "$legacy" >"$SHUNT_MODELS_FILE"
  run "$SHUNT_MODELS_BIN" thinking "p/one" off
  assert_success
  run "$SHUNT_MODELS_BIN" thinking "p/one" off '{"reasoningEffort":"none"}'
  assert_success
  run jq -c '.models[0].thinking_off_options' "$SHUNT_MODELS_FILE"
  assert_output '{"reasoningEffort":"none"}'
}

@test "add records null off options for a new model" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  run jq -c '.models[0] | has("thinking_off_options"), .thinking_off_options' "$SHUNT_MODELS_FILE"
  assert_line --index 0 "true"
  assert_line --index 1 "null"
}

@test "status shows whether off options are set" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  "$SHUNT_MODELS_BIN" thinking "p/two" off '{"reasoningEffort":"none"}'
  run "$SHUNT_MODELS_BIN" status
  assert_success
  assert_line --regexp '^p/one.*thinking=false.*thinking_off=none.*roles='
  assert_line --regexp '^p/two.*thinking=false.*thinking_off=set.*roles='
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

@test "add gives the model both roles explicitly by default" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/m"
  run jq -c '.models[0].roles' "$SHUNT_MODELS_FILE"
  assert_output '["bulk-read","code-write"]'
}

@test "add records the roles it is given" {
  shunt_write_provider "p"
  run "$SHUNT_MODELS_BIN" add "p/m" "code-write"
  assert_success
  run jq -c '.models[0].roles' "$SHUNT_MODELS_FILE"
  assert_output '["code-write"]'
}

@test "add drops duplicate roles and keeps their order" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/m" "code-write,bulk-read,code-write"
  run jq -c '.models[0].roles' "$SHUNT_MODELS_FILE"
  assert_output '["code-write","bulk-read"]'
}

@test "add refuses an unknown role before touching the registry or agents" {
  shunt_write_provider "p"
  run "$SHUNT_MODELS_BIN" add "p/m" "bulk_read"
  assert_failure
  assert_output --partial "unknown role"
  [ ! -f "$SHUNT_MODELS_FILE" ]
  [ -z "$(ls -A "$SHUNT_AGENTS_DIR" 2>/dev/null)" ]
}

@test "add refuses an empty role entry" {
  shunt_write_provider "p"
  run "$SHUNT_MODELS_BIN" add "p/m" "bulk-read,"
  assert_failure
  [ ! -f "$SHUNT_MODELS_FILE" ]
}

@test "add with a restricted role set still materializes the agent" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/m" "bulk-read"
  local agent
  agent=$(jq -r '.models[0].agent' "$SHUNT_MODELS_FILE")
  [ -f "$SHUNT_AGENTS_DIR/$agent.md" ]
}

@test "roles sets a model's roles in the given order and leaves the rest alone" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  "$SHUNT_MODELS_BIN" activate "p/two"
  run "$SHUNT_MODELS_BIN" roles "p/one" "code-write,bulk-read"
  assert_success
  assert_output --partial "p/one"
  run jq -c '.models[0].roles' "$SHUNT_MODELS_FILE"
  assert_output '["code-write","bulk-read"]'
  run jq -c '.models[1].roles' "$SHUNT_MODELS_FILE"
  assert_output '["bulk-read","code-write"]'
  run jq -r '.active' "$SHUNT_MODELS_FILE"
  assert_output "p/two"
}

@test "roles accepts a single role and drops duplicates" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  run "$SHUNT_MODELS_BIN" roles "p/one" "code-write"
  assert_success
  run jq -c '.models[0].roles' "$SHUNT_MODELS_FILE"
  assert_output '["code-write"]'
  run "$SHUNT_MODELS_BIN" roles "p/one" "bulk-read,bulk-read"
  assert_success
  run jq -c '.models[0].roles' "$SHUNT_MODELS_FILE"
  assert_output '["bulk-read"]'
}

@test "roles produces a registry that shunt_models_candidates honors" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  "$SHUNT_MODELS_BIN" roles "p/one" "code-write"
  source "$REPO_ROOT/scripts/lib/models.sh"
  run shunt_models_candidates bulk-read
  assert_output "p/two"
  run shunt_models_candidates code-write
  assert_line --index 0 "p/one"
  assert_line --index 1 "p/two"
}

@test "roles refuses an unknown role and leaves the registry untouched" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  local before
  before=$(cat "$SHUNT_MODELS_FILE")
  run "$SHUNT_MODELS_BIN" roles "p/one" "bulk-read,summarize"
  assert_failure
  assert_output --partial "summarize"
  [ "$(cat "$SHUNT_MODELS_FILE")" = "$before" ]
}

@test "roles refuses an empty role list" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  local before
  before=$(cat "$SHUNT_MODELS_FILE")
  run "$SHUNT_MODELS_BIN" roles "p/one" ""
  assert_failure
  assert_output --partial "usage"
  run "$SHUNT_MODELS_BIN" roles "p/one" ","
  assert_failure
  assert_output --partial "empty role"
  run "$SHUNT_MODELS_BIN" roles "p/one" "bulk-read,"
  assert_failure
  assert_output --partial "empty role"
  run "$SHUNT_MODELS_BIN" roles "p/one" $'bulk-read\ncode-write'
  assert_failure
  [ "$(cat "$SHUNT_MODELS_FILE")" = "$before" ]
}

@test "roles refuses missing arguments with a usage message" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  run "$SHUNT_MODELS_BIN" roles
  assert_failure
  assert_output --partial "usage"
  run "$SHUNT_MODELS_BIN" roles "p/one"
  assert_failure
  assert_output --partial "usage"
}

@test "roles refuses an id not in the registry" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  run "$SHUNT_MODELS_BIN" roles "p/missing" "bulk-read"
  assert_failure
  assert_output --partial "not in the registry"
}

@test "roles refuses when no registry exists" {
  run "$SHUNT_MODELS_BIN" roles "p/one" "bulk-read"
  assert_failure
  assert_output --partial "no models registry"
}

@test "status shows each model's effective roles" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  "$SHUNT_MODELS_BIN" roles "p/two" "code-write"
  run "$SHUNT_MODELS_BIN" status
  assert_success
  assert_line --regexp '^p/one.*roles=bulk-read,code-write'
  assert_line --regexp '^p/two.*roles=code-write'
  refute_line --regexp '^p/two.*roles=bulk-read'
}

@test "status computes the first choice for the bulk-read role" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  "$SHUNT_MODELS_BIN" roles "p/one" "code-write"
  "$SHUNT_MODELS_BIN" activate "p/one"
  run "$SHUNT_MODELS_BIN" status
  assert_success
  assert_output --partial "first choice: p/two"
}

@test "status says reads are not redirected when no enabled model has the bulk-read role" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" roles "p/one" "code-write"
  run "$SHUNT_MODELS_BIN" status
  assert_success
  assert_output --partial "no enabled model has the bulk-read role (large reads are not redirected)"
  refute_output --partial "shunt: first choice"
}

@test "roles repairs a registry that is invalid only because of a bad roles value" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  jq '.models[0].roles = ["bulk_read"]' "$SHUNT_MODELS_FILE" >"$TEST_TMPDIR/edited.json"
  mv "$TEST_TMPDIR/edited.json" "$SHUNT_MODELS_FILE"
  run "$SHUNT_MODELS_BIN" roles "p/one" "bulk-read"
  assert_success
  run jq -c '.models[0].roles' "$SHUNT_MODELS_FILE"
  assert_output '["bulk-read"]'
  source "$REPO_ROOT/scripts/lib/models.sh"
  run shunt_models_validate
  assert_success
}

@test "status and list explain an invalid registry instead of claiming legacy mode" {
  echo '{"version":1,"active":null,"models":[{"id":"p/one","agent":"a","roles":["bulk_read"]}]}' >"$SHUNT_MODELS_FILE"
  run "$SHUNT_MODELS_BIN" status
  assert_success
  assert_output --partial "unknown role"
  assert_output --partial "bulk_read"
  run "$SHUNT_MODELS_BIN" list
  assert_success
  assert_output --partial "unknown role"
}

# --- code-writer agent files ---------------------------------------------

@test "add materializes a code-writer agent next to the bulk-reader agent" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/m"
  [ -f "$SHUNT_AGENTS_DIR/shunt-bulk-reader-p-m.md" ]
  [ -f "$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md" ]
}

@test "add with only the bulk-read role creates no code-writer agent" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/m" "bulk-read"
  [ -f "$SHUNT_AGENTS_DIR/shunt-bulk-reader-p-m.md" ]
  [ ! -e "$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md" ]
}

@test "remove deletes the code-writer agent file too" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/m"
  run "$SHUNT_MODELS_BIN" remove "p/m"
  assert_success
  [ ! -e "$SHUNT_AGENTS_DIR/shunt-bulk-reader-p-m.md" ]
  [ ! -e "$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md" ]
}

@test "sync creates a missing code-writer agent for a registry written before roles existed" {
  shunt_write_provider "p"
  mkdir -p "$SHUNT_AGENTS_DIR"
  echo '{"version":1,"active":null,"models":[{"id":"p/m","agent":"shunt-bulk-reader-p-m","enabled":true}]}' >"$SHUNT_MODELS_FILE"
  run "$SHUNT_MODELS_BIN" sync
  assert_success
  [ -f "$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md" ]
}

@test "sync removes a code-writer agent of a model that lacks the role" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/m"
  local tmp
  tmp=$(jq '.models[0].roles = ["bulk-read"]' "$SHUNT_MODELS_FILE") && echo "$tmp" >"$SHUNT_MODELS_FILE"
  run "$SHUNT_MODELS_BIN" sync
  assert_success
  [ ! -e "$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md" ]
}

@test "roles removes the code-writer agent when code-write is dropped and restores it when added back" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/m"
  run "$SHUNT_MODELS_BIN" roles "p/m" bulk-read
  assert_success
  [ ! -e "$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md" ]
  [ -f "$SHUNT_AGENTS_DIR/shunt-bulk-reader-p-m.md" ]
  run "$SHUNT_MODELS_BIN" roles "p/m" bulk-read,code-write
  assert_success
  [ -f "$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md" ]
}

@test "roles keeps the agent files consistent for a code-write only model" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/m" bulk-read
  run "$SHUNT_MODELS_BIN" roles "p/m" code-write
  assert_success
  [ -f "$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md" ]
}

@test "thinking on also refreshes the code-writer agent" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/m"
  "$SHUNT_MODELS_BIN" thinking "p/m" on '{"reasoningEffort":"high"}'
  grep -q "^reasoningEffort: high$" "$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md"
}

@test "status names the code-write first choice separately from the bulk-read one" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/reader" bulk-read
  "$SHUNT_MODELS_BIN" add "p/writer" code-write
  "$SHUNT_MODELS_BIN" activate "p/reader"
  run "$SHUNT_MODELS_BIN" status
  assert_success
  assert_line "shunt: first choice: p/reader"
  assert_line "shunt: code-write first choice: p/writer"
}

@test "status says code-write is unavailable when no enabled model has the role" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/m" bulk-read
  run "$SHUNT_MODELS_BIN" status
  assert_success
  assert_output --partial "no enabled model has the code-write role"
  refute_output --partial "code-write first choice"
}

@test "remove also drops the model's code-write breaker key, keeping other models'" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  echo '{"version":1,"models":{"p/one":{"failures":1,"cooldown_until":0},"p/one#code-write":{"failures":3,"cooldown_until":9999999999},"p/two#code-write":{"failures":2,"cooldown_until":0}}}' \
    >"$SHUNT_BREAKER_STATE_FILE"

  run "$SHUNT_MODELS_BIN" remove "p/one"
  assert_success
  run jq -r '.models | keys | join(",")' "$SHUNT_BREAKER_STATE_FILE"
  assert_output "p/two#code-write"
}

@test "status shows the code-write breaker state of each model with that role" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  "$SHUNT_MODELS_BIN" add "p/two"
  "$SHUNT_MODELS_BIN" roles "p/two" bulk-read
  echo '{"version":1,"models":{"p/one#code-write":{"failures":3,"cooldown_until":9999999999}}}' \
    >"$SHUNT_BREAKER_STATE_FILE"
  export SHUNT_NOW_EPOCH=1000

  run "$SHUNT_MODELS_BIN" status
  assert_success
  assert_output --partial "code-write breaker p/one: failures=3 open=true"
  refute_output --partial "code-write breaker p/two"
}

@test "status warns once about an active model missing from the registry" {
  shunt_write_provider "p"
  "$SHUNT_MODELS_BIN" add "p/one"
  jq '.active = "p/missing"' "$SHUNT_MODELS_FILE" >"$TEST_TMPDIR/m.json" && mv "$TEST_TMPDIR/m.json" "$SHUNT_MODELS_FILE"

  run "$SHUNT_MODELS_BIN" status
  assert_success
  [ "$(echo "$output" | grep -c "falling back to priority order")" -eq 1 ]
}
