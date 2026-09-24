# Context window auto-detection for models of an HTTP-transport provider.
# Meant to be sourced by scripts/shunt-models after opencode.sh (which brings
# providers.sh and transport-http.sh: base_url check and key lookup).
#
# Only what the provider itself reports is used, a number is never guessed
# from built-in knowledge. Sources, in order:
#   1. GET <base_url>/models/<model>
#   2. GET <base_url>/models, the entry whose id is <model>
#   3. Ollama: POST <base_url without /v1>/api/show. The runtime window is
#      `num_ctx` in the `parameters` text, preferred because it is what the
#      server really allows. A model_info key ending in .context_length is only
#      the architecture maximum, used when num_ctx is not set.
# Every failure (network, non-2xx, bad JSON) just means "not found". The key
# only ever lives in a 0600 header file handed to curl as -H @file.

SHUNT_DETECT_TIMEOUT_SECONDS="${SHUNT_DETECT_TIMEOUT_SECONDS:-15}"
# Fields of a /models entry that carry the context window, first present wins.
SHUNT_DETECT_FIELDS=(context_length max_model_len context_window max_context_length max_input_tokens)
# Model names outside this alphabet are not put into a URL.
SHUNT_DETECT_MODEL_PATTERN='^[A-Za-z0-9._:@+/-]+$'
_SHUNT_DETECT_TMP=()

# _shunt_detect_cleanup
# Removes the temp files of the current detection, the auth header first.
_shunt_detect_cleanup() {
  local f
  for f in "${_SHUNT_DETECT_TMP[@]}"; do
    rm -f "$f"
  done
  _SHUNT_DETECT_TMP=()
}

# _shunt_detect_positive
# Reads JSON on stdin and a jq path expression yielding candidate values in
# $1, prints the first positive integer among them (nothing if none, or bad JSON).
_shunt_detect_positive() {
  jq -r "first(($1) | select(type == \"number\" and . > 0 and . == floor)) | tostring" 2>/dev/null
}

# _shunt_detect_fields_expr
# Prints the jq expression listing SHUNT_DETECT_FIELDS in order, e.g. `.a, .b`.
_shunt_detect_fields_expr() {
  local f expr=""
  for f in "${SHUNT_DETECT_FIELDS[@]}"; do
    expr+="${expr:+, }.$f"
  done
  printf '%s' "(objects | $expr)"
}

# _shunt_detect_get <url> <out-file> [<post-body>]
# One request (POST when a body is given). Succeeds only on a 2xx answer, whose
# body is then in <out-file>.
_shunt_detect_get() {
  local url="$1" out="$2" body="${3:-}" code
  local method=(-X GET)
  [ -z "$body" ] || method=(-X POST -H 'Content-Type: application/json' --data-binary "$body")
  code=$(curl -q -sS --globoff --max-time "$SHUNT_DETECT_TIMEOUT_SECONDS" --proto '=http,https' \
    "${method[@]}" "${_SHUNT_DETECT_HDR_ARGS[@]}" -o "$out" -w '%{http_code}' "$url" 2>/dev/null </dev/null) \
    || return 1
  case "$code" in 2??) return 0 ;; *) return 1 ;; esac
}

# _shunt_detect_run <model-id> <resp-file>
# Tries every source, prints the first value found. Returns 1 when none has one.
_shunt_detect_run() {
  local id="$1" resp="$2" provider="${1%%/*}" model="${1#*/}" base hdr value fields
  local api_base body
  [[ "$model" =~ $SHUNT_DETECT_MODEL_PATTERN ]] || return 1
  # No dot segments or empty path parts: curl would normalize them into another path.
  case "/$model/" in */../* | */./* | *//*) return 1 ;; esac
  base=$(shunt_provider_base_url "$provider") || return 1
  _shunt_http_check_base_url "$provider" "$base" base || return 1
  base="${base%/}"
  hdr=$(shunt_provider_write_auth_header_file "$provider") || return 1
  _SHUNT_DETECT_HDR_ARGS=()
  if [ -n "$hdr" ]; then
    _SHUNT_DETECT_TMP+=("$hdr")
    _SHUNT_DETECT_HDR_ARGS=(-H "@$hdr")
  fi
  fields=$(_shunt_detect_fields_expr)

  if _shunt_detect_get "$base/models/$model" "$resp"; then
    value=$(_shunt_detect_positive "$fields" <"$resp")
    [ -z "$value" ] || { echo "$value"; return 0; }
  fi
  if _shunt_detect_get "$base/models" "$resp"; then
    value=$(jq -c --arg id "$model" '[(.data // .models // .)[]? | objects | select(.id == $id)] | first // empty' "$resp" 2>/dev/null \
      | _shunt_detect_positive "$fields")
    [ -z "$value" ] || { echo "$value"; return 0; }
  fi
  api_base="${base%/v1}"
  body=$(jq -n -c --arg m "$model" '{model: $m}')
  if _shunt_detect_get "$api_base/api/show" "$resp" "$body"; then
    value=$(jq -r '(.parameters | strings | [scan("(?:^|\\n)num_ctx[ \\t]+([0-9]+)")[0] | tonumber | select(. > 0)] | first) // empty' "$resp" 2>/dev/null)
    [ -z "$value" ] || { echo "$value"; return 0; }
    value=$(jq -r '[.model_info | objects | to_entries[] | select(.key | endswith(".context_length")) | .value
      | select(type == "number" and . > 0 and . == floor)] | first // empty' "$resp" 2>/dev/null)
    [ -z "$value" ] || { echo "$value"; return 0; }
  fi
  return 1
}

# shunt_models_detect_context <provider/model>
# Prints the context window in tokens as reported by the provider, or fails
# with status 1 and prints nothing on stdout when it cannot find one.
shunt_models_detect_context() {
  local resp status=0
  _SHUNT_DETECT_TMP=()
  resp=$(umask 077 && mktemp "${TMPDIR:-/tmp}/shunt-detect.XXXXXX") || return 1
  _SHUNT_DETECT_TMP+=("$resp")
  _shunt_detect_run "$1" "$resp" || status=1
  _shunt_detect_cleanup
  return "$status"
}
