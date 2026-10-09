#!/bin/bash
# Provider config and API key handling for the HTTP transport. Reads
# providers.json (~/.config/agent-model-shunt/providers.json by default):
#
#   {"version":1,"providers":{"<name>":{
#      "transport":"http"|"opencode","base_url":"...",
#      "key":{"type":"keyring"|"env"|"plaintext"|"none","ref":"<env var name or plaintext value>"}}}}
#
# A missing file or provider means the implicit transport "opencode".
#
# Secret rules: a key is only ever printed by shunt_provider_key_resolve /
# shunt_keyring_get (callers capture it into a variable) or written into a
# 0600 header file. It never goes into argv (except the documented `security`
# limitation below), logs or error messages. Functions here report problems on
# stderr and return non-zero, they never exit, so they are safe inside $(...).

SHUNT_PROVIDERS_FILE="${SHUNT_PROVIDERS_FILE:-$HOME/.config/agent-model-shunt/providers.json}"
SHUNT_PROC_VERSION_FILE="${SHUNT_PROC_VERSION_FILE:-/proc/version}"
SHUNT_KEYRING_SERVICE="agent-model-shunt"
SHUNT_KWALLET_WALLET="kdewallet"
SHUNT_PROVIDER_TRANSPORTS="http opencode"
SHUNT_PROVIDER_KEY_TYPES="keyring env plaintext none"

SHUNT_PROVIDERS_LOCK_TIMEOUT="${SHUNT_PROVIDERS_LOCK_TIMEOUT:-10}"
_SHUNT_PROVIDERS_LOCK_DEPTH=0 _SHUNT_PROVIDERS_LOCK_FD="" _SHUNT_PROVIDERS_LOCK_DIR=""

# _shunt_guard_install <prefix> <cleanup-command>
# Runs <cleanup-command> when the shell exits, including on INT, TERM and HUP,
# and then still runs the caller's own EXIT trap. The caller's EXIT, INT, TERM
# and HUP traps are saved in <prefix>_SAVED_<SIG> (use a distinct <prefix> per
# guard) and put back by _shunt_guard_remove. While a guard is installed a
# caller's INT, TERM or HUP trap does not run. Bash defers a trap until the
# foreground child ends, so a signal sent to the whole process group acts at once.
_shunt_guard_install() {
  local prefix="$1" cleanup="$2" sig saved old_exit=""
  for sig in EXIT INT TERM HUP; do
    saved=$(trap -p "$sig")
    printf -v "${prefix}_SAVED_$sig" '%s' "$saved"
    if [ "$sig" = EXIT ] && [ -n "$saved" ]; then
      eval "set -- $saved"
      old_exit="${3:-}"
    fi
  done
  # The trap text only acts in the process that installed it: a subshell that
  # inherits it (trap -p reports the parent's traps) must not run the cleanup.
  local pid="${BASHPID:-$$}"
  # shellcheck disable=SC2064 # pid and the commands are meant to be expanded now
  # The caller's trap goes on its own lines: a trailing comment in it must not
  # swallow the closing "fi".
  trap "if [ \"\${BASHPID:-\$\$}\" = $pid ]; then
$cleanup
${old_exit:+$old_exit
}fi" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

# _shunt_guard_remove <prefix>
# Puts back the traps saved by _shunt_guard_install. Does not run the cleanup.
_shunt_guard_remove() {
  local prefix="$1" sig var
  for sig in EXIT INT TERM HUP; do
    var="${prefix}_SAVED_$sig"
    if [ -n "${!var:-}" ]; then eval "${!var}"; else trap - "$sig"; fi
  done
}

# jq definition: `entry_problem` maps one providers to_entries item to a
# description of what is wrong with it, or null. Never includes a key ref.
# shellcheck disable=SC2016 # jq program, $names are jq variables
_SHUNT_PROVIDER_ENTRY_PROBLEM_JQ='
  def entry_problem($transports; $types):
    .key as $n | .value as $v
    | if ($v | type) != "object" then "provider \"\($n)\": entry is not an object"
      elif ($v.transport // "opencode" | type) != "string" then "provider \"\($n)\": transport is not a string"
      elif ($transports | index($v.transport // "opencode")) == null
        then "provider \"\($n)\": unknown transport \"\($v.transport)\" (allowed: \($transports | join(" ")))"
      elif ($v.base_url // "" | type) != "string" then "provider \"\($n)\": base_url is not a string"
      elif ($v.base_url // "" | test("^([A-Za-z][A-Za-z0-9+.-]*://)?[^/?#]*@")) then "provider \"\($n)\": base_url has credentials (user:password@) in it"
      elif ($v.key // {} | type) != "object"
        then "provider \"\($n)\": key is not an object (expected {\"type\":\"...\",\"ref\":\"...\"})"
      elif ($v.key.type // "none" | type) != "string" then "provider \"\($n)\": key type is not a string"
      elif ($types | index($v.key.type // "none")) == null
        then "provider \"\($n)\": unknown key type \"\($v.key.type)\" (allowed: \($types | join(" ")))"
      elif ($v.key.ref // "" | type) != "string" then "provider \"\($n)\": key ref is not a string"
      elif $v.key.type == "env" and (($v.key.ref // "") | test("^[A-Za-z_][A-Za-z0-9_]*$") | not)
        then "provider \"\($n)\": env key ref is not a valid environment variable name"
      else null end;'

# shunt_providers_validate
# Returns 0 when the file is absent or valid. Otherwise explains on stderr.
shunt_providers_validate() {
  [ -f "$SHUNT_PROVIDERS_FILE" ] || return 0
  if ! jq -e '(.providers | type) == "object"' "$SHUNT_PROVIDERS_FILE" >/dev/null 2>&1; then
    echo "shunt: $SHUNT_PROVIDERS_FILE is invalid JSON or has no \"providers\" object." >&2
    return 1
  fi
  local bad
  if ! bad=$(jq -r --arg ts "$SHUNT_PROVIDER_TRANSPORTS" --arg kt "$SHUNT_PROVIDER_KEY_TYPES" \
    "$_SHUNT_PROVIDER_ENTRY_PROBLEM_JQ"'
    .providers | to_entries[] | entry_problem($ts | split(" "); $kt | split(" ")) // empty' \
    "$SHUNT_PROVIDERS_FILE" 2>/dev/null); then
    echo "shunt: $SHUNT_PROVIDERS_FILE could not be validated." >&2
    return 1
  fi
  if [ -n "$bad" ]; then
    echo "shunt: $SHUNT_PROVIDERS_FILE: ${bad%%$'\n'*}" >&2
    return 1
  fi
}

# shunt_providers_list_lines
# Prints one tab-separated line per provider: name, transport, base_url and
# key type (env:<VAR> for env keys). An invalid entry gets "invalid: <reason>"
# instead, so one bad entry does not hide the others. Never prints a key value.
shunt_providers_list_lines() {
  jq -r --arg ts "$SHUNT_PROVIDER_TRANSPORTS" --arg kt "$SHUNT_PROVIDER_KEY_TYPES" \
    "$_SHUNT_PROVIDER_ENTRY_PROBLEM_JQ"'
    .providers | to_entries[]
    | entry_problem($ts | split(" "); $kt | split(" ")) as $bad
    | if $bad != null then "\(.key)\tinvalid: \($bad)"
      else (.value.key // {}) as $k
        | "\(.key)\t\(.value.transport // "opencode")\t\(.value.base_url // "-")\t"
          + (if $k.type == "env" then "env:\($k.ref // "")" else ($k.type // "none") end)
      end' "$SHUNT_PROVIDERS_FILE"
}

# shunt_base_url_check <url>
# The one base_url validator, shared by `provider set` and the HTTP transport.
# Returns 0 for a usable URL, 2 for a scheme other than http:// or https://,
# 3 for no scheme at all, 1 when it is malformed: empty host, userinfo
# (user:pass@), whitespace or control characters. Never prints the URL.
shunt_base_url_check() {
  local url="$1" rest authority
  case "$url" in
    https://*) rest="${url#https://}" ;;
    http://*) rest="${url#http://}" ;;
    *://*) return 2 ;;
    *) rest="$url" ;;
  esac
  authority="${rest%%[/?#]*}"
  if [ -z "$authority" ] || [[ "$url" == *[[:space:][:cntrl:]]* ]] || [[ "$authority" == *@* ]]; then
    return 1
  fi
  [ "$rest" != "$url" ] || return 3
}

# shunt_providers_lock / shunt_providers_unlock
# Serializes read-modify-write of providers.json between processes. Uses
# flock on <file>.lock when available, otherwise a <file>.lock.d directory
# (removed by an EXIT trap if the process exits while holding it). Nested
# calls in the same process only count depth. Gives up after
# SHUNT_PROVIDERS_LOCK_TIMEOUT seconds.
shunt_providers_lock() {
  if [ "$_SHUNT_PROVIDERS_LOCK_DEPTH" -gt 0 ]; then
    _SHUNT_PROVIDERS_LOCK_DEPTH=$((_SHUNT_PROVIDERS_LOCK_DEPTH + 1))
    return 0
  fi
  local lock="$SHUNT_PROVIDERS_FILE.lock" tries
  mkdir -p "$(dirname "$SHUNT_PROVIDERS_FILE")" || return 1
  # flock on a fixed fd works on every bash. The `{fd}>` form needs bash 4.1.
  if command -v flock >/dev/null 2>&1; then
    exec 8>>"$lock" || return 1
    if ! flock -x -w "$SHUNT_PROVIDERS_LOCK_TIMEOUT" 8; then
      exec 8>&-
      echo "shunt: timed out waiting for the lock on $SHUNT_PROVIDERS_FILE." >&2
      return 1
    fi
    _SHUNT_PROVIDERS_LOCK_FD=8
  else
    tries=$((SHUNT_PROVIDERS_LOCK_TIMEOUT * 10))
    until mkdir "$lock.d" 2>/dev/null; do
      tries=$((tries - 1))
      if [ "$tries" -le 0 ]; then
        echo "shunt: timed out waiting for the lock on $SHUNT_PROVIDERS_FILE (remove $lock.d if no shunt-models is running)." >&2
        return 1
      fi
      sleep 0.1
    done
    _SHUNT_PROVIDERS_LOCK_DIR="$lock.d"
    _shunt_guard_install _SHUNT_PL 'rmdir "$_SHUNT_PROVIDERS_LOCK_DIR" 2>/dev/null'
  fi
  _SHUNT_PROVIDERS_LOCK_DEPTH=1
}

shunt_providers_unlock() {
  [ "$_SHUNT_PROVIDERS_LOCK_DEPTH" -gt 0 ] || return 0
  _SHUNT_PROVIDERS_LOCK_DEPTH=$((_SHUNT_PROVIDERS_LOCK_DEPTH - 1))
  [ "$_SHUNT_PROVIDERS_LOCK_DEPTH" -eq 0 ] || return 0
  if [ -n "$_SHUNT_PROVIDERS_LOCK_FD" ]; then
    exec 8>&-
    _SHUNT_PROVIDERS_LOCK_FD=""
  elif [ -n "$_SHUNT_PROVIDERS_LOCK_DIR" ]; then
    rmdir "$_SHUNT_PROVIDERS_LOCK_DIR" 2>/dev/null
    _shunt_guard_remove _SHUNT_PL
    _SHUNT_PROVIDERS_LOCK_DIR=""
  fi
}

# shunt_provider_field <provider> <jq path> <default>
# Prints a field of the provider, or the default when it is unset.
_shunt_provider_field() {
  local provider="$1" path="$2" default="$3"
  shunt_providers_validate || return 1
  [ -f "$SHUNT_PROVIDERS_FILE" ] || { printf '%s\n' "$default"; return 0; }
  jq -r --arg p "$provider" --arg d "$default" \
    ".providers[\$p] | ($path) // \$d" "$SHUNT_PROVIDERS_FILE"
}

shunt_provider_transport() { _shunt_provider_field "$1" '.transport' opencode; }
shunt_provider_base_url() { _shunt_provider_field "$1" '.base_url' ''; }
shunt_provider_key_type() { _shunt_provider_field "$1" '.key.type' none; }
_shunt_provider_key_ref() { _shunt_provider_field "$1" '.key.ref' ''; }

# shunt_provider_plaintext_warning
shunt_provider_plaintext_warning() {
  echo "shunt: warning: the key is stored in plain text in $SHUNT_PROVIDERS_FILE (mode 600). Prefer a keyring or an environment variable."
}

# shunt_is_wsl
shunt_is_wsl() {
  [ -r "$SHUNT_PROC_VERSION_FILE" ] && grep -qi microsoft "$SHUNT_PROC_VERSION_FILE"
}

# shunt_keyring_backend
# Prints the first usable backend (secret-tool, security, kwallet-query) or
# nothing. Under WSL there is no usable keyring, so nothing is printed.
shunt_keyring_backend() {
  shunt_is_wsl && return 0
  local tool
  for tool in secret-tool security kwallet-query; do
    if command -v "$tool" >/dev/null 2>&1; then
      echo "$tool"
      return 0
    fi
  done
}

# shunt_keyring_store <provider>
# Reads the key from stdin. secret-tool and kwallet-query take it on stdin.
# LIMITATION: macOS `security add-generic-password` has no stdin mode for the
# password (-w without a value prompts on the tty), so the key is briefly
# visible in that process's argv. Use an env-type key on macOS if that matters.
shunt_keyring_store() {
  local provider="$1" backend key
  backend=$(shunt_keyring_backend)
  [ -n "$backend" ] || { echo "shunt: no keyring backend available." >&2; return 1; }
  case "$backend" in
    secret-tool)
      secret-tool store --label="$SHUNT_KEYRING_SERVICE $provider" \
        service "$SHUNT_KEYRING_SERVICE" account "$provider" ;;
    kwallet-query)
      kwallet-query -f "$SHUNT_KEYRING_SERVICE" -w "$provider" "$SHUNT_KWALLET_WALLET" >/dev/null ;;
    security)
      IFS= read -r key || true
      security add-generic-password -U -s "$SHUNT_KEYRING_SERVICE/$provider" \
        -a "$SHUNT_KEYRING_SERVICE" -w "$key" >/dev/null ;;
  esac || { echo "shunt: storing the key in $backend failed." >&2; return 1; }
}

# shunt_keyring_get <provider>
# Prints the stored key, or returns 1 when there is none.
shunt_keyring_get() {
  local provider="$1" backend key=""
  backend=$(shunt_keyring_backend)
  [ -n "$backend" ] || return 1
  case "$backend" in
    secret-tool) key=$(secret-tool lookup service "$SHUNT_KEYRING_SERVICE" account "$provider" 2>/dev/null) ;;
    security) key=$(security find-generic-password -s "$SHUNT_KEYRING_SERVICE/$provider" -w 2>/dev/null) ;;
    kwallet-query) key=$(kwallet-query -f "$SHUNT_KEYRING_SERVICE" -r "$provider" "$SHUNT_KWALLET_WALLET" 2>/dev/null) ;;
  esac || true
  [ -n "$key" ] || return 1
  printf '%s\n' "$key"
}

# shunt_provider_key_resolve <provider>
# Prints the key (nothing for type none). Capture it into a variable, never
# into a log. Errors name the source but never a value.
shunt_provider_key_resolve() {
  local provider="$1" type ref
  type=$(shunt_provider_key_type "$provider") || return 1
  case "$type" in
    none) return 0 ;;
    env)
      ref=$(_shunt_provider_key_ref "$provider") || return 1
      [[ "$ref" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
        || { echo "shunt: provider '$provider': key ref is not a valid environment variable name." >&2; return 1; }
      [ -n "${!ref:-}" ] \
        || { echo "shunt: provider '$provider': environment variable $ref is unset or empty." >&2; return 1; }
      printf '%s\n' "${!ref}" ;;
    plaintext)
      ref=$(_shunt_provider_key_ref "$provider") || return 1
      [ -n "$ref" ] || { echo "shunt: provider '$provider': no plaintext key stored. Run: shunt-models key set $provider" >&2; return 1; }
      printf '%s\n' "$ref" ;;
    keyring)
      shunt_keyring_get "$provider" \
        || { echo "shunt: provider '$provider': no key found in the keyring. Run: shunt-models key set $provider" >&2; return 1; } ;;
  esac
}

# shunt_provider_write_auth_header_file <provider>
# Writes `Authorization: Bearer <key>` to a 0600 temp file for curl -H @file
# and prints its path. The caller removes it. Type none creates no file and
# prints nothing (no Authorization header). A key with a line break is refused
# so it cannot smuggle extra headers. Returns 1 when the key cannot be resolved
# or is refused, 2 when the temp file cannot be created or written (an
# environment failure, not a config one). With <outvar> the path is stored in
# that variable (not printed) as soon as the file exists, before the key is
# written, so a caller's cleanup that removes the variable's file never misses it.
# Call it directly then, not in $(...).
shunt_provider_write_auth_header_file() {
  local provider="$1" outvar="${2:-}" key file
  key=$(shunt_provider_key_resolve "$provider") || return 1
  [ -n "$key" ] || return 0
  case "$key" in
    *$'\n'* | *$'\r'*) echo "shunt: provider '$provider': the key contains a line break." >&2; return 1 ;;
  esac
  if ! file=$(umask 077 && mktemp "${TMPDIR:-/tmp}/shunt-auth.XXXXXX" 2>/dev/null); then
    echo "shunt: provider '$provider': cannot create a temp file for the auth header in ${TMPDIR:-/tmp}." >&2
    return 2
  fi
  [ -z "$outvar" ] || printf -v "$outvar" '%s' "$file"
  if ! { chmod 600 "$file" && printf 'Authorization: Bearer %s\n' "$key" >"$file"; } 2>/dev/null; then
    rm -f "$file"
    echo "shunt: provider '$provider': cannot write the auth header file." >&2
    return 2
  fi
  [ -n "$outvar" ] || echo "$file"
}

# shunt_providers_write <json>
# Validates and atomically replaces providers.json, created with mode 600.
# Callers that read the file to build <json> hold shunt_providers_lock around
# the read and this write.
shunt_providers_write() {
  local json="$1" dir tmp
  dir=$(dirname "$SHUNT_PROVIDERS_FILE")
  mkdir -p "$dir"
  tmp=$(umask 077 && mktemp "$dir/.providers.json.XXXXXX") || return 1
  if ! printf '%s' "$json" | jq -e . >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "shunt: refusing to write an invalid providers file." >&2
    return 1
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$SHUNT_PROVIDERS_FILE"
}

# shunt_provider_plaintext_store <provider>
# Reads the key from stdin and stores it as the provider's plaintext ref. The
# key travels through the environment, not argv. Holds the providers lock and
# checks the key type inside it: a provider switched to env (or anything but
# plaintext) in the meantime is refused, so a key is never written as an env ref.
shunt_provider_plaintext_store() {
  local provider="$1" key updated type rc=0
  IFS= read -r key || true
  shunt_providers_lock || return 1
  if type=$(shunt_provider_key_type "$provider") && [ "$type" = plaintext ]; then
    if updated=$(SHUNT_KEY_VALUE="$key" jq -c --arg p "$provider" \
      '.providers[$p].key.ref = $ENV.SHUNT_KEY_VALUE' "$SHUNT_PROVIDERS_FILE"); then
      shunt_providers_write "$updated" || rc=1
    else
      rc=1
    fi
  else
    echo "shunt: provider '$provider' no longer has a plaintext key type, nothing stored." >&2
    rc=1
  fi
  shunt_providers_unlock
  return "$rc"
}

# Absolute, shell-quoted path of shunt-models for user-facing hints. Plugin users
# run from their own project, so a relative scripts/shunt-models would not resolve.
printf -v SHUNT_MODELS_HINT_CMD '%q' \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/shunt-models"
