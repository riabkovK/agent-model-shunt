load 'test_helper'
bats_require_minimum_version 1.5.0

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
  grep -q '^<SHUNT-NOTES>$' "$agent_file"
  grep -q '^</SHUNT-NOTES>$' "$agent_file"
  grep -q '^<SHUNT-CODE>$' "$agent_file"
  grep -q '^</SHUNT-CODE>$' "$agent_file"
  grep -qi "exactly one" "$agent_file"
  grep -qi "only symbols" "$agent_file"
  grep -qi "not wrap" "$agent_file"
  grep -q "four backticks" "$agent_file"
}

@test "the code-writer agent prompt says each tag appears once and is never quoted" {
  echo '{"version":1,"active":null,"models":[{"id":"p/m","agent":"shunt-bulk-reader-p-m"}]}' >"$SHUNT_MODELS_FILE"
  shunt_models_materialize_agent "p/m"
  local agent_file="$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md"
  grep -q "exactly once in the whole reply" "$agent_file"
  grep -q "never quoted" "$agent_file"
}

@test "the code-writer agent prompt shows the four tags and does not tell the model to omit the closing tag" {
  echo '{"version":1,"active":null,"models":[{"id":"p/m","agent":"shunt-bulk-reader-p-m"}]}' >"$SHUNT_MODELS_FILE"
  shunt_models_materialize_agent "p/m"
  local agent_file="$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md"
  # The four tags in protocol order, each on a line of its own.
  [ "$(grep -nE '^</?SHUNT-(NOTES|CODE)>$' "$agent_file" | head -4 | cut -d: -f2 | tr '\n' ' ')" = "<SHUNT-NOTES> </SHUNT-NOTES> <SHUNT-CODE> </SHUNT-CODE> " ]
  grep -qi "nothing but blank lines" "$agent_file"
  run grep -ci "no closing" "$agent_file"
  assert_output "0"
  run grep -c "<<<" "$agent_file"
  assert_output "0"
}

@test "the code-writer agent prompt carries a full example reply with notes, tags and code" {
  echo '{"version":1,"active":null,"models":[{"id":"p/m","agent":"shunt-bulk-reader-p-m"}]}' >"$SHUNT_MODELS_FILE"
  shunt_models_materialize_agent "p/m"
  local agent_file="$SHUNT_AGENTS_DIR/shunt-code-writer-p-m.md"
  local example
  example=$(sed -n '/^Example of a complete, correct reply/,/^End of example\.$/p' "$agent_file")
  [ -n "$example" ]
  # All four tags once each, in protocol order, then the code inside.
  [ "$(echo "$example" | grep -E '^</?SHUNT-(NOTES|CODE)>$' | tr '\n' ' ')" = "<SHUNT-NOTES> </SHUNT-NOTES> <SHUNT-CODE> </SHUNT-CODE> " ]
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

@test "shunt_models_validate accepts context_tokens and oversize_policy, or neither" {
  cat >"$SHUNT_MODELS_FILE" <<'JSON'
{"version":1,"active":null,"models":[
  {"id":"p/a","agent":"a1","context_tokens":128000,"oversize_policy":"map_reduce"},
  {"id":"p/b","agent":"a2","oversize_policy":"fail"},
  {"id":"p/c","agent":"a3"}
]}
JSON
  run shunt_models_validate
  assert_success
}

@test "shunt_models_validate rejects a context_tokens that is not a positive integer" {
  local bad
  for bad in 0 -5 1.5 '"100"' null true; do
    printf '{"version":1,"models":[{"id":"p/a","agent":"a1","context_tokens":%s}]}' "$bad" >"$SHUNT_MODELS_FILE"
    run shunt_models_validate
    assert_failure
    assert_output --partial "p/a"
    assert_output --partial "context_tokens"
  done
}

@test "shunt_models_validate rejects an unknown oversize_policy" {
  local bad
  for bad in '"chunk"' 1 null '["fail"]'; do
    printf '{"version":1,"models":[{"id":"p/a","agent":"a1","oversize_policy":%s}]}' "$bad" >"$SHUNT_MODELS_FILE"
    run shunt_models_validate
    assert_failure
    assert_output --partial "p/a"
    assert_output --partial "oversize_policy"
  done
}

@test "shunt_models_validate rejects two models that derive the same agent name" {
  echo '{"version":1,"active":null,"models":[{"id":"p/a.b"},{"id":"p/a-b"}]}' >"$SHUNT_MODELS_FILE"
  run shunt_models_validate
  assert_failure
  assert_output --partial "p/a.b"
  assert_output --partial "p/a-b"
  assert_output --partial "share the agent name"
}

@test "shunt_models_validate rejects an explicit agent name that another model derives" {
  echo '{"version":1,"active":null,"models":[{"id":"p/x","agent":"shunt-bulk-reader-p-y"},{"id":"p/y"}]}' >"$SHUNT_MODELS_FILE"
  run shunt_models_validate
  assert_failure
  assert_output --partial "share the agent name"
}

@test "shunt_models_validate rejects an agent name with unsafe characters" {
  echo '{"version":1,"active":null,"models":[{"id":"p/x","agent":"../evil"}]}' >"$SHUNT_MODELS_FILE"
  run shunt_models_validate
  assert_failure
  assert_output --partial "invalid agent name"
}

@test "shunt_models_validate rejects an id that derives an empty agent name" {
  echo '{"version":1,"active":null,"models":[{"id":"///"}]}' >"$SHUNT_MODELS_FILE"
  run shunt_models_validate
  assert_failure
  assert_output --partial "empty agent name"
}

@test "shunt_models_validate accepts the plain hand-written agent names" {
  echo '{"version":1,"active":null,"models":[{"id":"p/x","agent":"bulk-reader"},{"id":"p/y","agent":"a2"}]}' >"$SHUNT_MODELS_FILE"
  run shunt_models_validate
  assert_success
}

@test "shunt_models_validate rejects a shared derived code-writer name even when only one model has code-write" {
  echo '{"version":1,"active":null,"models":[{"id":"p/a.b","agent":"x1","roles":["bulk-read"]},{"id":"p/a-b","agent":"x2"}]}' >"$SHUNT_MODELS_FILE"
  run shunt_models_validate
  assert_failure
  assert_output --partial 'would share the agent name "shunt-code-writer-p-a-b"'
}

@test "shunt_models_validate rejects another model's agent that equals a roleless model's code-writer name" {
  echo '{"version":1,"active":null,"models":[{"id":"a","roles":["bulk-read"]},{"id":"b","agent":"shunt-code-writer-a"}]}' >"$SHUNT_MODELS_FILE"
  run shunt_models_validate
  assert_failure
  assert_output --partial 'would share the agent name "shunt-code-writer-a"'
}

@test "shunt_models_validate rejects a control character in a model id" {
  jq -n '{version:1,active:null,models:[{id:"p/a\nmodel: evil"}]}' >"$SHUNT_MODELS_FILE"
  run shunt_models_validate
  assert_failure
  assert_output --partial "control character"
}

@test "shunt_models_validate rejects a shared derived code-writer name when both have code-write" {
  echo '{"version":1,"active":null,"models":[{"id":"p/a.b","agent":"x1"},{"id":"p/a-b","agent":"x2"}]}' >"$SHUNT_MODELS_FILE"
  run shunt_models_validate
  assert_failure
  assert_output --partial "shunt-code-writer-p-a-b"
}

@test "shunt_models_available warns on stderr and returns 1 when the interpreter is missing" {
  echo '{"version":1,"active":null,"models":[]}' >"$SHUNT_MODELS_FILE"
  export SHUNT_PYTHON="$TEST_TMPDIR/no-such-python"
  run --separate-stderr shunt_models_available
  assert_failure 1
  assert_output ""
  [[ "$stderr" == "shunt: the Python interpreter is unusable (exit 127)"* ]]
  [ "$(printf '%s\n' "$stderr" | wc -l)" -eq 1 ]
}

@test "shunt_models_available stays silent for an invalid registry" {
  echo 'not json' >"$SHUNT_MODELS_FILE"
  run --separate-stderr shunt_models_available
  assert_failure 1
  assert_output ""
  assert_equal "$stderr" ""
}

@test "a raw SHUNT_MODELS_FILE is echoed unnormalised by validate" {
  export SHUNT_MODELS_FILE="./nope//x.json"
  run shunt_models_validate
  assert_failure
  assert_output "shunt: models registry not found at ./nope//x.json"
}
