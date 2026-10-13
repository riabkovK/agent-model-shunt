# A fake provider for the http transport tests, on top of the local scripted server
# (test/py/httpserver.py). It replaces the fake curl these tests used to put on PATH.
# Load it after test_helper and call fake_http_start in setup (after
# shunt_test_setup and after sourcing scripts/lib/opencode.sh), stop_http_server in
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
# wraps the transport's request function and its max time function.
fake_http_start() {
  FAKE_ROUTES="$TEST_TMPDIR/routes"
  FAKE_MAXTIMES="$TEST_TMPDIR/max-times"
  export FAKE_CURL_SENT="$TEST_TMPDIR/curl-sent"
  mkdir -p "$FAKE_ROUTES"
  start_http_server "$FAKE_ROUTES" --sent "$FAKE_CURL_SENT"
  FAKE_BASE="http://127.0.0.1:$HTTP_PORT/v1"
  eval "$(declare -f _shunt_http_py | sed '1s/^_shunt_http_py/_fake_orig_py/')"
  eval "$(declare -f _shunt_http_request_max_time | sed '1s/^_shunt_http_request_max_time/_fake_orig_max_time/')"
  _shunt_http_py() { _fake_py_wrapper "$@"; }
  _shunt_http_request_max_time() { _fake_max_time_wrapper "$@"; }
}

_fake_py_wrapper() {
  local before after status=0
  fake_http_sync
  before=$(request_count)
  _fake_orig_py "$@" || status=$?
  after=$(request_count)
  [ "$after" -le "$before" ] || echo "$_FAKE_REAL_MAX_TIME" >>"$FAKE_MAXTIMES"
  if [ -n "${FAKE_CLOCK:-}" ] && [ "$after" -gt "$before" ]; then
    echo $(( $(cat "$FAKE_CLOCK") + ${FAKE_CURL_ADVANCE:-0} )) >"$FAKE_CLOCK"
  fi
  return "$status"
}

_fake_max_time_wrapper() {
  _fake_orig_max_time || return $?
  _FAKE_REAL_MAX_TIME="$_SHUNT_HTTP_MAX_TIME"
  [ "${FAKE_CURL_EXIT:-0}" != 28 ] || _SHUNT_HTTP_MAX_TIME=0.3
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

# max_time_of <n>: the max time of the n-th request.
max_time_of() { sed -n "${1}p" "$FAKE_MAXTIMES"; }

# sent_header <name> [n]: a request header (lower-case name) of request n (default: the last).
sent_header() { jq -r --arg h "$1" ".headers[\$h] // empty" < <(sed -n "${2:-\$}p" "$HTTP_LOG"); }
