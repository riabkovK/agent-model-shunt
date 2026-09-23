# Circuit breaker for delegate models, scoped only to failures (errors,
# timeouts), never latency. N consecutive failures on a model opens the
# breaker and excludes it for a cooldown period, after which it is retried
# automatically (half-open: the next is_open check simply reports closed
# again, no separate trial-request state). No response-time measurement and
# no racing multiple models concurrently: both were considered and ruled out
# as unnecessary complexity for v1.
#
# State is persisted to a JSON file (SHUNT_BREAKER_STATE_FILE) since every
# delegated call is its own short-lived `opencode run` process with no
# shared memory between calls.
#
# Meant to be sourced by scripts/lib/opencode.sh (failover wiring) and
# hooks/check-file-size (to allow a direct Read through when no delegate
# model is available). Requires jq.

SHUNT_BREAKER_STATE_FILE="${SHUNT_BREAKER_STATE_FILE:-$HOME/.cache/agent-model-shunt/breaker-state.json}"

# Config precedence: hardcoded default -> SHUNT_BREAKER_CONFIG_FILE (if
# present and valid) -> SHUNT_BREAKER_THRESHOLD/SHUNT_BREAKER_COOLDOWN_SECONDS
# env vars, which stay the emergency/test override on top of everything
# else. Read once here, at source time, not inside any function body: this
# file is re-sourced fresh in every hook/opencode.sh process, so a function
# that re-read the config file on every call would pay that jq cost once per
# call instead of once per process - unacceptable for hooks/check-file-size,
# which must stay cheap on every Read.
SHUNT_BREAKER_CONFIG_FILE="${SHUNT_BREAKER_CONFIG_FILE:-$HOME/.config/agent-model-shunt/breaker-config.json}"

# Every value that can reach bash arithmetic or an integer comparison (state
# file fields, config file fields, env overrides) goes through this guard
# first. Bash evaluates the operands of $(( )) recursively, so an unchecked
# string such as 'a[$(cmd)]' from a tampered state file would run cmd. Only
# plain decimal digits pass. Anything else (text, negative or fractional
# numbers, JSON objects, empty) yields the fallback instead.
#
# _shunt_breaker_uint_or <value> <fallback>
# Sets REPLY (no subshell, so it stays cheap in hooks) to <value> as a decimal
# integer when it is 1 to 15 digits, else to <fallback>. The 10# prefix keeps
# leading zeros from being read as octal, and the length cap keeps the result
# inside a 64-bit signed integer.
_shunt_breaker_uint_or() {
  local value="${1-}" fallback="$2"
  if [[ "$value" =~ ^[0-9]{1,15}$ ]]; then
    REPLY=$((10#$value))
  else
    REPLY="$fallback"
  fi
}

_shunt_breaker_default_threshold=3
_shunt_breaker_default_cooldown=300

_shunt_breaker_config_threshold=""
_shunt_breaker_config_cooldown=""
if [ -f "$SHUNT_BREAKER_CONFIG_FILE" ]; then
  _shunt_breaker_config_threshold=$(jq -r '.threshold // empty' "$SHUNT_BREAKER_CONFIG_FILE" 2>/dev/null) || _shunt_breaker_config_threshold=""
  _shunt_breaker_config_cooldown=$(jq -r '.cooldown_seconds // empty' "$SHUNT_BREAKER_CONFIG_FILE" 2>/dev/null) || _shunt_breaker_config_cooldown=""
fi

# Same precedence as above (env, then config file, then default), but a value
# that is not a plain non-negative integer is skipped at each step.
_shunt_breaker_uint_or "$_shunt_breaker_config_threshold" "$_shunt_breaker_default_threshold"
_shunt_breaker_uint_or "${SHUNT_BREAKER_THRESHOLD:-}" "$REPLY"
SHUNT_BREAKER_THRESHOLD="$REPLY"
_shunt_breaker_uint_or "$_shunt_breaker_config_cooldown" "$_shunt_breaker_default_cooldown"
_shunt_breaker_uint_or "${SHUNT_BREAKER_COOLDOWN_SECONDS:-}" "$REPLY"
SHUNT_BREAKER_COOLDOWN_SECONDS="$REPLY"

unset _shunt_breaker_default_threshold _shunt_breaker_default_cooldown
unset _shunt_breaker_config_threshold _shunt_breaker_config_cooldown

# shunt_breaker_now
# Prints the current epoch seconds, or SHUNT_NOW_EPOCH when set to a plain
# non-negative integer (test hook). Any other SHUNT_NOW_EPOCH value is ignored.
shunt_breaker_now() {
  if [[ "${SHUNT_NOW_EPOCH-}" =~ ^[0-9]{1,15}$ ]]; then
    echo "$((10#$SHUNT_NOW_EPOCH))"
  else
    date +%s
  fi
}

# _shunt_breaker_parse_state <state-json>
# Reads the failures and cooldown_until fields of a model state object (as
# printed by shunt_breaker_model_state) into _shunt_breaker_failures and
# _shunt_breaker_cooldown_until. Missing, corrupt or non-integer values, and a
# state that is not an object, all read as 0 (a closed breaker, same as an
# absent file). The jq filter drops everything that is not a non-negative
# whole number, and the bash guard then re-checks the printed text.
_shunt_breaker_parse_state() {
  local raw f c
  raw=$(printf '%s' "$1" | jq -r '
    def whole: if type == "number" and . >= 0 and . == floor then . else 0 end;
    try (if type == "object" then "\(.failures | whole) \(.cooldown_until | whole)" else "0 0" end)
    catch "0 0"' 2>/dev/null) || raw="0 0"
  read -r f c <<<"$raw"
  _shunt_breaker_uint_or "$f" 0
  _shunt_breaker_failures="$REPLY"
  _shunt_breaker_uint_or "$c" 0
  _shunt_breaker_cooldown_until="$REPLY"
}

# shunt_breaker_key <id> [role]
# Prints the state key that holds <id>'s failure counter for <role>. The
# bulk-read role (the default) keeps the plain model id, so state written
# before roles existed still applies. Every other role gets its own counter
# under "<id>#<role>", so a model that keeps failing one kind of call is not
# paused for the other.
shunt_breaker_key() {
  local id="$1" role="${2:-bulk-read}"
  if [ "$role" = "bulk-read" ]; then
    echo "$id"
  else
    echo "$id#$role"
  fi
}

# shunt_breaker_model_state <id>
# Prints the model's state object, or "null" if no state file or no entry
# exists yet for <id>.
shunt_breaker_model_state() {
  local id="$1"
  [ -f "$SHUNT_BREAKER_STATE_FILE" ] || { echo "null"; return; }
  jq -c --arg id "$id" '.models[$id] // null' "$SHUNT_BREAKER_STATE_FILE" 2>/dev/null || echo "null"
}

# shunt_breaker_is_open <id>
# Success (0) if <id>'s breaker is currently open (failures at/above
# threshold and still within its cooldown window); failure (1) otherwise,
# including when there is no recorded state.
shunt_breaker_is_open() {
  local id="$1"
  local state
  state=$(shunt_breaker_model_state "$id")
  [ "$state" != "null" ] || return 1

  local _shunt_breaker_failures _shunt_breaker_cooldown_until now
  _shunt_breaker_parse_state "$state"
  now=$(shunt_breaker_now)

  [ "$_shunt_breaker_failures" -ge "$SHUNT_BREAKER_THRESHOLD" ] \
    && [ "$now" -lt "$_shunt_breaker_cooldown_until" ]
}

# shunt_breaker_write_state <id> <failures> <cooldown_until>
# Atomically writes the given fields for <id> into the state file. The state
# file is self-healing: a missing, empty, truncated or otherwise unparsable
# file (or one that is not a JSON object) is treated as an empty state and
# overwritten with a fresh one. Reads keep treating such a file as a closed
# breaker and never touch it. Returns non-zero only when the write itself
# fails (for example the directory or file is not writable).
shunt_breaker_write_state() {
  local id="$1" failures="$2" cooldown_until="$3"
  local dir
  dir=$(dirname "$SHUNT_BREAKER_STATE_FILE")

  mkdir -p "$dir" || return 1

  # A file holding exactly one JSON object is updated in place. Anything else
  # starts from a null input, which the filter below turns into the empty
  # state {"version":1,"models":{}}.
  local -a input=(--null-input)
  if [ -f "$SHUNT_BREAKER_STATE_FILE" ] \
    && jq -e -s 'length == 1 and (.[0] | type == "object")' "$SHUNT_BREAKER_STATE_FILE" >/dev/null 2>&1; then
    input=("$SHUNT_BREAKER_STATE_FILE")
  fi

  local tmp_file
  tmp_file=$(mktemp "$dir/.breaker-state.json.XXXXXX") || return 1

  jq -e --arg id "$id" --argjson f "$failures" --argjson c "$cooldown_until" '
    (if type == "object" then . else {version: 1} end)
    | (if (.models | type) == "object" then . else .models = {} end)
    | .models[$id] = {failures: $f, cooldown_until: $c}' \
    "${input[@]}" >"$tmp_file" \
    && mv "$tmp_file" "$SHUNT_BREAKER_STATE_FILE" \
    || { rm -f "$tmp_file"; return 1; }
}

# shunt_breaker_clear_state <id>
# Atomically drops <id>'s entries from the state file (the plain key and every
# "<id>#<role>" key, see shunt_breaker_key) so a removed model doesn't leave
# stale failure/cooldown data behind (a later re-add would otherwise inherit
# an open breaker). No-op if there is no state file.
shunt_breaker_clear_state() {
  local id="$1"
  [ -f "$SHUNT_BREAKER_STATE_FILE" ] || return 0

  local tmp_file
  tmp_file=$(mktemp "$(dirname "$SHUNT_BREAKER_STATE_FILE")/.breaker-state.json.XXXXXX")

  jq -e --arg id "$id" \
    'if .models then .models |= with_entries(select(.key != $id and (.key | startswith($id + "#") | not))) else . end' \
    "$SHUNT_BREAKER_STATE_FILE" >"$tmp_file" \
    && mv "$tmp_file" "$SHUNT_BREAKER_STATE_FILE" \
    || { rm -f "$tmp_file"; return 1; }
}

# shunt_breaker_record_failure <id>
# Increments <id>'s consecutive failure count. Once it reaches
# SHUNT_BREAKER_THRESHOLD, (re-)starts the cooldown window from now.
shunt_breaker_record_failure() {
  local id="$1"
  local state failures cooldown_until now
  local _shunt_breaker_failures _shunt_breaker_cooldown_until
  state=$(shunt_breaker_model_state "$id")
  _shunt_breaker_parse_state "$state"
  failures="$_shunt_breaker_failures"
  cooldown_until="$_shunt_breaker_cooldown_until"
  now=$(shunt_breaker_now)

  failures=$((failures + 1))
  if [ "$failures" -ge "$SHUNT_BREAKER_THRESHOLD" ]; then
    cooldown_until=$((now + SHUNT_BREAKER_COOLDOWN_SECONDS))
  fi

  shunt_breaker_write_state "$id" "$failures" "$cooldown_until"
}

# shunt_breaker_record_success <id>
# Resets <id>'s failure count and closes its breaker.
shunt_breaker_record_success() {
  local id="$1"
  shunt_breaker_write_state "$id" 0 0
}

# shunt_breaker_any_closed <id...>
# Success (0) if at least one of the given ids is currently closed
# (usable); failure (1) if every given id is open, or if no ids were given.
# Reads the state file once via a single jq call, rather than looping
# shunt_breaker_is_open per id, since this is meant for
# hooks/check-file-size, which runs on every large-file Read and must stay
# cheap even with several candidate models.
shunt_breaker_any_closed() {
  [ "$#" -gt 0 ] || return 1

  local ids_json now state_json
  ids_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  now=$(shunt_breaker_now)
  state_json='{"models":{}}'
  [ -f "$SHUNT_BREAKER_STATE_FILE" ] && state_json=$(cat "$SHUNT_BREAKER_STATE_FILE")

  # Same reading rules as _shunt_breaker_parse_state: anything that is not a
  # non-negative whole number counts as 0 (closed), never as open. An
  # unparsable state file (jq exit code 2 or above) also counts as closed, to
  # match shunt_breaker_is_open. Only a plain "false" result (exit 1) means
  # every id is open.
  local rc=0
  echo "$state_json" | jq -e \
    --argjson ids "$ids_json" --argjson threshold "$SHUNT_BREAKER_THRESHOLD" --argjson now "$now" '
    def whole: if type == "number" and . >= 0 and . == floor then . else 0 end;
    def field($f): if type == "object" then (.[$f] | whole) else 0 end;
    . as $root
    | $ids | any(. as $id
        | (try $root.models[$id] catch null) as $s
        | (($s | field("failures")) < $threshold) or ($now >= ($s | field("cooldown_until"))))
  ' >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 1 ]
}

# shunt_breaker_status <id>
# Prints a one-line "failures=N open=true|false" summary for <id>.
shunt_breaker_status() {
  local id="$1"
  local state
  local _shunt_breaker_failures _shunt_breaker_cooldown_until
  state=$(shunt_breaker_model_state "$id")
  _shunt_breaker_parse_state "$state"

  local open="false"
  shunt_breaker_is_open "$id" && open="true"

  echo "failures=$_shunt_breaker_failures open=$open"
}
