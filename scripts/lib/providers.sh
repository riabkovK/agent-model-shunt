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
#
# The read side (validation, listing, field getters, base_url check), the
# keyring and the key resolution live in scripts/py/shunt/providers.py. The
# functions here are thin wrappers around `shunt_py providers <subcommand>` with
# the old names, stdout, stderr and exit codes, and each call that reaches Python
# costs one interpreter start. The writers of providers.json
# (shunt_provider_plaintext_store, provider set) are in
# scripts/py/shunt/providers_write.py. Python takes the providers lock itself
# (scripts/py/shunt/lockfile.py is the only lock implementation) for a
# read-modify-write. The read side never takes the lock.

# shellcheck source=py.sh
source "${BASH_SOURCE[0]%/*}/py.sh"

SHUNT_PROVIDERS_FILE="${SHUNT_PROVIDERS_FILE:-$HOME/.config/agent-model-shunt/providers.json}"
SHUNT_PROC_VERSION_FILE="${SHUNT_PROC_VERSION_FILE:-/proc/version}"
# The two lists below must match TRANSPORTS and KEY_TYPES in scripts/py/shunt/providers.py.
# shellcheck disable=SC2034 # read by scripts/shunt-models and scripts/lib/migrate.sh
SHUNT_PROVIDER_TRANSPORTS="http opencode"
# shellcheck disable=SC2034 # read by scripts/shunt-models and scripts/lib/migrate.sh
SHUNT_PROVIDER_KEY_TYPES="keyring env plaintext none"
# The one provider name charset. Names reach shell hints the user copies.
# Two spellings of it exist on purpose: bash ERE has no \A and \z and its $ only
# matches at the very end, while Oniguruma (jq) lets $ match before a final
# newline, so "ok\n" would pass there. The jq form is anchored with \A and \z.
SHUNT_PROVIDER_NAME_REGEX='^[A-Za-z0-9][A-Za-z0-9._-]*$'
# shellcheck disable=SC2034 # read by scripts/lib/migrate.sh
SHUNT_PROVIDER_NAME_REGEX_JQ='\A[A-Za-z0-9][A-Za-z0-9._-]*\z'

# shunt_provider_name_ok <name>
shunt_provider_name_ok() { [[ "$1" =~ $SHUNT_PROVIDER_NAME_REGEX ]]; }

# shunt_word_in_list <word> <space separated list>
# Succeeds when <word> equals one whole entry of the list.
shunt_word_in_list() {
  local w
  for w in $2; do
    [ "$w" != "$1" ] || return 0
  done
  return 1
}

# shunt_provider_name_refuse <name>
# Explains on stderr why the name is refused. When providers.json already holds
# an entry under that name, says so and what to do. The name is shown through
# jq tojson, so it is quoted and has no raw control characters.
shunt_provider_name_refuse() {
  local q
  if [ -f "$SHUNT_PROVIDERS_FILE" ] \
    && jq -e --arg p "$1" '.providers[$p] != null' "$SHUNT_PROVIDERS_FILE" >/dev/null 2>&1; then
    q=$(jq -rn --arg p "$1" '$p | tojson')
    echo "shunt: invalid provider name: $SHUNT_PROVIDERS_FILE has an entry named $q, which uses characters other than letters, digits, dot, dash and underscore (or does not start with a letter or digit). Please edit providers.json to remove or rename that entry." >&2
  else
    echo "shunt: invalid provider name (use letters, digits, dot, dash, underscore)." >&2
  fi
}

SHUNT_PROVIDERS_LOCK_TIMEOUT="${SHUNT_PROVIDERS_LOCK_TIMEOUT:-10}"

# _shunt_providers_py <subcommand> [args...]
# Runs a providers subcommand with the paths this file resolved, exported only
# for the call (the variables may be unexported shell defaults). The API key
# never goes through here: env-type keys are read by Python from the exported
# environment, the others from providers.json or the keyring.
_shunt_providers_py() {
  SHUNT_PROVIDERS_FILE="$SHUNT_PROVIDERS_FILE" SHUNT_PROC_VERSION_FILE="$SHUNT_PROC_VERSION_FILE" \
    shunt_py providers "$@"
}

# shunt_providers_validate
# Returns 0 when the file is absent or valid. Otherwise explains on stderr.
# Never takes the providers lock, so callers may hold it.
shunt_providers_validate() {
  [ -f "$SHUNT_PROVIDERS_FILE" ] || return 0
  _shunt_providers_py validate
}

# shunt_providers_list_lines
# Prints one tab-separated line per provider: name, transport, base_url and
# key type (env:<VAR> for env keys). An invalid entry gets "invalid: <reason>"
# instead, so one bad entry does not hide the others. Never prints a key value.
shunt_providers_list_lines() {
  _shunt_providers_py list-lines
}

# shunt_base_url_check <url>
# The one base_url validator, shared by `provider set` and the HTTP transport.
# Returns 0 for a usable URL, 2 for a scheme other than http:// or https://,
# 3 for no scheme at all, 1 when it is malformed: empty host, userinfo
# (user:pass@), whitespace or control characters. Never prints the URL.
# An unusable interpreter also surfaces as a non-zero status (127, 126 or 2).
shunt_base_url_check() {
  _shunt_providers_py base-url-check -- "$1"
}

# shunt_provider_transport / base_url / key_type <provider>
# Print a field of the provider, or the default when it is unset (opencode,
# empty, none). Validate the whole file first and fail with its message.
shunt_provider_transport() { _shunt_providers_py field transport -- "$1"; }
shunt_provider_base_url() { _shunt_providers_py field base-url -- "$1"; }
shunt_provider_key_type() { _shunt_providers_py field key-type -- "$1"; }
_shunt_provider_key_ref() { _shunt_providers_py field key-ref -- "$1"; }

# shunt_provider_plaintext_warning
shunt_provider_plaintext_warning() {
  echo "shunt: warning: the key is stored in plain text in $SHUNT_PROVIDERS_FILE (mode 600). Prefer a keyring or an environment variable."
}

# shunt_keyring_backend
# Prints the first usable backend (secret-tool, security, kwallet-query) or
# nothing. Under WSL there is no usable keyring, so nothing is printed.
shunt_keyring_backend() {
  _shunt_providers_py keyring-backend
}

# shunt_keyring_store <provider>
# Reads the key from stdin. secret-tool and kwallet-query take it on stdin.
# LIMITATION: macOS `security add-generic-password` has no stdin mode for the
# password (-w without a value prompts on the tty), so the key is briefly
# visible in that process's argv. Use an env-type key on macOS if that matters.
shunt_keyring_store() {
  _shunt_providers_py keyring-store -- "$1"
}

# shunt_keyring_get <provider>
# Prints the stored key, or returns 1 when there is none.
shunt_keyring_get() {
  _shunt_providers_py keyring-get -- "$1"
}

# shunt_provider_key_resolve <provider>
# Prints the key (nothing for type none). Capture it into a variable, never
# into a log. Errors name the source but never a value. An env-type key must be
# exported: Python reads the environment, not unexported shell variables.
shunt_provider_key_resolve() {
  _shunt_providers_py key-resolve -- "$1"
}

# shunt_provider_write_auth_header_file <provider> [<outvar>]
# Writes `Authorization: Bearer <key>` to a 0600 temp file for curl -H @file
# and prints its path. The caller removes it. Type none creates no file and
# prints nothing (no Authorization header). A key with a line break is refused
# so it cannot smuggle extra headers. Returns 1 when the key cannot be resolved
# or is refused, 2 when the temp file cannot be created or written (an
# environment failure, not a config one). With <outvar> the path is stored in
# that variable instead of being printed. Call it directly then, not in $(...).
# The file is created by Python (O_EXCL, 0600) and its path reaches the variable
# when Python exits, so a signal in that short window can leave the file behind.
shunt_provider_write_auth_header_file() {
  local provider="$1" outvar="${2:-}" file rc=0
  file=$(_shunt_providers_py auth-header-file -- "$provider") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -n "$file" ] || return 0
  if [ -n "$outvar" ]; then printf -v "$outvar" '%s' "$file"; else echo "$file"; fi
}

# _shunt_providers_write_py <subcommand> [args...]
# Runs a providers-write subcommand with the paths this file resolved. The lock
# timeout is passed too.
_shunt_providers_write_py() {
  local sub="$1"
  shift
  SHUNT_PROVIDERS_FILE="$SHUNT_PROVIDERS_FILE" SHUNT_PROVIDERS_LOCK_TIMEOUT="$SHUNT_PROVIDERS_LOCK_TIMEOUT" \
    shunt_py providers-write "$sub" "$@"
}

# shunt_provider_plaintext_store <provider>
# Reads the key from stdin and stores it as the provider's plaintext ref. The
# key stays on stdin (never argv or the environment). Python holds the providers
# lock and checks the key type inside it: a provider switched to env (or
# anything but plaintext) in the meantime is refused, so a key is never written
# as an env ref.
shunt_provider_plaintext_store() {
  _shunt_providers_write_py plaintext-store -- "$1"
}

# Absolute, shell-quoted path of shunt-models for user-facing hints. Plugin users
# run from their own project, so a relative scripts/shunt-models would not resolve.
printf -v SHUNT_MODELS_HINT_CMD '%q' \
  "$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/shunt-models"
