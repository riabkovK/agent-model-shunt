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

# shunt_providers_validate
# Returns 0 when the file is absent or valid. Otherwise explains on stderr.
shunt_providers_validate() {
  [ -f "$SHUNT_PROVIDERS_FILE" ] || return 0
  if ! jq -e '(.providers | type) == "object"' "$SHUNT_PROVIDERS_FILE" >/dev/null 2>&1; then
    echo "shunt: $SHUNT_PROVIDERS_FILE is invalid JSON or has no \"providers\" object." >&2
    return 1
  fi
  local bad
  bad=$(jq -r --arg ts "$SHUNT_PROVIDER_TRANSPORTS" --arg kt "$SHUNT_PROVIDER_KEY_TYPES" '
    ($ts | split(" ")) as $transports | ($kt | split(" ")) as $types |
    .providers | to_entries[] |
    if (.value.transport // "opencode") as $t | ($transports | index($t)) == null
      then "provider \"\(.key)\": unknown transport \"\(.value.transport)\" (allowed: \($ts))"
    elif (.value.key.type // "none") as $t | ($types | index($t)) == null
      then "provider \"\(.key)\": unknown key type \"\(.value.key.type)\" (allowed: \($kt))"
    else empty end' "$SHUNT_PROVIDERS_FILE" 2>/dev/null | head -n 1)
  if [ -n "$bad" ]; then
    echo "shunt: $SHUNT_PROVIDERS_FILE: $bad" >&2
    return 1
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
      IFS= read -r key
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
# so it cannot smuggle extra headers.
shunt_provider_write_auth_header_file() {
  local provider="$1" key file
  key=$(shunt_provider_key_resolve "$provider") || return 1
  [ -n "$key" ] || return 0
  case "$key" in
    *$'\n'* | *$'\r'*) echo "shunt: provider '$provider': the key contains a line break." >&2; return 1 ;;
  esac
  file=$(umask 077 && mktemp "${TMPDIR:-/tmp}/shunt-auth.XXXXXX") || return 1
  chmod 600 "$file"
  printf 'Authorization: Bearer %s\n' "$key" >"$file"
  echo "$file"
}

# shunt_providers_write <json>
# Validates and atomically replaces providers.json, created with mode 600.
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
# key travels through the environment, not argv.
shunt_provider_plaintext_store() {
  local provider="$1" key updated
  IFS= read -r key
  updated=$(SHUNT_KEY_VALUE="$key" jq -c --arg p "$provider" \
    '.providers[$p].key.ref = $ENV.SHUNT_KEY_VALUE' "$SHUNT_PROVIDERS_FILE") || return 1
  shunt_providers_write "$updated"
}
