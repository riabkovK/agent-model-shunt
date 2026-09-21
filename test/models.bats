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

@test "shunt_models_validate accepts a roles array of known roles" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/a","agent":"a1","roles":["bulk-read"]},
  {"id":"p/b","agent":"a2","roles":["code-write","bulk-read"]},
  {"id":"p/c","agent":"a3"}
]}
JSON
  run shunt_models_validate
  assert_success
  assert_output ""
}

@test "shunt_models_validate rejects an unknown role, naming the model and the role" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/a","agent":"a1","roles":["bulk-read","summarize"]}
]}
JSON
  run shunt_models_validate
  assert_failure
  assert_output --partial "p/a"
  assert_output --partial "unknown role"
  assert_output --partial "summarize"
  run shunt_models_available
  assert_failure
}

@test "shunt_models_validate rejects an empty roles array" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/a","agent":"a1","roles":[]}
]}
JSON
  run shunt_models_validate
  assert_failure
  assert_output --partial "p/a"
  assert_output --partial "empty"
}

@test "shunt_models_validate rejects roles that is not an array" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/a","agent":"a1","roles":"bulk-read"}
]}
JSON
  run shunt_models_validate
  assert_failure
  assert_output --partial "p/a"
  assert_output --partial "must be an array"
}

@test "shunt_models_validate rejects a non-string role value" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/a","agent":"a1","roles":[1]}
]}
JSON
  run shunt_models_validate
  assert_failure
  assert_output --partial "unknown role"
}

@test "shunt_models_validate rejects a nested array as a role" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/a","agent":"a1","roles":[["bulk-read"]]}
]}
JSON
  run shunt_models_validate
  assert_failure
  assert_output --partial "unknown role"
}

@test "shunt_models_validate rejects roles set to null" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/a","agent":"a1","roles":null}
]}
JSON
  run shunt_models_validate
  assert_failure
  assert_output --partial "must be an array"
}

@test "the bash and JSON role lists stay in sync" {
  [ "$(jq -c . <<<"$SHUNT_MODELS_ROLES_JSON")" = "$(printf '%s\n' "${SHUNT_MODELS_ROLES[@]}" | jq -R . | jq -sc .)" ]
}

@test "shunt_models_candidates prints only the warning when active is unknown and no model has the role" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":"p/missing","models":[
  {"id":"p/reader","agent":"a1","roles":["bulk-read"]}
]}
JSON
  run shunt_models_candidates code-write
  assert_success
  [ "${#lines[@]}" -eq 1 ]
  assert_line --partial "falling back to priority order"
}

@test "shunt_models_candidates treats a missing roles field as both roles" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/first","agent":"a1"},
  {"id":"p/second","agent":"a2"}
]}
JSON
  run shunt_models_candidates bulk-read
  assert_success
  assert_line --index 0 "p/first"
  assert_line --index 1 "p/second"
  [ "${#lines[@]}" -eq 2 ]
  run shunt_models_candidates code-write
  assert_success
  assert_line --index 0 "p/first"
  assert_line --index 1 "p/second"
  [ "${#lines[@]}" -eq 2 ]
}

@test "shunt_models_candidates keeps only models that have the requested role" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/reader","agent":"a1","roles":["bulk-read"]},
  {"id":"p/writer","agent":"a2","roles":["code-write"]},
  {"id":"p/both","agent":"a3","roles":["code-write","bulk-read"]},
  {"id":"p/legacy","agent":"a4"}
]}
JSON
  run shunt_models_candidates bulk-read
  assert_success
  assert_line --index 0 "p/reader"
  assert_line --index 1 "p/both"
  assert_line --index 2 "p/legacy"
  [ "${#lines[@]}" -eq 3 ]
  run shunt_models_candidates code-write
  assert_success
  assert_line --index 0 "p/writer"
  assert_line --index 1 "p/both"
  assert_line --index 2 "p/legacy"
  [ "${#lines[@]}" -eq 3 ]
}

@test "shunt_models_candidates puts the active model first within a role, deduped" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":"p/third","models":[
  {"id":"p/first","agent":"a1","roles":["code-write"]},
  {"id":"p/second","agent":"a2","roles":["bulk-read"]},
  {"id":"p/third","agent":"a3","roles":["code-write","bulk-read"]}
]}
JSON
  run shunt_models_candidates code-write
  assert_success
  assert_line --index 0 "p/third"
  assert_line --index 1 "p/first"
  [ "${#lines[@]}" -eq 2 ]
  run shunt_models_candidates bulk-read
  assert_success
  assert_line --index 0 "p/third"
  assert_line --index 1 "p/second"
  [ "${#lines[@]}" -eq 2 ]
}

@test "shunt_models_candidates skips an active model lacking the role without noise" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":"p/reader","models":[
  {"id":"p/first","agent":"a1"},
  {"id":"p/reader","agent":"a2","roles":["bulk-read"]},
  {"id":"p/third","agent":"a3"}
]}
JSON
  run shunt_models_candidates code-write
  assert_success
  assert_line --index 0 "p/first"
  assert_line --index 1 "p/third"
  [ "${#lines[@]}" -eq 2 ]
  refute_output --partial "falling back"
}

@test "shunt_models_candidates excludes disabled models within a role" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":"p/off","models":[
  {"id":"p/off","agent":"a1","enabled":false,"roles":["code-write"]},
  {"id":"p/on","agent":"a2","roles":["code-write"]}
]}
JSON
  run shunt_models_candidates code-write
  assert_success
  [ "${#lines[@]}" -eq 1 ]
  assert_line --index 0 "p/on"
}

@test "shunt_models_candidates prints nothing when no enabled model has the role" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":"p/reader","models":[
  {"id":"p/reader","agent":"a1","roles":["bulk-read"]},
  {"id":"p/off","agent":"a2","enabled":false,"roles":["code-write"]}
]}
JSON
  run shunt_models_candidates code-write
  assert_success
  assert_output ""
}

@test "shunt_models_candidates defaults to the bulk-read role when called without one" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/writer","agent":"a1","roles":["code-write"]},
  {"id":"p/reader","agent":"a2","roles":["bulk-read"]}
]}
JSON
  run shunt_models_candidates
  assert_success
  [ "${#lines[@]}" -eq 1 ]
  assert_line --index 0 "p/reader"
}

@test "shunt_models_candidates rejects an unknown role argument" {
  echo '{"version":1,"active":null,"models":[{"id":"p/a","agent":"a1"}]}' >"$SHUNT_MODELS_FILE"
  run shunt_models_candidates summarize
  assert_failure
  assert_output --partial "unknown role"
}

@test "shunt_models_candidates still warns about an unknown active model for a role" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":"p/missing","models":[
  {"id":"p/first","agent":"a1","roles":["code-write"]}
]}
JSON
  run shunt_models_candidates code-write
  assert_success
  assert_line --partial "p/first"
  assert_line --partial "falling back to priority order"
}

@test "shunt_models_candidates reads the registry with a single jq call" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":"p/second","models":[
  {"id":"p/first","agent":"a1"},
  {"id":"p/second","agent":"a2","roles":["code-write"]}
]}
JSON
  local real_jq shim_dir="$TEST_TMPDIR/shim"
  real_jq=$(command -v jq)
  mkdir -p "$shim_dir"
  printf '#!/bin/bash\necho x >>"%s/jq-calls"\nexec "%s" "$@"\n' "$TEST_TMPDIR" "$real_jq" >"$shim_dir/jq"
  chmod +x "$shim_dir/jq"
  PATH="$shim_dir:$PATH" run shunt_models_candidates code-write
  assert_success
  [ "$(wc -l <"$TEST_TMPDIR/jq-calls" | tr -d ' ')" -eq 1 ]
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

@test "shunt_models_thinking_off_options_for prints null when the field is missing" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/m","agent":"a","thinking":false,"thinking_options":null}
]}
JSON
  run shunt_models_thinking_off_options_for "p/m"
  assert_success
  assert_output "null"
}

@test "shunt_models_thinking_off_options_for prints the stored object" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/m","agent":"a","thinking":false,"thinking_options":null,"thinking_off_options":{"reasoningEffort":"none"}}
]}
JSON
  run shunt_models_thinking_off_options_for "p/m"
  assert_success
  assert_output '{"reasoningEffort":"none"}'
}

@test "the thinking block renders off options when thinking is off" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/m","agent":"a","thinking":false,"thinking_options":null,"thinking_off_options":{"reasoningEffort":"none"}}
]}
JSON
  run _shunt_models_thinking_block "p/m"
  assert_success
  assert_output "reasoningEffort: none"
}

@test "the thinking block is empty when thinking is off and no off options are stored" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/m","agent":"a","thinking":false,"thinking_options":null}
]}
JSON
  run _shunt_models_thinking_block "p/m"
  assert_success
  assert_output ""
}

@test "the thinking block ignores off options when thinking is on" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/m","agent":"a","thinking":true,"thinking_options":{"reasoningEffort":"high"},"thinking_off_options":{"reasoningEffort":"none"}}
]}
JSON
  run _shunt_models_thinking_block "p/m"
  assert_success
  assert_output "reasoningEffort: high"
}

@test "shunt_models_materialize_agent writes off options into both agent files when thinking is off" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/m","agent":"shunt-bulk-reader-p-m","thinking":false,"thinking_options":null,"thinking_off_options":{"reasoningEffort":"none"}}
]}
JSON
  run shunt_models_materialize_agent "p/m"
  assert_success
  run grep -c "^reasoningEffort: none$" "$SHUNT_AGENTS_DIR/shunt-bulk-reader-p-m.md"
  assert_output "1"
  run grep -c "^reasoningEffort: none$" "$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md"
  assert_output "1"
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

@test "shunt_models_code_writer_agent_for derives the agent name from the model id" {
  run shunt_models_code_writer_agent_for "Spark/deepseek-ai/DeepSeek-V4-Flash-0731"
  assert_success
  assert_output "shunt-code-writer-spark-deepseek-ai-deepseek-v4-flash-0731"
}

@test "shunt_models_has_role is true for a listed role and for every role when roles is missing" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/all","agent":"a1"},
  {"id":"p/read","agent":"a2","roles":["bulk-read"]}
]}
JSON
  run shunt_models_has_role "p/all" code-write
  assert_success
  run shunt_models_has_role "p/read" bulk-read
  assert_success
  run shunt_models_has_role "p/read" code-write
  assert_failure
}

@test "shunt_models_materialize_agent also writes a tool-less code-writer agent for a code-write model" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/m","agent":"shunt-bulk-reader-p-m","thinking":false,"thinking_options":null}
]}
JSON
  run shunt_models_materialize_agent "p/m"
  assert_success
  local agent_file="$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md"
  [ -f "$agent_file" ]
  grep -q "^model: p/m$" "$agent_file"
  grep -q "^mode: primary$" "$agent_file"
  grep -q "^temperature: 0.2$" "$agent_file"
  grep -q "^  read: false$" "$agent_file"
  grep -q "^  write: false$" "$agent_file"
  grep -q "^  edit: false$" "$agent_file"
  grep -q "^  bash: false$" "$agent_file"
  run grep -c ": true$" "$agent_file"
  assert_output "0"
}

@test "the code-writer agent prompt describes the response protocol" {
  echo '{"version":1,"active":null,"models":[{"id":"p/m","agent":"shunt-bulk-reader-p-m"}]}' >"$SHUNT_MODELS_FILE"
  shunt_models_materialize_agent "p/m"
  local agent_file="$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md"
  grep -q '^<<<SHUNT-NOTES>>>$' "$agent_file"
  grep -q '^<<<SHUNT-CODE>>>$' "$agent_file"
  grep -qi "exactly one" "$agent_file"
  grep -qi "only symbols" "$agent_file"
  grep -qi "not wrap" "$agent_file"
  grep -q "four backticks" "$agent_file"
}

@test "the code-writer agent prompt says each delimiter appears once and is never quoted" {
  echo '{"version":1,"active":null,"models":[{"id":"p/m","agent":"shunt-bulk-reader-p-m"}]}' >"$SHUNT_MODELS_FILE"
  shunt_models_materialize_agent "p/m"
  local agent_file="$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md"
  grep -q "exactly once in the whole reply" "$agent_file"
  grep -q "never quoted" "$agent_file"
}

@test "the code-writer agent prompt carries a full example reply with notes, delimiters and code" {
  echo '{"version":1,"active":null,"models":[{"id":"p/m","agent":"shunt-bulk-reader-p-m"}]}' >"$SHUNT_MODELS_FILE"
  shunt_models_materialize_agent "p/m"
  local agent_file="$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md"
  local example
  example=$(sed -n '/^Example of a complete, correct reply/,/^End of example\.$/p' "$agent_file")
  [ -n "$example" ]
  # Notes line, then the code delimiter, then the code, in that order.
  [ "$(echo "$example" | grep -n '^<<<SHUNT-NOTES>>>$' | cut -d: -f1)" -lt "$(echo "$example" | grep -n '^<<<SHUNT-CODE>>>$' | cut -d: -f1)" ]
  [ "$(echo "$example" | grep -c '^<<<SHUNT-NOTES>>>$')" -eq 1 ]
  [ "$(echo "$example" | grep -c '^<<<SHUNT-CODE>>>$')" -eq 1 ]
  echo "$example" | grep -q '^def add(a, b):$'
}

@test "shunt_models_materialize_agent skips the code-writer agent for a model without the role" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/m","agent":"shunt-bulk-reader-p-m","roles":["bulk-read"]}
]}
JSON
  shunt_models_materialize_agent "p/m"
  [ -f "$SHUNT_AGENTS_DIR/shunt-bulk-reader-p-m.md" ]
  [ ! -e "$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md" ]
}

@test "shunt_models_materialize_agent removes a stale code-writer agent once the role is gone" {
  echo '{"version":1,"active":null,"models":[{"id":"p/m","agent":"shunt-bulk-reader-p-m"}]}' >"$SHUNT_MODELS_FILE"
  shunt_models_materialize_agent "p/m"
  [ -f "$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md" ]
  echo '{"version":1,"active":null,"models":[{"id":"p/m","agent":"shunt-bulk-reader-p-m","roles":["bulk-read"]}]}' >"$SHUNT_MODELS_FILE"
  shunt_models_materialize_agent "p/m"
  [ ! -e "$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md" ]
}

@test "shunt_models_materialize_agent merges thinking_options into the code-writer agent too" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/m","agent":"shunt-bulk-reader-p-m","thinking":true,"thinking_options":{"reasoningEffort":"high"}}
]}
JSON
  shunt_models_materialize_agent "p/m"
  grep -q "^reasoningEffort: high$" "$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md"
}

@test "the code-writer agent denies every tool by default, not only the listed ones" {
  echo '{"version":1,"active":null,"models":[{"id":"p/m","agent":"shunt-bulk-reader-p-m"}]}' >"$SHUNT_MODELS_FILE"
  shunt_models_materialize_agent "p/m"
  local agent_file="$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md"
  awk '/^tools:$/{getline; print; exit}' "$agent_file" | grep -qx '  "\*": false'
}
