load 'test_helper'
load 'http_fake'

# Adversarial reproductions for the http transport's chunk planning (UTF-8 safe
# split, measured per-file overhead, SHUNT_HTTP_MAX_CHUNKS) and its total
# deadline (SHUNT_TOTAL_TIMEOUT_SECONDS). Same fake provider (http_fake.bash) and
# fake clock as transport-http.bats. A test that reproduces a break asserts the correct
# behaviour, so it fails until the break is fixed.

bats_require_minimum_version 1.5.0

setup() {
  ORIG_PATH="$PATH"
  shunt_test_setup
  export SHUNT_PROVIDERS_FILE="$TEST_TMPDIR/providers.json"
  export TMPDIR="$TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR" "$TEST_TMPDIR/bin"
  export FAKE_CURL_BODY="$TEST_TMPDIR/curl-body"
  export FAKE_CURL_CODE=200 FAKE_CURL_EXIT=0
  export ACME_KEY="sk-test-key"
  unset SHUNT_TOTAL_TIMEOUT_SECONDS FAKE_CLOCK FAKE_CURL_ADVANCE FAKE_CURL_FAIL_AT
  PATH="$TEST_TMPDIR/bin:$PATH"
  source "$REPO_ROOT/scripts/lib/opencode.sh"
  unset SHUNT_TRANSPORT
  AGENT="shunt-bulk-reader-acme-m1"
  fake_http_start
  jq -n --arg u "$FAKE_BASE" '{version:1,providers:{acme:{transport:"http",base_url:$u,
    key:{type:"env",ref:"ACME_KEY"}}}}' >"$SHUNT_PROVIDERS_FILE"
  write_sized_registry 6000
  jq -n '{choices:[{message:{role:"assistant",content:"ok"},finish_reason:"stop"}],
    usage:{prompt_tokens:1,completion_tokens:1}}' >"$FAKE_CURL_BODY"
}

teardown() {
  stop_http_server
  PATH="$ORIG_PATH"
  shunt_test_teardown
}

# write_sized_registry <context_tokens> [second-model-too]
# 6000 tokens gives a 10800 byte budget.
write_sized_registry() {
  jq -n --argjson ct "$1" --arg two "${2:-}" '{version:1,models:(
    [{id:"acme/m1",agent:"shunt-bulk-reader-acme-m1",enabled:true,context_tokens:$ct}]
    + (if $two == "" then [] else
        [{id:"acme/m2",agent:"shunt-bulk-reader-acme-m2",enabled:true,context_tokens:$ct}] end))}' \
    >"$SHUNT_MODELS_FILE"
}

# sent_text_bytes <n>: decoded system + user bytes of request n (what the guard measures).
sent_text_bytes() { jq -j '.messages[0].content + .messages[1].content' "$FAKE_CURL_SENT.$1" | wc -c; }

# sent_chunk <n> <outfile>: the file content of chunk request n, between the
# "--- file: ... ---" header line and the "--- end of file ---" trailer.
sent_chunk() {
  jq -j '.messages[1].content' "$FAKE_CURL_SENT.$1" \
    | perl -0777 -ne 'print $1 if /\n--- file: .*? ---\n(.*)\n--- end of file ---\n\z/s' >"$2"
}

use_fake_clock() {
  export FAKE_CLOCK="$TEST_TMPDIR/clock" FAKE_CURL_ADVANCE="$1"
  echo 0 >"$FAKE_CLOCK"
}

lines_file() {
  awk -v n="$2" 'BEGIN { pad = sprintf("%93s", ""); gsub(/ /, "x", pad)
    for (i = 1; i <= n; i++) printf "L%04d %s\n", i, pad }' >"$1"
}

# repeat <count> <string>: prints string count times.
repeat() {
  local i out=""
  for (( i = 0; i < $1; i++ )); do out+="$2"; done
  printf '%s' "$out"
}

# The planner is Python now (chunk_plan.py), so these helpers run it through chunk_py.
# PLAN_PY plans one file for the agent of this test, cuts every chunk with write_chunk,
# stitches them back (dropping the line overlap of neighbouring line chunks) and writes
# "start end offset length" per chunk to the plan file and chunk i to OUT.chunk.i.
PLAN_PY='
import os
from shunt import chunk_plan as c, chunking, transport_http as t
from shunt.transport_reply import Abort
agent, f, out, plan_file = sys.argv[1:5]
setup = t._setup(agent, os.environ)
try:
    plan = c.plan_all("q", [f], model_id=setup.model_id, system_len=len(setup.system),
                      budget_bytes=chunking.budget_bytes(setup.context_tokens), max_chunks=chunking.max_chunks(os.environ))
except Abort as stop:
    sys.exit(stop.status)
import io
nxt = 1
with open(out, "wb") as joined, open(plan_file, "w") as rows:
    for i, ch in enumerate(plan):
        data = c.write_chunk(ch)
        open(f"{out}.chunk.{i}", "wb").write(data)
        rows.write(f"{ch.start} {ch.end} {ch.offset} {ch.length}\n")
        if ch.offset >= 0:
            joined.write(data)
            nxt = ch.start + 1
        else:
            joined.write(b"".join(io.BytesIO(data).readlines()[nxt - ch.start:]))
            nxt = ch.end + 1
'

# room_for <question> <file-label> <size>: content bytes the planner allows per chunk.
room_for() {
  SHUNT_PROMPTS_DIR="$SHUNT_PROMPTS_DIR" chunk_py '
import os
from shunt import chunk_plan as c, chunking, transport_http as t
setup = t._setup(sys.argv[1], os.environ)
print(chunking.budget_bytes(setup.context_tokens) - c.overhead(sys.argv[2], sys.argv[3], sys.argv[4], len(setup.system)))' \
    "$AGENT" "$1" "$2" "$3"
}

# rebuild_from_plan <file> <outfile>: plans <file> alone and stitches the chunks back.
# Leaves the chunk count in PLAN_N and the plan in PLAN_START/END/OFF/LEN.
rebuild_from_plan() {
  local s e o l
  SHUNT_PROMPTS_DIR="$SHUNT_PROMPTS_DIR" chunk_py "$PLAN_PY" "$AGENT" "$1" "$2" "$TEST_TMPDIR/plan" || return 1
  PLAN_N=0 PLAN_START=() PLAN_END=() PLAN_OFF=() PLAN_LEN=()
  while read -r s e o l; do
    PLAN_START+=("$s") PLAN_END+=("$e") PLAN_OFF+=("$o") PLAN_LEN+=("$l")
    PLAN_N=$(( PLAN_N + 1 ))
  done <"$TEST_TMPDIR/plan"
}

# ---- byte fidelity -----------------------------------------------------------

@test "split: an overlong line of 2, 3 and 4 byte characters at every cut offset is rebuilt byte for byte" {
  local ch pre f
  for ch in $'\xc3\xa9' $'\xe2\x82\xac' $'\xf0\x9f\x98\x80'; do
    for pre in "" a ab abc; do
      f="$TEST_TMPDIR/u.txt"
      { printf '%s' "$pre"; repeat 9000 "$ch"; printf '\n'; } >"$f"
      rebuild_from_plan "$f" "$TEST_TMPDIR/re.txt"
      [ "$PLAN_N" -gt 1 ]
      cmp "$f" "$TEST_TMPDIR/re.txt"
    done
  done
}

@test "split: chunk requests of an overlong UTF-8 line carry the exact bytes and no replacement character" {
  local f="$TEST_TMPDIR/u.txt" n i
  { printf 'ab'; repeat 9000 $'\xf0\x9f\x98\x80'; } >"$f"
  run --separate-stderr shunt_transport_invoke "$AGENT" "q" "$f"
  assert_success
  n=$(request_count)
  : >"$TEST_TMPDIR/all"
  for (( i = 1; i < n; i++ )); do
    sent_chunk "$i" "$TEST_TMPDIR/c"
    cat "$TEST_TMPDIR/c" >>"$TEST_TMPDIR/all"
    [ "$(grep -c $'\xef\xbf\xbd' "$TEST_TMPDIR/c")" -eq 0 ]
    [ "$(sent_text_bytes "$i")" -le 10800 ]
  done
  cmp "$f" "$TEST_TMPDIR/all"
}

@test "split: invalid UTF-8 (lone continuation bytes, truncated and overlong sequences) loses no bytes" {
  local f="$TEST_TMPDIR/bad.bin"
  { repeat 3000 $'\x80\x80\x80\x80\x80'; repeat 2000 $'\xe2\x82'; repeat 2000 $'\xc0\xaf'; repeat 2000 $'\xf0\x9f'; } >"$f"
  rebuild_from_plan "$f" "$TEST_TMPDIR/re.txt"
  [ "$PLAN_N" -gt 1 ]
  cmp "$f" "$TEST_TMPDIR/re.txt"
}

@test "split: CRLF lines, NUL bytes and a final line without newline survive chunking" {
  local f="$TEST_TMPDIR/mix.bin" i
  for (( i = 0; i < 400; i++ )); do printf 'row %04d\0with nul and crlf %s\r\n' "$i" "$(repeat 40 y)"; done >"$f"
  { repeat 30000 z; } >>"$f"
  rebuild_from_plan "$f" "$TEST_TMPDIR/re.txt"
  [ "$PLAN_N" -gt 2 ]
  cmp "$f" "$TEST_TMPDIR/re.txt"
}

@test "split: a file of only newlines and a file with no newline at all are rebuilt exactly" {
  head -c 50000 /dev/zero | tr '\0' '\n' >"$TEST_TMPDIR/nl.txt"
  rebuild_from_plan "$TEST_TMPDIR/nl.txt" "$TEST_TMPDIR/re1"
  cmp "$TEST_TMPDIR/nl.txt" "$TEST_TMPDIR/re1"
  head -c 50000 /dev/zero | tr '\0' 'k' >"$TEST_TMPDIR/one.txt"
  rebuild_from_plan "$TEST_TMPDIR/one.txt" "$TEST_TMPDIR/re2"
  cmp "$TEST_TMPDIR/one.txt" "$TEST_TMPDIR/re2"
}

# ---- budget boundaries ---------------------------------------------------------

@test "budget: a line exactly at the room is one line chunk, one under too" {
  local f="$TEST_TMPDIR/b.txt" room
  lines_file "$f" 200
  room=$(room_for q "$f" 99999)
  { repeat $(( room - 1 )) a; printf '\n'; } >"$f"
  lines_file "$TEST_TMPDIR/tail" 200
  cat "$TEST_TMPDIR/tail" >>"$f"
  rebuild_from_plan "$f" "$TEST_TMPDIR/re"
  [ "${PLAN_OFF[0]}" -eq -1 ]
  cmp "$f" "$TEST_TMPDIR/re"
  { repeat $(( room - 2 )) a; printf '\n'; cat "$TEST_TMPDIR/tail"; } >"$f"
  rebuild_from_plan "$f" "$TEST_TMPDIR/re"
  [ "${PLAN_OFF[0]}" -eq -1 ]
}

@test "budget: a line one byte over the room does not cost a whole request for its lone newline" {
  local f="$TEST_TMPDIR/b.txt" room i
  lines_file "$f" 200
  room=$(room_for q "$TEST_TMPDIR/b2.txt" 99999)
  { repeat "$room" a; printf '\n'; cat "$TEST_TMPDIR/b.txt"; } >"$TEST_TMPDIR/b2.txt"
  rebuild_from_plan "$TEST_TMPDIR/b2.txt" "$TEST_TMPDIR/re"
  cmp "$TEST_TMPDIR/b2.txt" "$TEST_TMPDIR/re"
  for (( i = 0; i < PLAN_N; i++ )); do
    # A piece holding nothing but the line's newline is an empty request.
    if [ "${PLAN_OFF[i]}" -ge 0 ] && [ "${PLAN_LEN[i]}" -eq 1 ]; then
      echo "chunk $i is the lone newline at byte $(( PLAN_OFF[i] + 1 )) of line ${PLAN_START[i]}" >&2
      false
    fi
  done
}

@test "budget: a long line ending in a run of whitespace sends no whitespace-only piece" {
  local f="$TEST_TMPDIR/w.txt" room i
  room=$(room_for q "$f" 99999)
  { repeat $(( room - 3 )) a; printf '      \r\n'; lines_file /dev/stdout 50; } >"$f"
  rebuild_from_plan "$f" "$TEST_TMPDIR/re"
  cmp "$f" "$TEST_TMPDIR/re"
  for (( i = 0; i < PLAN_N; i++ )); do
    [ "${PLAN_OFF[i]}" -ge 0 ] || continue
    LC_ALL=C grep -q '[^[:space:]]' "$TEST_TMPDIR/re.chunk.$i"
  done
}

@test "budget: exactly SHUNT_HTTP_MAX_CHUNKS chunks is sent, one more is refused with nothing sent" {
  local f="$TEST_TMPDIR/m.txt" room
  room=$(room_for q "$f" 99999)
  SHUNT_HTTP_MAX_CHUNKS=3
  repeat $(( 3 * room )) a >"$f"
  run --separate-stderr shunt_transport_invoke "$AGENT" "q" "$f"
  assert_success
  [ "$(request_count)" -eq 4 ]
  : >"$HTTP_LOG"
  repeat $(( 3 * room + 1 )) a >"$f"
  run --separate-stderr shunt_transport_invoke "$AGENT" "q" "$f"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]
  [[ "$stderr" == *"more chunks than the limit of 3"* ]]
  [ "$(request_count)" -eq 0 ]
}

@test "budget: a question that alone exceeds the budget fails fast with nothing sent" {
  local f="$TEST_TMPDIR/s.txt"
  printf 'x\n' >"$f"
  run --separate-stderr timeout 20 bash -c '
    source "$1/scripts/lib/opencode.sh"; unset SHUNT_TRANSPORT
    shunt_transport_invoke "$2" "$(head -c 20000 /dev/zero | tr "\0" q)" "$3"' _ "$REPO_ROOT" "$AGENT" "$f"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]
  [[ "$stderr" == *"leave no room for file content"* ]]
  [ "$(request_count)" -eq 0 ]
}

@test "budget: empty question, empty file and 1-byte file next to a big file all chunk within budget" {
  local n i
  : >"$TEST_TMPDIR/empty.txt"
  printf 'z' >"$TEST_TMPDIR/one.txt"
  lines_file "$TEST_TMPDIR/big.txt" 300
  run --separate-stderr shunt_transport_invoke "$AGENT" "" "$TEST_TMPDIR/empty.txt" "$TEST_TMPDIR/one.txt" "$TEST_TMPDIR/big.txt"
  assert_success
  n=$(request_count)
  [ "$n" -gt 3 ]
  for (( i = 1; i <= n; i++ )); do [ "$(sent_text_bytes "$i")" -le 10800 ]; done
}

@test "budget: hostile file names (spaces, newline, quotes, unicode, leading dash) keep every request in budget" {
  local d="$TEST_TMPDIR/dir" f n i
  mkdir -p "$d"
  f="$d/-n a \"q\" 'r'"$'\n'"ünï€😀 $(repeat 100 ж).txt"
  lines_file "$f" 300
  run --separate-stderr shunt_transport_invoke "$AGENT" "q" "$f"
  assert_success
  n=$(request_count)
  [ "$n" -gt 2 ]
  for (( i = 1; i <= n; i++ )); do [ "$(sent_text_bytes "$i")" -le 10800 ]; done
  jq -r '.messages[1].content' "$FAKE_CURL_SENT.1" | grep -qF "ünï€😀"
}

# ---- planning cost -------------------------------------------------------------

@test "dos: planning a 40 MB file of newlines is refused within 15 seconds" {
  head -c 40000000 /dev/zero | tr '\0' '\n' >"$TEST_TMPDIR/huge.txt"
  local t0=$SECONDS st=0
  SHUNT_PROMPTS_DIR="$SHUNT_PROMPTS_DIR" chunk_py "$PLAN_PY" "$AGENT" "$TEST_TMPDIR/huge.txt" "$TEST_TMPDIR/re" "$TEST_TMPDIR/plan" 2>/dev/null || st=$?
  [ "$st" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]
  [ $(( SECONDS - t0 )) -le 15 ]
}

@test "dos: a 1 MB single line within the chunk cap spawns a bounded number of processes in time" {
  SHUNT_HTTP_MAX_CHUNKS=100
  head -c 1000000 /dev/zero | tr '\0' 'w' >"$TEST_TMPDIR/line.txt"
  local t0=$SECONDS
  rebuild_from_plan "$TEST_TMPDIR/line.txt" "$TEST_TMPDIR/re"
  [ "$PLAN_N" -le 100 ]
  [ $(( SECONDS - t0 )) -le 15 ]
}

# ---- total deadline ------------------------------------------------------------

@test "deadline: a 10-digit SHUNT_TIMEOUT_SECONDS keeps the default total at three times it" {
  lines_file "$TEST_TMPDIR/big.txt" 300
  use_fake_clock 1000
  export SHUNT_TIMEOUT_SECONDS=1000000000
  run --separate-stderr shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  assert_success
  [ "$(request_count)" -eq 5 ]
}

@test "deadline: SHUNT_TIMEOUT_SECONDS=0 (no per-request limit) does not shrink the default total to 900s" {
  lines_file "$TEST_TMPDIR/big.txt" 300
  use_fake_clock 1000
  export SHUNT_TIMEOUT_SECONDS=0
  run --separate-stderr shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  assert_success
  [ "$(request_count)" -eq 5 ]
}

@test "deadline: an explicit total caps max-time when SHUNT_TIMEOUT_SECONDS is 0" {
  export SHUNT_TIMEOUT_SECONDS=0 SHUNT_TOTAL_TIMEOUT_SECONDS=10
  run --separate-stderr shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(max_time_of 1)" = 10 ]
}

@test "deadline: an explicit total caps max-time when SHUNT_TIMEOUT_SECONDS has more than 9 digits" {
  export SHUNT_TIMEOUT_SECONDS=99999999999 SHUNT_TOTAL_TIMEOUT_SECONDS=10
  run --separate-stderr shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(max_time_of 1)" = 10 ]
}

@test "deadline: a fractional SHUNT_TIMEOUT_SECONDS above the time left is capped to the time left" {
  export SHUNT_TIMEOUT_SECONDS=2.5 SHUNT_TOTAL_TIMEOUT_SECONDS=2
  run --separate-stderr shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(max_time_of 1)" = 2 ]
}

@test "deadline: a total of 1 second still sends one request capped at 1" {
  export SHUNT_TOTAL_TIMEOUT_SECONDS=1
  run --separate-stderr shunt_transport_invoke "$AGENT" "q"
  assert_success
  [ "$(max_time_of 1)" = 1 ]
}

@test "deadline: a total of 1 second with the real clock never fails before sending (30 tries)" {
  local i fails=0
  export SHUNT_TOTAL_TIMEOUT_SECONDS=1
  for (( i = 0; i < 30; i++ )); do
    shunt_transport_invoke "$AGENT" "q" >/dev/null 2>&1 || fails=$(( fails + 1 ))
  done
  echo "failed $fails of 30, requests sent $(request_count)" >&2
  [ "$fails" -eq 0 ]
}

@test "deadline: reached during the merge returns DEADLINE after all chunks" {
  lines_file "$TEST_TMPDIR/big.txt" 300
  use_fake_clock 10
  export SHUNT_TOTAL_TIMEOUT_SECONDS=40
  run --separate-stderr shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  [ "$status" -eq "$SHUNT_TRY_INVOKE_DEADLINE" ]
  [ "$(request_count)" -eq 4 ]
  [[ "$stderr" == *"4 of 4 chunks finished"* ]]
}

@test "deadline: the DEADLINE status records a breaker failure and fails over to the next model" {
  write_sized_registry 6000 two
  export FAKE_CURL_EXIT=28 SHUNT_TOTAL_TIMEOUT_SECONDS=7
  run --separate-stderr shunt_invoke_with_failover "q"
  assert_failure
  [[ "$stderr" == *"acme/m1 failed: total deadline reached"* ]]
  [[ "$stderr" == *"acme/m2 failed: total deadline reached"* ]]
  [ "$(jq -r '."acme/m1".failures // .models."acme/m1".failures // empty' "$SHUNT_BREAKER_STATE_FILE")" = 1 ]
}

@test "deadline: each failover candidate gets its own total deadline" {
  write_sized_registry 6000 two
  lines_file "$TEST_TMPDIR/big.txt" 300
  use_fake_clock 10
  export SHUNT_TOTAL_TIMEOUT_SECONDS=15
  run --separate-stderr shunt_invoke_with_failover "q" "$TEST_TMPDIR/big.txt"
  assert_failure
  # m1 sends at 0 and 10, stops at 20. m2 starts a fresh 15s at 20.
  [ "$(request_count)" -eq 4 ]
  [ "$(max_time_of 1)" = 15 ]
  [ "$(max_time_of 2)" = 5 ]
  [ "$(max_time_of 3)" = 15 ]
  [ "$(max_time_of 4)" = 5 ]
  [[ "$stderr" == *"model acme/m1: total deadline of 15s"* ]]
  [[ "$stderr" == *"model acme/m2: total deadline of 15s"* ]]
}

# ---- hostile server bodies in the map/reduce usage totals ----------------------

@test "hostile: a usage token count of x[\$(cmd)] in a chunk reply runs no command (arithmetic injection)" {
  lines_file "$TEST_TMPDIR/big.txt" 300
  export SHUNT_PWNED="$TEST_TMPDIR/pwned"
  jq -n '{choices:[{message:{role:"assistant",content:"ok"},finish_reason:"stop"}],
    usage:{prompt_tokens:"x[$(date>$SHUNT_PWNED)]",completion_tokens:1}}' >"$FAKE_CURL_BODY"
  run --separate-stderr shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  [ ! -e "$SHUNT_PWNED" ]
}

@test "hostile: a fractional usage token count in chunk replies does not break the chunked call" {
  lines_file "$TEST_TMPDIR/big.txt" 300
  jq -n '{choices:[{message:{role:"assistant",content:"ok"},finish_reason:"stop"}],
    usage:{prompt_tokens:1.5,completion_tokens:1}}' >"$FAKE_CURL_BODY"
  run --separate-stderr shunt_transport_invoke "$AGENT" "q" "$TEST_TMPDIR/big.txt"
  assert_success
  [ "$(jq -r '.text' "$output")" = "ok" ]
}

# write_chunk_py <file> <start> <end> <offset> <length> <outfile>: cuts one planned chunk with
# chunk_plan.write_chunk, writes it to <outfile>, exits with the Abort status.
write_chunk_py() {
  chunk_py '
from shunt import chunk_plan as c
from shunt.transport_reply import Abort
f, start, end, off, length, out = sys.argv[1:7]
try:
    data = c.write_chunk(c.Chunk(f, int(start), int(end), int(off), int(length), 1, 1))
except Abort as stop:
    sys.exit(stop.status)
open(out, "wb").write(data)' "$@"
}

@test "write_chunk: a source that cannot be read fails instead of writing an empty chunk" {
  run ! write_chunk_py "$TEST_TMPDIR/missing.txt" 1 1 0 5 "$TEST_TMPDIR/c"
  run ! write_chunk_py "$TEST_TMPDIR/missing.txt" 1 1 -1 0 "$TEST_TMPDIR/c"
}

@test "write_chunk: a byte slice shorter than the line still succeeds when head closes the pipe early" {
  local f="$TEST_TMPDIR/long.txt"
  { repeat 200000 a; echo; } >"$f"
  write_chunk_py "$f" 1 1 0 10 "$TEST_TMPDIR/c"
  [ "$(wc -c <"$TEST_TMPDIR/c" | tr -d ' ')" = 10 ]
}

@test "write_chunk: a small slice of a huge line succeeds when SIGPIPE is ignored" {
  local f="$TEST_TMPDIR/long.txt"
  { repeat 300000 a; echo; } >"$f"
  trap '' PIPE
  write_chunk_py "$f" 1 1 0 10 "$TEST_TMPDIR/c2"
  trap - PIPE
  [ "$(wc -c <"$TEST_TMPDIR/c2" | tr -d ' ')" = 10 ]
}

@test "write_chunk: an unreadable source is rejected up front with a clear error" {
  run --separate-stderr write_chunk_py "$TEST_TMPDIR/missing.txt" 1 1 0 5 "$TEST_TMPDIR/c"
  assert_failure
  [[ "$stderr" == *"cannot read"* ]]
}

@test "write_chunk: a directory as the source is rejected" {
  mkdir "$TEST_TMPDIR/d"
  run --separate-stderr write_chunk_py "$TEST_TMPDIR/d" 1 1 2 100 "$TEST_TMPDIR/c"
  assert_failure
  [[ "$stderr" == *"cannot read"* ]]
}

@test "write_chunk: a file truncated after planning fails instead of writing a short chunk" {
  local f="$TEST_TMPDIR/short.txt"
  printf 'abcdef\n' >"$f"
  run --separate-stderr write_chunk_py "$f" 1 1 2 100 "$TEST_TMPDIR/c"
  assert_failure
  [[ "$stderr" == *"expected 100 bytes"* ]]
}

@test "plan_long_line fails when the line cannot be read" {
  run chunk_py '
from shunt import chunk_plan as c
from shunt.transport_reply import Abort
try:
    c.plan_file(sys.argv[1], 100, 10)
except (Abort, OSError):
    sys.exit(1)' "$TEST_TMPDIR/missing.txt"
  assert_failure
}
