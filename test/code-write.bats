load 'test_helper'

# Launcher smoke tests for scripts/code-write with a stubbed `opencode`. The
# behaviour of the call itself (argument and path refusals, the failover loop,
# the response checks, publishing, the debug log) is tested in pytest, see
# test/py/test_code_write.py and test/py/test_cw_*.py. Here only what needs the
# real shell launcher: exec of the Python core, exit statuses, signals, and the
# hand-off to usage-report. The stub answers per agent from files under
# $STUB_DIR, records every call and never touches the network.

CODE_WRITE="$REPO_ROOT/scripts/code-write"
NOTES_OPEN='<SHUNT-NOTES>'
NOTES_CLOSE='</SHUNT-NOTES>'
CODE_OPEN='<SHUNT-CODE>'
CODE_CLOSE='</SHUNT-CODE>'

setup() {
  shunt_test_setup
  unset SHUNT_DEBUG_LOG
  export SHUNT_DEBUG_LOG_PATH="$TEST_TMPDIR/usage.jsonl"

  STUB_DIR="$TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR" "$TEST_TMPDIR/bin"
  export STUB_DIR
  write_stub_opencode
  export SHUNT_OPENCODE_BIN="$TEST_TMPDIR/bin/opencode"

  PROJ="$TEST_TMPDIR/proj"
  mkdir -p "$PROJ/src"
  PROJ="$(cd -P "$PROJ" && pwd -P)"
  # The test image has no git, so pin the project root the way a hook would.
  export CLAUDE_PROJECT_DIR="$PROJ"
  printf 'func Add(a, b int) int { return a + b }\n' >"$PROJ/src/add.go"
  printf 'func TestSub(t *testing.T) {}\n' >"$PROJ/src/sub_test.go"
  printf 'Use table-driven tests.\n' >"$PROJ/RULES.txt"
  cd "$PROJ"

  shunt_write_provider "p"
}

teardown() {
  cd /
  shunt_test_teardown
}

# The stub: `opencode run --agent A "MESSAGE" -f F ... --format json`. It
# records the agent, the message and the attachments of call N, then replays
# resp.<agent> (or resp.default) wrapped in a JSONL transcript. finish.<agent>
# sets the step_finish reason (default stop), nofinish.<agent> drops the
# step_finish event, exit.<agent> makes the call fail, sleep.<agent> delays,
# create holds a path the stub creates while "working" (a lost-race stand-in).
write_stub_opencode() {
  cat >"$TEST_TMPDIR/bin/opencode" <<'FAKE'
#!/bin/bash
shift
agent="" msg="" files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) agent="$2"; shift 2 ;;
    -f) files+=("$2"); shift 2 ;;
    --format) shift 2 ;;
    *) msg="$1"; shift ;;
  esac
done
n=$(( $(cat "$STUB_DIR/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$STUB_DIR/count"
echo "$agent" >>"$STUB_DIR/agents"
printf '%s' "$msg" >"$STUB_DIR/prompt.$n"
printf '%s\n' "${files[@]}" >"$STUB_DIR/files.$n"
[ -f "$STUB_DIR/sleep.$agent" ] && sleep "$(cat "$STUB_DIR/sleep.$agent")"
[ -f "$STUB_DIR/create" ] && echo raced >"$(cat "$STUB_DIR/create")"
[ -f "$STUB_DIR/exit.$agent" ] && exit "$(cat "$STUB_DIR/exit.$agent")"
resp="$STUB_DIR/resp.$agent"
[ -f "$resp" ] || resp="$STUB_DIR/resp.default"
finish=stop
[ -f "$STUB_DIR/finish.$agent" ] && finish="$(cat "$STUB_DIR/finish.$agent")"
jq -cn --rawfile t "$resp" '{type:"text",part:{text:$t}}'
[ -f "$STUB_DIR/nofinish.$agent" ] \
  || jq -cn --arg r "$finish" '{type:"step_finish",part:{reason:$r,cost:0.5,tokens:{input:100,output:50}}}'
FAKE
  chmod +x "$TEST_TMPDIR/bin/opencode"
}

# add_models <id>...: registers the models (both roles), first one active.
add_models() {
  local id
  for id in "$@"; do
    "$REPO_ROOT/scripts/shunt-models" add "$id" >/dev/null
  done
  "$REPO_ROOT/scripts/shunt-models" activate "$1" >/dev/null
}

# agent_of <id>: the code-writer agent name of a model.
agent_of() {
  echo "shunt-code-writer-$(echo "$1" | tr '[:upper:]/' '[:lower:]-')"
}

# response <notes> <code>: a well-formed model response on stdout.
response() {
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$NOTES_OPEN" "$1" "$NOTES_CLOSE" "$CODE_OPEN" "$2" "$CODE_CLOSE"
}

# set_resp <id|default> <text>: what the stub answers for that model.
set_resp() {
  local key="default"
  [ "$1" = "default" ] || key="$(agent_of "$1")"
  printf '%s' "$2" >"$STUB_DIR/resp.$key"
}

stub_calls() {
  cat "$STUB_DIR/count" 2>/dev/null || echo 0
}

stub_agents() {
  { tr '\n' ',' <"$STUB_DIR/agents" 2>/dev/null || true; } | sed 's/,$//'
}

# breaker_failures <id>: the code-write failure counter, kept under "<id>#code-write".
breaker_failures() {
  jq -r --arg id "$1#code-write" '.models[$id].failures // 0' "$SHUNT_BREAKER_STATE_FILE"
}

# assert_refused_early: the call made no model call and left the breaker alone.
assert_refused_early() {
  assert_failure
  [ "$(stub_calls)" = "0" ]
  [ ! -f "$SHUNT_BREAKER_STATE_FILE" ]
}

# --- launcher smoke tests ----------------------------------------------------

@test "writes the generated code to the target and reports path and notes" {
  add_models p/one
  set_resp default "$(response "skipped the parallel case" "package src

func TestAdd(t *testing.T) {}")"
  run "$CODE_WRITE" --kind test --spec "test Add" --reference src/sub_test.go \
    --source src/add.go --target src/add_test.go
  assert_success
  assert_output --partial "$PROJ/src/add_test.go"
  assert_output --partial "skipped the parallel case"
  assert_output --partial "untrusted"
  assert_output --partial "code-write usage: input=100 output=50 cost=0.5"
  [ "$(head -n 1 src/add_test.go)" = "package src" ]
  [ "$(stub_agents)" = "$(agent_of p/one)" ]
  [ "$(breaker_failures p/one)" = "0" ]
}

@test "answers through the http transport from a fake provider without leaking the key" {
  export SHUNT_PROMPTS_DIR="$REPO_ROOT/prompts"
  export SHUNT_PROVIDERS_FILE="$TEST_TMPDIR/providers.json"
  export ACME_KEY="sk-smoke-secret-value-123"
  mkdir -p "$TEST_TMPDIR/routes"
  start_http_server "$TEST_TMPDIR/routes"
  jq -n --arg t "$(response none "x := 1")" '{choices:[{message:{content:$t},finish_reason:"stop"}],
    usage:{prompt_tokens:12,completion_tokens:5}}' >"$TEST_TMPDIR/routes/v1_chat_completions"
  jq -n --arg u "http://127.0.0.1:$HTTP_PORT/v1" \
    '{version:1,providers:{acme:{transport:"http",base_url:$u,key:{type:"env",ref:"ACME_KEY"}}}}' >"$SHUNT_PROVIDERS_FILE"
  jq -n '{version:1,models:[{id:"acme/m1",enabled:true}]}' >"$SHUNT_MODELS_FILE"
  run "$CODE_WRITE" --kind generic --spec s --reference src/add.go --target out.go
  stop_http_server
  assert_success
  assert_output --partial "created $PROJ/out.go"
  [ "$(cat out.go)" = "x := 1" ]
  [ "$(wc -l <"$HTTP_LOG" | tr -d ' ')" = "1" ]
  refute_output --partial "$ACME_KEY"
  [ "$(jq -r '.headers.authorization' "$HTTP_LOG")" = "Bearer $ACME_KEY" ]
  [ "$(jq -r '.body' "$HTTP_LOG" | grep -c "$ACME_KEY")" = "0" ]
}

@test "a usage error exits 1 before any model call and leaves the breaker alone" {
  add_models p/one
  run "$CODE_WRITE" --spec s --reference src/add.go --target out.go
  assert_failure 1
  assert_output --partial "--kind is required"
  [ "$(stub_calls)" = "0" ]
  [ ! -f "$SHUNT_BREAKER_STATE_FILE" ]
}

@test "refuses a target that escapes the project root before any model call" {
  add_models p/one
  run "$CODE_WRITE" --kind generic --spec s --reference src/add.go --target ../escape.go
  assert_failure 1
  assert_output --partial "refusing target"
  [ "$(stub_calls)" = "0" ]
  [ ! -e "$TEST_TMPDIR/escape.go" ]
}

@test "an unusable response fails over to the next model and counts against the breaker" {
  add_models p/one p/two
  set_resp p/one "just some chatter"
  set_resp p/two "$(response ok "x := 2")"
  run "$CODE_WRITE" --kind generic --spec s --reference src/add.go --target src/out.go
  assert_success
  [ "$(stub_agents)" = "$(agent_of p/one),$(agent_of p/two)" ]
  [ "$(breaker_failures p/one)" = "1" ]
  [ "$(breaker_failures p/two)" = "0" ]
  [ "$(cat src/out.go)" = "x := 2" ]
}

@test "a deliberate refusal exits 3 and writes nothing" {
  add_models p/one
  set_resp default "$(response "the expected behavior is not clear from the source" "")"
  run "$CODE_WRITE" --kind generic --spec s --reference src/add.go --target brand/out.go
  [ "$status" -eq 3 ]
  assert_output --partial "the expected behavior is not clear from the source"
  assert_output --partial "nothing was written"
  [ ! -e brand ]
  [ "$(breaker_failures p/one)" = "0" ]
}

@test "a TERM during the model call exits 143 without writing and cleans its temp files" {
  add_models p/one
  set_resp default "$(response none "x := 1")"
  echo 2 >"$STUB_DIR/sleep.$(agent_of p/one)"
  bg_detached "$CODE_WRITE" --kind generic --spec s --reference src/add.go --target out.go
  local pid=$BG_PID
  sleep 0.7
  kill -TERM "$pid"
  local rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  [ ! -e out.go ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "usage-report separates code-write calls from bulk-read calls" {
  export SHUNT_DEBUG_LOG=1
  add_models p/one
  set_resp default "$(response none "x := 1")"
  "$CODE_WRITE" --kind generic --spec s --reference src/add.go --target out.go >/dev/null
  # A bulk-read style entry written before the tool field existed.
  echo '{"timestamp":"t","agent":"p/one","files":[],"question_chars":1,"delegate_input_tokens":10,"delegate_output_tokens":5,"delegate_cost_usd":0.25,"avoided_tokens_estimate":400}' \
    >>"$SHUNT_DEBUG_LOG_PATH"

  run bash -c '"$0" 2>/dev/null' "$REPO_ROOT/scripts/usage-report"
  assert_success
  [ "$(echo "$output" | jq -r '.calls')" = "2" ]
  [ "$(echo "$output" | jq -r '.by_tool[] | select(.tool == "code-write") | .calls')" = "1" ]
  [ "$(echo "$output" | jq -r '.by_tool[] | select(.tool == "bulk-read") | .calls')" = "1" ]
  [ "$(echo "$output" | jq -r '.by_tool[] | select(.tool == "code-write") | .generated_bytes')" = "7" ]
}
