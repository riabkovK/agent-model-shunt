# HTTP transport: one non-streaming POST to <base_url>/chat/completions of an
# OpenAI-compatible provider, normalized into the response format described in
# transport.sh. Meant to be sourced by transport.sh, which supplies the
# SHUNT_TRY_INVOKE_* statuses and SHUNT_TIMEOUT_SECONDS. Needs providers.sh and
# models.sh, and shunt_tmpfile from opencode.sh.
#
# Status mapping (curl -w '%{http_code}'):
#   curl exit 28                        TIMEOUT
#   other curl failure, 429, 5xx,
#   400/404/413 and any other non-2xx   ERROR (model failure, the breaker counts it)
#   401, 403                            AUTH (a key problem, not the model's fault:
#                                       the failover loop skips the breaker)
#   2xx, text empty                     EMPTY
#   2xx, finish_reason not "stop"       ERROR (an answer cut off, e.g. "length",
#                                       is unusable and another model may do better)
#   2xx, not a chat completion          ERROR
# Secret rules: the key only ever lives in a 0600 header file handed to curl as
# -H @file, never in argv or on stderr. Redirects are never followed (no -L), so
# the Authorization header cannot be replayed to another host.

SHUNT_HTTP_EXCERPT_CHARS=300
_SHUNT_HTTP_TMP=()

# _shunt_http_cleanup
# Removes every temp file the current call created, the auth header file first.
_shunt_http_cleanup() {
  local f
  for f in "${_SHUNT_HTTP_TMP[@]}"; do
    rm -f "$f"
  done
  _SHUNT_HTTP_TMP=()
}

# _shunt_http_new_tmp <varname>
# Creates a 0600 temp file, remembers it for cleanup and stores its path in the
# named variable. Not a command substitution, so the cleanup list survives.
_shunt_http_new_tmp() {
  local f
  f=$(umask 077 && mktemp "${TMPDIR:-/tmp}/shunt-http.XXXXXX") || return 1
  _SHUNT_HTTP_TMP+=("$f")
  printf -v "$1" '%s' "$f"
}

# _shunt_http_excerpt <file> <key>
# Prints a one-line excerpt of the file that is safe for stderr: control
# characters removed, the key value scrubbed, cut to SHUNT_HTTP_EXCERPT_CHARS.
_shunt_http_excerpt() {
  local s
  s=$(head -c 4000 "$1" | tr -d '[:cntrl:]')
  [ -z "$2" ] || s="${s//"$2"/[redacted]}"
  printf '%s' "${s:0:$SHUNT_HTTP_EXCERPT_CHARS}"
}

# _shunt_http_check_base_url <provider> <base_url> <outvar>
# Stores the URL to use in <outvar>. An explicit http:// or https:// is taken
# as written (http to any host is the user's informed choice). A base_url with
# no scheme gets https:// prepended and _SHUNT_HTTP_ASSUMED_HTTPS=1, so a failed
# connection can say so. Never falls back to http. Other schemes, userinfo,
# whitespace and control characters are refused.
_shunt_http_check_base_url() {
  local provider="$1" url="$2" rest authority
  _SHUNT_HTTP_ASSUMED_HTTPS=0
  case "$url" in
    https://*) rest="${url#https://}" ;;
    http://*) rest="${url#http://}" ;;
    *://*)
      echo "shunt: provider '$provider': base_url scheme must be http:// or https:// (config problem, no request sent)." >&2
      return 1
      ;;
    *)
      rest="$url"
      url="https://$url"
      _SHUNT_HTTP_ASSUMED_HTTPS=1
      ;;
  esac
  authority="${rest%%[/?#]*}"
  if [ -z "$authority" ] || [[ "$url" == *[[:space:][:cntrl:]]* ]] || [[ "$authority" == *@* ]]; then
    echo "shunt: provider '$provider': base_url is malformed or has credentials in it (config problem, no request sent)." >&2
    return 1
  fi
  printf -v "$3" '%s' "$url"
}

# The registry entry of the agent being called, resolved once per delegated call
# by _shunt_http_resolve and shared by the dispatcher (transport choice), the
# system prompt and the request body. Empty _SHUNT_HTTP_AGENT means unresolved.
_SHUNT_HTTP_AGENT="" _SHUNT_HTTP_ID="" _SHUNT_HTTP_ROLE="" _SHUNT_HTTP_REQUEST_BODY=""

# _shunt_http_clear
# Forgets the resolved entry so a later call reads the registry afresh.
_shunt_http_clear() {
  _SHUNT_HTTP_AGENT="" _SHUNT_HTTP_ID="" _SHUNT_HTTP_ROLE="" _SHUNT_HTTP_REQUEST_BODY=""
}

# _shunt_http_resolve <agent>
# One registry read: finds the model whose bulk-reader or code-writer agent is
# <agent> and sets _SHUNT_HTTP_ID, _SHUNT_HTTP_ROLE (bulk-reader|code-writer)
# and _SHUNT_HTTP_REQUEST_BODY (compact JSON, {} when unset). Must run in the
# current shell, not in $(...). Fails, leaving nothing resolved, when the
# registry is missing or has no such model.
_shunt_http_resolve() {
  local agent="$1" id a rb
  _shunt_http_clear
  shunt_models_available || return 1
  while IFS=$'\t' read -r id a rb; do
    if [ "$agent" = "$a" ]; then
      _SHUNT_HTTP_ROLE=bulk-reader
    elif [ "$agent" = "$(shunt_models_code_writer_agent_for "$id")" ]; then
      _SHUNT_HTTP_ROLE=code-writer
    else
      continue
    fi
    _SHUNT_HTTP_AGENT="$agent" _SHUNT_HTTP_ID="$id" _SHUNT_HTTP_REQUEST_BODY="$rb"
    return 0
  done < <(jq -r '.models[] | [.id, (.agent // ""), ((.request_body // {}) | tojson)] | @tsv' "$SHUNT_MODELS_FILE")
  return 1
}

# _shunt_http_system_prompt <role> <outvar>
# Stores the role prompt in <outvar>: prompts/code-writer.md or
# prompts/bulk-reader.md. The same files are the body of the materialized
# OpenCode agent files. A missing or unreadable file is a config problem
# (incomplete plugin install).
_shunt_http_system_prompt() {
  local role="$1" file
  file="$SHUNT_PROMPTS_DIR/$role.md"
  [ -f "$file" ] && [ -r "$file" ] \
    || { echo "shunt: the $role prompt is missing at $file (incomplete plugin install)." >&2; return 1; }
  printf -v "$2" '%s' "$(<"$file")"
}

# _shunt_http_build_prompt <outfile> <question> [file...]
# The question, then each attached file in a labelled block (the HTTP API has
# no equivalent of `opencode run -f`).
_shunt_http_build_prompt() {
  local out="$1" question="$2" f
  shift 2
  printf '%s\n' "$question" >"$out"
  for f in "$@"; do
    [ -f "$f" ] && [ -r "$f" ] || { echo "shunt: cannot read attached file '$f'." >&2; return 1; }
    { printf '\n--- file: %s ---\n' "$f"; cat -- "$f"; printf '\n--- end of file ---\n'; } >>"$out"
  done
}

# _shunt_http_normalize <response-file>
# Prints the normalized JSON of a chat completion, or returns 1 when the body
# has no choices[0]. cost is taken from usage.cost or cost, only when a number.
_shunt_http_normalize() {
  jq -e -c '
    select((.choices | type) == "array" and (.choices | length) > 0) |
    (.choices[0].message.content // "") as $c |
    ((.usage | objects) // null) as $u |
    {text: (if ($c | type) == "string" then $c else "" end),
     finish_reason: (.choices[0].finish_reason // "")}
    + (if $u == null then {} else
        {usage: {input: ($u.prompt_tokens // 0), output: ($u.completion_tokens // 0)}} end)
    + ((($u.cost // .cost) | if type == "number" then . else null end) as $cost
        | if $cost == null then {} else {cost: $cost} end)
  ' "$1" 2>/dev/null
}

# _shunt_http_call <agent> <question> [file...]
# The work of _shunt_transport_http. Temp files are registered for cleanup by
# the caller. Prints the normalized response file path on success.
_shunt_http_call() {
  local agent="$1" question="$2"
  shift 2
  local id provider base_url request_body
  # The dispatcher already resolved this agent. A direct caller has not.
  [ "$_SHUNT_HTTP_AGENT" = "$agent" ] || _shunt_http_resolve "$agent" \
    || { echo "shunt: no model in the registry for agent '$agent'." >&2; return 1; }
  id="$_SHUNT_HTTP_ID" request_body="$_SHUNT_HTTP_REQUEST_BODY"
  provider="${id%%/*}"
  base_url=$(shunt_provider_base_url "$provider") || return 1
  _shunt_http_check_base_url "$provider" "$base_url" base_url || return 1
  jq -e 'type == "object"' <<<"$request_body" >/dev/null 2>&1 \
    || { echo "shunt: model '$id': request_body must be a JSON object." >&2; return 1; }

  local system_prompt prompt_file body_file resp_file err_file hdr="" key="" hdr_args=()
  _shunt_http_system_prompt "$_SHUNT_HTTP_ROLE" system_prompt || return 1
  _shunt_http_new_tmp prompt_file && _shunt_http_new_tmp body_file \
    && _shunt_http_new_tmp resp_file && _shunt_http_new_tmp err_file || return 1
  _shunt_http_build_prompt "$prompt_file" "$question" "$@" || return 1
  # The registered request_body goes first so it can never replace model or messages.
  jq -n -c --arg model "${id#*/}" --rawfile prompt "$prompt_file" --arg system "$system_prompt" --argjson rb "$request_body" \
    '$rb + {model: $model, messages: [{role: "system", content: $system}, {role: "user", content: $prompt}]}' >"$body_file" || return 1

  hdr=$(shunt_provider_write_auth_header_file "$provider") || return 1
  if [ -n "$hdr" ]; then
    _SHUNT_HTTP_TMP+=("$hdr")
    key=$(<"$hdr")
    key="${key#Authorization: Bearer }"
    hdr_args=(-H "@$hdr")
  fi

  local http_code curl_status=0
  http_code=$(curl -q -sS --globoff --max-time "$SHUNT_TIMEOUT_SECONDS" --proto '=http,https' \
    -H 'Content-Type: application/json' "${hdr_args[@]}" \
    --data-binary "@$body_file" -o "$resp_file" -w '%{http_code}' \
    "${base_url%/}/chat/completions" 2>"$err_file" </dev/null) || curl_status=$?

  if [ "$curl_status" -eq 28 ]; then
    return "$SHUNT_TRY_INVOKE_TIMEOUT"
  elif [ "$curl_status" -ne 0 ]; then
    echo "shunt: request to provider '$provider' failed (curl exit $curl_status): $(_shunt_http_excerpt "$err_file" "$key")" >&2
    if [ "${_SHUNT_HTTP_ASSUMED_HTTPS:-0}" = 1 ]; then
      echo "shunt: provider '$provider': cannot reach $base_url (no scheme in base_url, https was assumed; write http://... explicitly for a plain http endpoint)." >&2
    fi
    return "$SHUNT_TRY_INVOKE_ERROR"
  fi

  case "$http_code" in
    2??) ;;
    401 | 403)
      echo "shunt: auth failed for provider $provider, check key via model-config" >&2
      return "$SHUNT_TRY_INVOKE_AUTH"
      ;;
    400 | 404 | 413)
      echo "shunt: provider '$provider' answered HTTP $http_code: $(_shunt_http_excerpt "$resp_file" "$key")" >&2
      return "$SHUNT_TRY_INVOKE_ERROR"
      ;;
    *)
      echo "shunt: provider '$provider' answered HTTP ${http_code//[^0-9]/}." >&2
      return "$SHUNT_TRY_INVOKE_ERROR"
      ;;
  esac

  local out
  out=$(shunt_tmpfile) || return 1
  if ! _shunt_http_normalize "$resp_file" >"$out"; then
    rm -f "$out"
    echo "shunt: provider '$provider' sent a reply that is not a chat completion." >&2
    return "$SHUNT_TRY_INVOKE_ERROR"
  fi
  local finish
  finish=$(jq -r '.finish_reason' "$out")
  if [ -n "$finish" ] && [ "$finish" != "stop" ]; then
    rm -f "$out"
    echo "shunt: provider '$provider' ended the answer with finish_reason '$(printf '%s' "$finish" | tr -d '[:cntrl:]' | head -c 40)'." >&2
    return "$SHUNT_TRY_INVOKE_ERROR"
  fi
  if [ -z "$(jq -r '.text' "$out")" ]; then
    rm -f "$out"
    return "$SHUNT_TRY_INVOKE_EMPTY"
  fi
  echo "$out"
}

# _shunt_transport_http <agent> <question> [file...]
# Prints the path to a temp file holding the normalized response. Never exits
# the process: returns a SHUNT_TRY_INVOKE_* status (or 1 for a config problem
# already explained on stderr). The temp files, the auth header file included,
# are removed on every exit path, INT and TERM too. The caller's INT and TERM
# traps are restored afterwards.
_shunt_transport_http() {
  local saved_int saved_term saved_hup status=0
  saved_int=$(trap -p INT)
  saved_term=$(trap -p TERM)
  saved_hup=$(trap -p HUP)
  _SHUNT_HTTP_TMP=()
  trap '_shunt_http_cleanup; exit 130' INT
  trap '_shunt_http_cleanup; exit 143' TERM
  trap '_shunt_http_cleanup; exit 129' HUP

  _shunt_http_call "$@" || status=$?

  _shunt_http_clear
  _shunt_http_cleanup
  if [ -n "$saved_int" ]; then eval "$saved_int"; else trap - INT; fi
  if [ -n "$saved_term" ]; then eval "$saved_term"; else trap - TERM; fi
  if [ -n "$saved_hup" ]; then eval "$saved_hup"; else trap - HUP; fi
  return "$status"
}
