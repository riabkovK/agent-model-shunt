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

_shunt_breaker_default_threshold=3
_shunt_breaker_default_cooldown=300

_shunt_breaker_config_threshold=""
_shunt_breaker_config_cooldown=""
if [ -f "$SHUNT_BREAKER_CONFIG_FILE" ]; then
  _shunt_breaker_config_threshold=$(jq -r '.threshold // empty' "$SHUNT_BREAKER_CONFIG_FILE" 2>/dev/null) || _shunt_breaker_config_threshold=""
  _shunt_breaker_config_cooldown=$(jq -r '.cooldown_seconds // empty' "$SHUNT_BREAKER_CONFIG_FILE" 2>/dev/null) || _shunt_breaker_config_cooldown=""
fi

SHUNT_BREAKER_THRESHOLD="${SHUNT_BREAKER_THRESHOLD:-${_shunt_breaker_config_threshold:-$_shunt_breaker_default_threshold}}"
SHUNT_BREAKER_COOLDOWN_SECONDS="${SHUNT_BREAKER_COOLDOWN_SECONDS:-${_shunt_breaker_config_cooldown:-$_shunt_breaker_default_cooldown}}"

unset _shunt_breaker_default_threshold _shunt_breaker_default_cooldown
unset _shunt_breaker_config_threshold _shunt_breaker_config_cooldown

# shunt_breaker_now
# Prints the current epoch seconds, or SHUNT_NOW_EPOCH when set (test hook).
shunt_breaker_now() {
  echo "${SHUNT_NOW_EPOCH:-$(date +%s)}"
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

  local failures cooldown_until now
  failures=$(echo "$state" | jq -r '.failures // 0')
  cooldown_until=$(echo "$state" | jq -r '.cooldown_until // 0')
  now=$(shunt_breaker_now)

  [ "$failures" -ge "$SHUNT_BREAKER_THRESHOLD" ] && [ "$now" -lt "$cooldown_until" ]
}

# shunt_breaker_write_state <id> <failures> <cooldown_until>
# Atomically writes the given fields for <id> into the state file.
shunt_breaker_write_state() {
  local id="$1" failures="$2" cooldown_until="$3"

  mkdir -p "$(dirname "$SHUNT_BREAKER_STATE_FILE")"
  [ -f "$SHUNT_BREAKER_STATE_FILE" ] || echo '{"version":1,"models":{}}' >"$SHUNT_BREAKER_STATE_FILE"

  local tmp_file
  tmp_file=$(mktemp "$(dirname "$SHUNT_BREAKER_STATE_FILE")/.breaker-state.json.XXXXXX")

  jq -e --arg id "$id" --argjson f "$failures" --argjson c "$cooldown_until" \
    '.models[$id] = {failures: $f, cooldown_until: $c}' \
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
  state=$(shunt_breaker_model_state "$id")
  failures=$(echo "$state" | jq -r 'if . == null then 0 else (.failures // 0) end')
  cooldown_until=$(echo "$state" | jq -r 'if . == null then 0 else (.cooldown_until // 0) end')
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

# shunt_breaker_status <id>
# Prints a one-line "failures=N open=true|false" summary for <id>.
shunt_breaker_status() {
  local id="$1"
  local state failures
  state=$(shunt_breaker_model_state "$id")
  failures=$(echo "$state" | jq -r 'if . == null then 0 else (.failures // 0) end')

  local open="false"
  shunt_breaker_is_open "$id" && open="true"

  echo "failures=$failures open=$open"
}
