# A fake provider for the http transport tests, on top of the local scripted server
# (test/py/httpserver.py). It replaces the fake curl these tests used to put on PATH.
# Load it after test_helper and call fake_http_start in setup (after
# shunt_test_setup and after sourcing scripts/lib/py.sh), stop_http_server in
# teardown. The old knobs keep working, they are read before every request:
#   FAKE_CURL_BODY       file with the body of the answer
#   FAKE_CURL_CODE       HTTP status of the answer (default 200)
#   FAKE_CURL_FAIL_AT / FAKE_CURL_FAIL_CODE   request number N gets this status instead
#   FAKE_CURL_EXIT=28    the request times out (the server stalls, the time limit is 0.3s)
#   FAKE_CURL_EXIT=7|52  the server drops the connection without an answer
#   FAKE_CLOCK, FAKE_CURL_ADVANCE   the clock file moves by ADVANCE after each request
# Artifacts: FAKE_CURL_SENT.<n> (body of request n, FAKE_CURL_SENT the last one),
# HTTP_LOG (one JSON line per request: path, lower-cased headers, body),
# request_count, and max_time_of <n> (the request's max time as the wrapper chose it).

# fake_http_start: starts the server, sets FAKE_BASE (the provider's base_url) and
# points the Python bridge at test/fake_shunt_main.py, which scripts the route of each
# request from the knobs, records each request's time limit and moves the fake clock
# (production code has no test hooks). The knobs may be unexported shell variables
# in a test, the wrapper of shunt_py exports them for the Python child.
fake_http_start() {
  FAKE_ROUTES="$TEST_TMPDIR/routes"
  FAKE_MAXTIMES="$TEST_TMPDIR/max-times"
  export FAKE_CURL_SENT="$TEST_TMPDIR/curl-sent"
  mkdir -p "$FAKE_ROUTES"
  start_http_server "$FAKE_ROUTES" --sent "$FAKE_CURL_SENT"
  FAKE_BASE="http://127.0.0.1:$HTTP_PORT/v1"
  export FAKE_HTTP_ROUTES="$FAKE_ROUTES" FAKE_HTTP_MAXTIMES="$FAKE_MAXTIMES" FAKE_HTTP_LOG="$HTTP_LOG"
  export SHUNT_PY_MAIN="$REPO_ROOT/test/fake_shunt_main.py"
  eval "$(declare -f shunt_py | sed '1s/^shunt_py/_fake_orig_call/')"
  shunt_py() { _fake_export_knobs; _fake_orig_call "$@"; }
}

_fake_export_knobs() {
  local v
  for v in FAKE_CLOCK FAKE_CURL_ADVANCE FAKE_CURL_FAIL_AT FAKE_CURL_FAIL_CODE FAKE_CURL_EXIT FAKE_CURL_CODE FAKE_CURL_BODY; do
    [ -z "${!v+x}" ] || export "$v"
  done
}

# fake_http_sync: writes the route of the next request from the FAKE_CURL_* knobs.
fake_http_sync() {
  local route="$FAKE_ROUTES/v1_chat_completions" code="${FAKE_CURL_CODE:-200}"
  [ "$(( $(request_count) + 1 ))" != "${FAKE_CURL_FAIL_AT:-}" ] || code="$FAKE_CURL_FAIL_CODE"
  echo "$code" >"$route.code"
  rm -f "$route.delay" "$route.drop"
  case "${FAKE_CURL_EXIT:-0}" in
    28) echo 5 >"$route.delay" ;;
    7 | 52) : >"$route.drop" ;;
  esac
  cp "$FAKE_CURL_BODY" "$route"
}

request_count() {
  if [ -f "$HTTP_LOG" ]; then wc -l <"$HTTP_LOG" | tr -d ' '; else echo 0; fi
}

# max_time_of <n>: the time limit, in seconds, the n-th request was sent with.
max_time_of() { sed -n "${1}p" "$FAKE_MAXTIMES"; }

# sent_header <name> [n]: a request header (lower-case name) of request n (default: the last).
sent_header() { jq -r --arg h "$1" ".headers[\$h] // empty" < <(sed -n "${2:-\$}p" "$HTTP_LOG"); }

# chunk_py <python code> [args]: runs the code with scripts/py on sys.path and sys.argv[1:] = args
# (the bats replacement for calling the old bash planner functions).
chunk_py() {
  python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); del sys.argv[1]
'"$1" "$REPO_ROOT/scripts/py" "${@:2}"
}
