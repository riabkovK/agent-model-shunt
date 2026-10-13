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
# model is available). Needs python3, not jq.

SHUNT_BREAKER_STATE_FILE="${SHUNT_BREAKER_STATE_FILE:-$HOME/.cache/agent-model-shunt/breaker-state.json}"

# Config precedence: hardcoded default -> SHUNT_BREAKER_CONFIG_FILE (if
# present and valid) -> SHUNT_BREAKER_THRESHOLD/SHUNT_BREAKER_COOLDOWN_SECONDS
# env vars, which stay the emergency/test override on top of everything
# else. Read once here, at source time, not inside any function body: this
# file is re-sourced fresh in every hook/opencode.sh process, so a function
# that re-read the config file on every call would pay that cost once per
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
# shellcheck source=py.sh
source "${BASH_SOURCE[0]%/*}/py.sh"
if [ -f "$SHUNT_BREAKER_CONFIG_FILE" ]; then
  # The two fields come from one Python call. It also applies the env overrides, so
  # the env values below are only a second pass over an already resolved number.
  _shunt_breaker_limits=$(SHUNT_BREAKER_CONFIG_FILE="$SHUNT_BREAKER_CONFIG_FILE" SHUNT_BREAKER_THRESHOLD="${SHUNT_BREAKER_THRESHOLD-}" \
    SHUNT_BREAKER_COOLDOWN_SECONDS="${SHUNT_BREAKER_COOLDOWN_SECONDS-}" shunt_py breaker limits 2>/dev/null) || _shunt_breaker_limits=""
  _shunt_breaker_config_threshold="${_shunt_breaker_limits%% *}"
  _shunt_breaker_config_cooldown="${_shunt_breaker_limits#* }"
  unset _shunt_breaker_limits
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

# The state logic lives in scripts/py/shunt/breaker.py. The functions below are
# thin wrappers with the old names, stdout and return codes, one shunt_py call
# each. The paths and limits resolved above are exported only for the call (the
# variables may be unexported shell defaults). Python takes the state file lock
# itself for every read-modify-write (record, write, clear), the readers never
# lock. Key ids go after `--` so an id that starts with a dash stays an id.


# _shunt_breaker_py <subcommand> [args...]
_shunt_breaker_py() {
  SHUNT_BREAKER_STATE_FILE="$SHUNT_BREAKER_STATE_FILE" \
    SHUNT_BREAKER_CONFIG_FILE="$SHUNT_BREAKER_CONFIG_FILE" \
    SHUNT_BREAKER_THRESHOLD="$SHUNT_BREAKER_THRESHOLD" \
    SHUNT_BREAKER_COOLDOWN_SECONDS="$SHUNT_BREAKER_COOLDOWN_SECONDS" \
    SHUNT_NOW_EPOCH="${SHUNT_NOW_EPOCH-}" \
    SHUNT_PROVIDERS_LOCK_TIMEOUT="${SHUNT_PROVIDERS_LOCK_TIMEOUT-}" \
    shunt_py breaker "$@"
}

# shunt_breaker_now
# Prints the current epoch seconds, or SHUNT_NOW_EPOCH when set to a plain
# non-negative integer (test hook). Any other SHUNT_NOW_EPOCH value is ignored.
# Stays in bash: it is one `date` call at most and Python would cost more.
shunt_breaker_now() {
  if [[ "${SHUNT_NOW_EPOCH-}" =~ ^[0-9]{1,15}$ ]]; then
    echo "$((10#$SHUNT_NOW_EPOCH))"
  else
    date +%s
  fi
}

# shunt_breaker_key <id> [role]
# Prints the state key that holds <id>'s failure counter for <role>. The
# bulk-read role (the default) keeps the plain model id, so state written
# before roles existed still applies. Every other role gets its own counter
# under "<id>#<role>", so a model that keeps failing one kind of call is not
# paused for the other. Pure string work, so it stays in bash (no subprocess).
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
  _shunt_breaker_py model-state -- "$1"
}

# shunt_breaker_is_open <id>
# Success (0) if <id>'s breaker is currently open (failures at/above
# threshold and still within its cooldown window); failure (1) otherwise,
# including when there is no recorded state.
shunt_breaker_is_open() {
  _shunt_breaker_py is-open -- "$1"
}

# shunt_breaker_write_state <id> <failures> <cooldown_until>
# Atomically writes the given fields for <id> into the state file, under the
# state file lock. The file is self-healing: a missing, empty, truncated or
# otherwise unparsable file (or one that is not a JSON object) is treated as an
# empty state and overwritten with a fresh one. Reads keep treating such a file
# as a closed breaker and never touch it. Returns non-zero only when the write
# itself fails (for example the directory is not writable or the lock times out).
shunt_breaker_write_state() {
  _shunt_breaker_py write-state -- "$1" "$2" "$3"
}

# shunt_breaker_clear_state <id>
# Atomically drops <id>'s entries from the state file (the plain key and every
# "<id>#<role>" key, see shunt_breaker_key) so a removed model doesn't leave
# stale failure/cooldown data behind (a later re-add would otherwise inherit
# an open breaker). No-op if there is no state file.
shunt_breaker_clear_state() {
  _shunt_breaker_py clear-state -- "$1"
}

# shunt_breaker_record_failure <id>
# Increments <id>'s consecutive failure count. Once it reaches
# SHUNT_BREAKER_THRESHOLD, (re-)starts the cooldown window from now. The read
# and the write happen under one lock, so concurrent failures are all counted.
shunt_breaker_record_failure() {
  _shunt_breaker_py record-failure -- "$1"
}

# shunt_breaker_record_success <id>
# Resets <id>'s failure count and closes its breaker.
shunt_breaker_record_success() {
  _shunt_breaker_py record-success -- "$1"
}

# shunt_breaker_any_closed <id...>
# Success (0) if at least one of the given ids is currently closed
# (usable); failure (1) if every given id is open, or if no ids were given.
# One state file read for all ids (used by hooks/check-file-size on every
# large-file Read).
shunt_breaker_any_closed() {
  [ "$#" -gt 0 ] || return 1
  _shunt_breaker_py any-closed -- "$@"
}

# shunt_breaker_status <id>
# Prints a one-line "failures=N open=true|false" summary for <id>.
shunt_breaker_status() {
  _shunt_breaker_py status -- "$1"
}
