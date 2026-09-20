load 'test_helper'

setup() {
  shunt_test_setup
  source "$REPO_ROOT/scripts/lib/models.sh"
}

teardown() {
  shunt_test_teardown
}

@test "shunt_models_available is false when no registry file exists" {
  run shunt_models_available
  assert_failure
}

@test "shunt_models_available is true for a valid registry" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[{"id":"p/m","agent":"shunt-bulk-reader-p-m","thinking":false,"thinking_options":null}]}
JSON
  run shunt_models_available
  assert_success
}

@test "shunt_models_validate rejects malformed JSON with a clear error" {
  echo 'not json' >"$SHUNT_MODELS_FILE"
  run shunt_models_validate
  assert_failure
  assert_output --partial "invalid JSON"
}

@test "shunt_models_validate accepts an empty models array" {
  echo '{"version":1,"active":null,"models":[]}' >"$SHUNT_MODELS_FILE"
  run shunt_models_validate
  assert_success
  run shunt_models_available
  assert_success
}

@test "shunt_models_candidates prints nothing for an empty registry" {
  echo '{"version":1,"active":null,"models":[]}' >"$SHUNT_MODELS_FILE"
  run shunt_models_candidates
  assert_success
  assert_output ""
}

@test "shunt_models_candidates skips disabled models, treating a missing enabled field as enabled" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/first","agent":"a1","enabled":false},
  {"id":"p/second","agent":"a2"},
  {"id":"p/third","agent":"a3","enabled":true}
]}
JSON
  run shunt_models_candidates
  assert_success
  assert_line --index 0 "p/second"
  assert_line --index 1 "p/third"
  [ "${#lines[@]}" -eq 2 ]
}

@test "shunt_models_candidates ignores a disabled active model without noise" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":"p/second","models":[
  {"id":"p/first","agent":"a1","enabled":true},
  {"id":"p/second","agent":"a2","enabled":false}
]}
JSON
  run shunt_models_candidates
  assert_success
  [ "${#lines[@]}" -eq 1 ]
  assert_line --index 0 "p/first"
}

@test "shunt_models_candidates prints nothing when every model is disabled" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":"p/one","models":[{"id":"p/one","agent":"a1","enabled":false}]}
JSON
  run shunt_models_candidates
  assert_success
  assert_output ""
}

@test "shunt_models_validate rejects duplicate ids" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/m","agent":"a1","thinking":false,"thinking_options":null},
  {"id":"p/m","agent":"a2","thinking":false,"thinking_options":null}
]}
JSON
  run shunt_models_validate
  assert_failure
  assert_output --partial "duplicate"
}

@test "shunt_models_candidates preserves priority order" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/first","agent":"a1","thinking":false,"thinking_options":null},
  {"id":"p/second","agent":"a2","thinking":false,"thinking_options":null},
  {"id":"p/third","agent":"a3","thinking":false,"thinking_options":null}
]}
JSON
  run shunt_models_candidates
  assert_success
  assert_line --index 0 "p/first"
  assert_line --index 1 "p/second"
  assert_line --index 2 "p/third"
}

@test "shunt_models_candidates puts a valid active model first, then priority order, deduped" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":"p/second","models":[
  {"id":"p/first","agent":"a1","thinking":false,"thinking_options":null},
  {"id":"p/second","agent":"a2","thinking":false,"thinking_options":null},
  {"id":"p/third","agent":"a3","thinking":false,"thinking_options":null}
]}
JSON
  run shunt_models_candidates
  assert_success
  assert_line --index 0 "p/second"
  assert_line --index 1 "p/first"
  assert_line --index 2 "p/third"
  [ "${#lines[@]}" -eq 3 ]
}

@test "shunt_models_candidates warns and falls back to head when active is unknown" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":"p/missing","models":[
  {"id":"p/first","agent":"a1","thinking":false,"thinking_options":null},
  {"id":"p/second","agent":"a2","thinking":false,"thinking_options":null}
]}
JSON
  run shunt_models_candidates
  assert_success
  assert_line --partial "p/first"
  assert_line --partial "p/second"
  assert_line --partial "falling back to priority order"
}

@test "shunt_models_agent_for returns the registered agent name" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/m","agent":"shunt-bulk-reader-p-m","thinking":false,"thinking_options":null}
]}
JSON
  run shunt_models_agent_for "p/m"
  assert_success
  assert_output "shunt-bulk-reader-p-m"
}

@test "shunt_models_thinking_for returns the registered thinking flag" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/m","agent":"a","thinking":true,"thinking_options":null}
]}
JSON
  run shunt_models_thinking_for "p/m"
  assert_success
  assert_output "true"
}

@test "shunt_models_slug lowercases and dashes a provider/model id" {
  run shunt_models_slug "Spark/deepseek-ai/DeepSeek-V4-Flash-0731"
  assert_success
  assert_output "shunt-bulk-reader-spark-deepseek-ai-deepseek-v4-flash-0731"
}

@test "shunt_models_slug handles dots and consecutive separators" {
  run shunt_models_slug "P.rovider/Model--Name"
  assert_success
  assert_output "shunt-bulk-reader-p-rovider-model-name"
}

@test "shunt_models_materialize_agent writes an OpenCode agent file with the model id" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/m","agent":"shunt-bulk-reader-p-m","thinking":false,"thinking_options":null}
]}
JSON
  run shunt_models_materialize_agent "p/m"
  assert_success
  local agent_file="$SHUNT_AGENTS_DIR/shunt-bulk-reader-p-m.md"
  [ -f "$agent_file" ]
  run grep -c "^model: p/m$" "$agent_file"
  assert_output "1"
  run grep -c "^mode: primary$" "$agent_file"
  assert_output "1"
  run grep -c "^  read: true$" "$agent_file"
  assert_output "1"
  run grep -c "^  bash: false$" "$agent_file"
  assert_output "1"
}

@test "shunt_models_materialize_agent omits reasoning frontmatter when thinking is off" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/m","agent":"shunt-bulk-reader-p-m","thinking":false,"thinking_options":{"reasoningEffort":"high"}}
]}
JSON
  run shunt_models_materialize_agent "p/m"
  assert_success
  local agent_file="$SHUNT_AGENTS_DIR/shunt-bulk-reader-p-m.md"
  run grep -c "reasoningEffort" "$agent_file"
  assert_output "0"
}

@test "shunt_models_materialize_agent merges thinking_options into frontmatter when thinking is on" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/m","agent":"shunt-bulk-reader-p-m","thinking":true,"thinking_options":{"reasoningEffort":"high"}}
]}
JSON
  run shunt_models_materialize_agent "p/m"
  assert_success
  local agent_file="$SHUNT_AGENTS_DIR/shunt-bulk-reader-p-m.md"
  run grep -c "^reasoningEffort: high$" "$agent_file"
  assert_output "1"
}
