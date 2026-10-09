# HTTP transport, total deadline: the clock, the per-request limit, the
# per-attempt deadline and the max-time of each request. Sourced by
# transport-http.sh, which supplies the SHUNT_TRY_INVOKE_* statuses and
# SHUNT_TIMEOUT_SECONDS. Not meant to be sourced on its own.

# One model attempt (a single request, or every chunk and merge request of a
# chunked call) must finish within SHUNT_TOTAL_TIMEOUT_SECONDS. Each failover
# candidate starts its own deadline. The clock is read only through
# _shunt_http_now, so tests can swap it. It counts _SHUNT_HTTP_TICKS per second:
# milliseconds from $EPOCHREALTIME (bash 5), else bash's whole $SECONDS
# (bash 3.2). The whole-second clock may already be up to a second into the
# start second, so it adds _SHUNT_HTTP_CLOCK_SLACK ticks to the deadline, which
# then fires up to a second late but never early.
_SHUNT_HTTP_NOW=0 _SHUNT_HTTP_TOTAL=0 _SHUNT_HTTP_DEADLINE=0
_SHUNT_HTTP_TICKS=1 _SHUNT_HTTP_CLOCK_SLACK=0
_SHUNT_HTTP_MAX_TIME="" _SHUNT_HTTP_MAX_TIME_CAPPED=0
# SHUNT_TIMEOUT_SECONDS as whole seconds rounded up, see _shunt_http_per_limit.
_SHUNT_HTTP_PER_LIMIT=""
# Chunk progress for the deadline message, 0 of 0 for an unchunked call.
_SHUNT_HTTP_CHUNKS_DONE=0 _SHUNT_HTTP_CHUNKS_TOTAL=0
# Longest accepted SHUNT_TOTAL_TIMEOUT_SECONDS, in digits, so the arithmetic
# cannot overflow. A SHUNT_TIMEOUT_SECONDS with more whole digits than this is
# longer than any total can be, so it counts as no per-request limit.
SHUNT_HTTP_TOTAL_TIMEOUT_MAX_DIGITS=9
# SHUNT_TIMEOUT_SECONDS when it is not a number, for the default total.
SHUNT_HTTP_FALLBACK_TIMEOUT_SECONDS=300

_shunt_http_now() {
  local t="${EPOCHREALTIME:-}"
  if [ -n "$t" ]; then
    t=${t/[.,]/}
    _SHUNT_HTTP_NOW=$(( 10#${t%???} )) _SHUNT_HTTP_TICKS=1000 _SHUNT_HTTP_CLOCK_SLACK=0
  else
    _SHUNT_HTTP_NOW=$SECONDS _SHUNT_HTTP_TICKS=1 _SHUNT_HTTP_CLOCK_SLACK=1
  fi
}

# _shunt_http_per_limit
# Sets _SHUNT_HTTP_PER_LIMIT from SHUNT_TIMEOUT_SECONDS: its whole seconds
# rounded up, 0 for no limit (0, as curl reads it, or more than
# SHUNT_HTTP_TOTAL_TIMEOUT_MAX_DIGITS whole digits), or empty when it is not a
# plain decimal number.
_shunt_http_per_limit() {
  local v="$SHUNT_TIMEOUT_SECONDS" whole frac=""
  _SHUNT_HTTP_PER_LIMIT=""
  whole=${v%%.*}
  [ "$whole" = "$v" ] || frac=${v#*.}
  case "$whole$frac" in '' | *[!0-9]*) return 0 ;; esac
  while [ "${#whole}" -gt 1 ] && [ "${whole#0}" != "$whole" ]; do whole=${whole#0}; done
  if [ "${#whole}" -gt "$SHUNT_HTTP_TOTAL_TIMEOUT_MAX_DIGITS" ]; then
    _SHUNT_HTTP_PER_LIMIT=0
    return 0
  fi
  _SHUNT_HTTP_PER_LIMIT=$(( 10#${whole:-0} ))
  case "$frac" in *[1-9]*) _SHUNT_HTTP_PER_LIMIT=$(( _SHUNT_HTTP_PER_LIMIT + 1 )) ;; esac
}

# _shunt_http_init_deadline
# Validates SHUNT_TOTAL_TIMEOUT_SECONDS (a config error, status 1, when it is not
# a positive whole number) and starts this model attempt's clock. Unset or
# empty means SHUNT_TOTAL_TIMEOUT_FACTOR times SHUNT_TIMEOUT_SECONDS (rounded up
# to whole seconds), and no total deadline when SHUNT_TIMEOUT_SECONDS is no
# limit. _SHUNT_HTTP_TOTAL is 0 when there is no total deadline.
_shunt_http_init_deadline() {
  local total="${SHUNT_TOTAL_TIMEOUT_SECONDS:-}"
  _SHUNT_HTTP_CHUNKS_DONE=0 _SHUNT_HTTP_CHUNKS_TOTAL=0
  if [ -z "$total" ]; then
    _shunt_http_per_limit
    total=$(( ${_SHUNT_HTTP_PER_LIMIT:-$SHUNT_HTTP_FALLBACK_TIMEOUT_SECONDS} * SHUNT_TOTAL_TIMEOUT_FACTOR ))
  else
    case "$total" in
      *[!0-9]*) total=bad ;;
      *) { [ "${#total}" -le "$SHUNT_HTTP_TOTAL_TIMEOUT_MAX_DIGITS" ] && [ $(( 10#$total )) -gt 0 ]; } || total=bad ;;
    esac
    if [ "$total" = bad ]; then
      echo "shunt: SHUNT_TOTAL_TIMEOUT_SECONDS must be a positive whole number of seconds (at most $SHUNT_HTTP_TOTAL_TIMEOUT_MAX_DIGITS digits), got '$(printf '%s' "$SHUNT_TOTAL_TIMEOUT_SECONDS" | tr -d '[:cntrl:]' | head -c 40)'." >&2
      return "$SHUNT_TRY_INVOKE_CONFIG"
    fi
    total=$(( 10#$total ))
  fi
  _SHUNT_HTTP_TOTAL=$total _SHUNT_HTTP_TICKS=1 _SHUNT_HTTP_CLOCK_SLACK=0
  _shunt_http_now
  _SHUNT_HTTP_DEADLINE=$(( _SHUNT_HTTP_NOW + total * _SHUNT_HTTP_TICKS + _SHUNT_HTTP_CLOCK_SLACK ))
}

# _shunt_http_deadline_note
# Says on stderr that the total deadline ended the call, and how far a chunked
# call got. Never prints chunk content.
_shunt_http_deadline_note() {
  local progress=""
  [ "$_SHUNT_HTTP_CHUNKS_TOTAL" -eq 0 ] \
    || progress=", $_SHUNT_HTTP_CHUNKS_DONE of $_SHUNT_HTTP_CHUNKS_TOTAL chunks finished"
  echo "shunt: model $_SHUNT_HTTP_ID: total deadline of ${_SHUNT_HTTP_TOTAL}s (SHUNT_TOTAL_TIMEOUT_SECONDS) reached$progress." >&2
}

# _shunt_http_request_max_time
# Sets _SHUNT_HTTP_MAX_TIME for the next request: SHUNT_TIMEOUT_SECONDS, or the
# time left before the deadline (whole seconds, rounded up, at most the total)
# when SHUNT_TIMEOUT_SECONDS is longer or no limit (then
# _SHUNT_HTTP_MAX_TIME_CAPPED is 1). Returns SHUNT_TRY_INVOKE_DEADLINE, and sends
# nothing, once no time is left.
_shunt_http_request_max_time() {
  local left
  _SHUNT_HTTP_MAX_TIME="$SHUNT_TIMEOUT_SECONDS" _SHUNT_HTTP_MAX_TIME_CAPPED=0
  [ "$_SHUNT_HTTP_TOTAL" -gt 0 ] || return 0
  _shunt_http_now
  left=$(( _SHUNT_HTTP_DEADLINE - _SHUNT_HTTP_NOW ))
  if [ "$left" -le 0 ]; then
    _shunt_http_deadline_note
    return "$SHUNT_TRY_INVOKE_DEADLINE"
  fi
  left=$(( (left + _SHUNT_HTTP_TICKS - 1) / _SHUNT_HTTP_TICKS ))
  [ "$left" -le "$_SHUNT_HTTP_TOTAL" ] || left=$_SHUNT_HTTP_TOTAL
  # A SHUNT_TIMEOUT_SECONDS that is not a number is passed on to curl unchanged.
  _shunt_http_per_limit
  [ -n "$_SHUNT_HTTP_PER_LIMIT" ] || return 0
  if [ "$_SHUNT_HTTP_PER_LIMIT" -eq 0 ] || [ "$left" -lt "$_SHUNT_HTTP_PER_LIMIT" ]; then
    _SHUNT_HTTP_MAX_TIME=$left _SHUNT_HTTP_MAX_TIME_CAPPED=1
  fi
}
