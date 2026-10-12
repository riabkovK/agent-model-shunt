# HTTP transport: one non-streaming POST to <base_url>/chat/completions of an
# OpenAI-compatible provider, normalized into the response format described in
# transport.sh. Meant to be sourced by transport.sh, which supplies the
# SHUNT_TRY_INVOKE_* statuses and SHUNT_TIMEOUT_SECONDS. Needs providers.sh and
# models.sh, and shunt_tmpfile from opencode.sh.
#
# Status mapping (curl -w '%{http_code}'):
#   curl exit 28                        TIMEOUT, or DEADLINE when the request's
#                                       max-time was cut to the total deadline
#   total deadline already passed       DEADLINE (nothing sent)
#   other curl failure, 429, 5xx,
#   400/404/413 and any other non-2xx   ERROR (model failure, the breaker counts it)
#   401, 403                            AUTH (a key problem, not the model's fault:
#                                       the failover loop skips the breaker)
#   2xx, text empty                     EMPTY
#   2xx, finish_reason not "stop"       ERROR (an answer cut off, e.g. "length",
#                                       is unusable and another model may do better)
#   2xx, not a chat completion          ERROR
#   input over the context budget       OVERSIZE (nothing sent, not the model's
#                                       fault: the failover loop skips the breaker)
#   missing key, bad base_url, request_body,
#   oversize policy, total timeout, no
#   context_tokens, missing role prompt CONFIG (nothing sent, the failover loop
#                                       explains it and skips the breaker)
# Secret rules: the key only ever lives in a 0600 header file handed to curl as
# -H @file, never in argv or on stderr. Redirects are never followed (no -L), so
# the Authorization header cannot be replayed to another host.

SHUNT_HTTP_EXCERPT_CHARS=300
# Largest reply body accepted, in bytes (default 16 MiB). curl stops at this size
# when the server sends a Content-Length. Without one, --max-filesize also stops
# a chunked transfer only on curl >= 8.4.0. On older curl the size check after the
# download plus the --max-time deadline bound it instead.
SHUNT_HTTP_MAX_RESPONSE_BYTES_DEFAULT=16777216
SHUNT_HTTP_CURL_TOO_LARGE=63

# _shunt_http_max_response_bytes
# Prints the cap: SHUNT_HTTP_MAX_RESPONSE_BYTES when it is a positive integer.
_shunt_http_max_response_bytes() {
  local v="${SHUNT_HTTP_MAX_RESPONSE_BYTES:-}"
  [[ "$v" =~ ^[1-9][0-9]{0,14}$ ]] || v=$SHUNT_HTTP_MAX_RESPONSE_BYTES_DEFAULT
  printf '%s' "$v"
}

# _shunt_http_too_large <file>
# Succeeds when the file is bigger than the response cap.
_shunt_http_too_large() {
  local size
  size=$(wc -c <"$1" 2>/dev/null) || return 1
  [ "${size//[^0-9]/}" -gt "$(_shunt_http_max_response_bytes)" ]
}
# Oversize guard: tokens are estimated as ceil(bytes / SHUNT_HTTP_BYTES_PER_TOKEN)
# and must fit in SHUNT_HTTP_CONTEXT_BUDGET_PERCENT of the model's context_tokens.
# A model without context_tokens is only trusted with requests up to
# SHUNT_HTTP_UNKNOWN_CONTEXT_MAX_TOKENS.
SHUNT_HTTP_BYTES_PER_TOKEN=3
SHUNT_HTTP_CONTEXT_BUDGET_PERCENT=60
SHUNT_HTTP_UNKNOWN_CONTEXT_MAX_TOKENS=4000
SHUNT_HTTP_MAX_CONTEXT_DIGITS=12
# What an absent oversize_policy means.
SHUNT_HTTP_DEFAULT_OVERSIZE_POLICY=map_reduce
# map_reduce chunking. Neighbouring chunks of a file share this many lines, and
# a chunk request carries at least SHUNT_HTTP_MIN_CHUNK_BYTES of file content.
# The framing of a chunk request (question, "part i of n" note, block markers)
# is measured per file, see _shunt_http_chunk_overhead. Partial answers are
# merged in at most SHUNT_HTTP_MAX_MERGE_DEPTH group rounds.
# SHUNT_HTTP_PARTIAL_RESERVE_BYTES is the marker overhead assumed per partial
# answer in a merge request.
SHUNT_HTTP_CHUNK_OVERLAP_LINES=20
SHUNT_HTTP_MIN_CHUNK_BYTES=200
SHUNT_HTTP_MAX_MERGE_DEPTH=3
# A call that would need more chunk requests than this fails before sending any.
SHUNT_HTTP_MAX_CHUNKS=100
SHUNT_HTTP_PARTIAL_RESERVE_BYTES=100
# Internal status of _shunt_http_guard_size, never returned to callers.
SHUNT_HTTP_NEEDS_CHUNKING=90
SHUNT_HTTP_MERGE_INSTRUCTION="The input was too large to send at once, so it was analysed in parts. Below are the partial answers to the question above, one per part. Neighbouring parts of one file share $SHUNT_HTTP_CHUNK_OVERLAP_LINES lines, so the same finding can appear twice. Combine them into one final answer to the question, without repeating duplicates."
_SHUNT_HTTP_TMP=()
# The auth header file, set by shunt_provider_write_auth_header_file before the
# key is written into it, so the cleanup cannot miss it.
_SHUNT_HTTP_HDR_FILE=""

_SHUNT_HTTP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=transport-http-deadline.sh
source "$_SHUNT_HTTP_LIB_DIR/transport-http-deadline.sh"
# shellcheck source=transport-http-chunking.sh
source "$_SHUNT_HTTP_LIB_DIR/transport-http-chunking.sh"

# _shunt_http_cleanup
# Removes every temp file the current call created, the auth header file first.
_shunt_http_cleanup() {
  local f
  [ -z "$_SHUNT_HTTP_HDR_FILE" ] || rm -f "$_SHUNT_HTTP_HDR_FILE"
  _SHUNT_HTTP_HDR_FILE=""
  for f in ${_SHUNT_HTTP_TMP[@]+"${_SHUNT_HTTP_TMP[@]}"}; do
    rm -f "$f"
  done
  _SHUNT_HTTP_TMP=()
}

# _shunt_http_new_tmp <varname>
# Creates a 0600 temp file, remembers it for cleanup and stores its path in the
# named variable. Not a command substitution, so the cleanup list survives.
# An environment failure (no temp file) is explained and returns ERROR.
_shunt_http_new_tmp() {
  local f
  f=$(umask 077 && mktemp "${TMPDIR:-/tmp}/shunt-http.XXXXXX" 2>/dev/null) \
    || { echo "shunt: cannot create a temp file in ${TMPDIR:-/tmp}." >&2; return "$SHUNT_TRY_INVOKE_ERROR"; }
  _SHUNT_HTTP_TMP+=("$f")
  printf -v "$1" '%s' "$f"
}

# _shunt_http_ascii_json_forms <text>
# Prints the text as a JSON string body in two spellings, lower case hex only:
# non-ASCII characters as \uxxxx (surrogate pairs above U+FFFF), and then every
# character as \uxxxx (ASCII and control characters too).
_shunt_http_ascii_json_forms() {
  local all
  for all in false true; do
    printf '%s' "$1" | jq -Rrsj --argjson all "$all" '
      def hex4: [(./4096|floor)%16, (./256|floor)%16, (./16|floor)%16, .%16]
        | map("0123456789abcdef"[.:.+1]) | join("");
      def esc: if . < 128 and ($all | not) then ([.] | implode | tojson | .[1:-1])
        elif . < 65536 then "\\u" + hex4
        else (. - 65536) as $c | (55296 + ($c/1024|floor)) as $h | (56320 + ($c%1024)) as $l
          | "\\u" + ($h|hex4) + "\\u" + ($l|hex4) end;
      explode | map(esc) | join("") | ., "\n"' 2>/dev/null || true
  done
}

# _shunt_http_lower_u_escapes
# Filter: lower-cases the hex digits of every \uXXXX escape, so one spelling is
# enough when matching. Plain awk (no GNU sed \L), safe for mawk and BusyBox.
_shunt_http_lower_u_escapes() {
  awk '{
    out = ""; line = $0
    while (match(line, /\\u[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/)) {
      out = out substr(line, 1, RSTART - 1) tolower(substr(line, RSTART, RLENGTH))
      line = substr(line, RSTART + RLENGTH)
    }
    print out line
  }'
}

# _shunt_http_excerpt <file> <key>
# Prints a one-line excerpt of the file that is safe for stderr: control
# characters removed, every spelling of the whole key value scrubbed (see
# below), cut to SHUNT_HTTP_EXCERPT_CHARS. Only the complete key is matched, a
# fragment of it is not redacted.
_shunt_http_excerpt() {
  local s key="$2" rawkey="$2" raw_escaped escaped form
  s=$(head -c 4000 "$1" | tr -d '[:cntrl:]' | _shunt_http_lower_u_escapes)
  if [ -n "$key" ]; then
    # The key as it may be echoed: as is, and in the form jq writes it into a JSON
    # string, plus the "\/" spelling some servers use for a slash. The body had its
    # control characters stripped, so the key is stripped the same way for the plain
    # forms. The JSON form with control characters escaped (\t, \n) comes from the
    # unstripped key.
    raw_escaped=$(printf '%s' "$rawkey" | jq -Rsrj 'tojson | .[1:-1]' 2>/dev/null) || raw_escaped=""
    key=$(printf '%s' "$key" | tr -d '[:cntrl:]')
    escaped=$(jq -Rrj 'tojson | .[1:-1]' <<<"$key" 2>/dev/null) || escaped=""
    [ -z "$key" ] || s="${s//"$key"/[redacted]}"
    [ -z "$raw_escaped" ] || s="${s//"$raw_escaped"/[redacted]}"
    [ -z "$escaped" ] || s="${s//"$escaped"/[redacted]}"
    [ -z "$escaped" ] || s="${s//"${escaped//\//\\\/}"/[redacted]}"
    # The \uxxxx forms (non-ASCII only, and every character), lower case hex.
    while IFS= read -r form; do
      [ -z "$form" ] || s="${s//"$form"/[redacted]}"
    done < <(_shunt_http_ascii_json_forms "$key")
    # Same for the unstripped key, whose control characters become \u0009 and so on.
    while IFS= read -r form; do
      [ -z "$form" ] || s="${s//"$form"/[redacted]}"
    done < <(_shunt_http_ascii_json_forms "$rawkey")
  fi
  printf '%s' "${s:0:$SHUNT_HTTP_EXCERPT_CHARS}"
}

# Absolute path of shunt-models for hints. Hooks run with the user's project as
# the working directory, so a relative scripts/shunt-models would not resolve.
# Shell-quoted so a plugin root with spaces still pastes as one word.
printf -v _SHUNT_HTTP_MODELS_CMD '%q' \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/shunt-models"

# _shunt_http_check_base_url <provider> <base_url> <outvar>
# Stores the URL to use in <outvar>. An explicit http:// or https:// is taken
# as written (http to any host is the user's informed choice). A base_url with
# no scheme gets https:// prepended and _SHUNT_HTTP_ASSUMED_HTTPS=1, so a failed
# connection can say so. Never falls back to http. Other schemes, userinfo,
# whitespace and control characters are refused.
_shunt_http_check_base_url() {
  local provider="$1" url="$2" rc=0
  _SHUNT_HTTP_ASSUMED_HTTPS=0
  shunt_base_url_check "$url" || rc=$?
  case "$rc" in
    0) ;;
    3)
      url="https://$url"
      _SHUNT_HTTP_ASSUMED_HTTPS=1
      ;;
    2)
      echo "shunt: provider '$provider': base_url scheme must be http:// or https:// (config problem, no request sent)." >&2
      return "$SHUNT_TRY_INVOKE_CONFIG"
      ;;
    *)
      echo "shunt: provider '$provider': base_url is malformed or has credentials in it (config problem, no request sent)." >&2
      return "$SHUNT_TRY_INVOKE_CONFIG"
      ;;
  esac
  printf -v "$3" '%s' "$url"
}

# The registry entry of the agent being called, resolved once per delegated call
# by _shunt_http_resolve and shared by the dispatcher (transport choice), the
# system prompt and the request body. Empty _SHUNT_HTTP_AGENT means unresolved.
_SHUNT_HTTP_AGENT="" _SHUNT_HTTP_ID="" _SHUNT_HTTP_ROLE="" _SHUNT_HTTP_REQUEST_BODY=""
# Optional registry fields of the same entry, empty when absent.
_SHUNT_HTTP_CONTEXT_TOKENS="" _SHUNT_HTTP_OVERSIZE_POLICY="" _SHUNT_HTTP_ROLE_REQUEST_BODY=""
# The thinking options of the current mode (thinking_options when thinking is
# true, thinking_off_options otherwise) as compact JSON, and that field's name.
_SHUNT_HTTP_THINKING_BODY="" _SHUNT_HTTP_THINKING_FIELD=""

# _shunt_http_clear
# Forgets the resolved entry so a later call reads the registry afresh.
_shunt_http_clear() {
  _SHUNT_HTTP_AGENT="" _SHUNT_HTTP_ID="" _SHUNT_HTTP_ROLE="" _SHUNT_HTTP_REQUEST_BODY=""
  _SHUNT_HTTP_CONTEXT_TOKENS="" _SHUNT_HTTP_OVERSIZE_POLICY="" _SHUNT_HTTP_ROLE_REQUEST_BODY=""
  _SHUNT_HTTP_THINKING_BODY="" _SHUNT_HTTP_THINKING_FIELD=""
  _SHUNT_HTTP_KEY="" _SHUNT_HTTP_HDR_ARGS=() _SHUNT_HTTP_AUTH_READY=0
}

# _shunt_http_resolve <agent>
# One registry read: finds the model whose bulk-reader or code-writer agent is
# <agent> and sets _SHUNT_HTTP_ID, _SHUNT_HTTP_ROLE (bulk-reader|code-writer),
# _SHUNT_HTTP_REQUEST_BODY and _SHUNT_HTTP_ROLE_REQUEST_BODY (compact JSON, {}
# when unset, merged and validated later by _shunt_http_setup),
# _SHUNT_HTTP_THINKING_BODY and _SHUNT_HTTP_THINKING_FIELD (the options of the
# current thinking mode, "null" when unset; thinking counts as off unless it is
# true, as for the opencode agent files), and the optional
# _SHUNT_HTTP_CONTEXT_TOKENS and _SHUNT_HTTP_OVERSIZE_POLICY (empty when
# absent). Fields are split on the unit separator, a non-whitespace delimiter,
# so empty fields keep their column. Must run in the current shell, not in
# $(...). Fails, leaving nothing resolved, when the
# registry is missing or has no such model.
_shunt_http_resolve() {
  local agent="$1" id a rb rrb ct op tf tb
  _shunt_http_clear
  shunt_models_available || return 1
  while IFS=$'\x1f' read -r id a rb rrb ct op tf tb; do
    if [ "$agent" = "$a" ]; then
      _SHUNT_HTTP_ROLE=bulk-reader
    elif [ "$agent" = "$(shunt_models_code_writer_agent_for "$id")" ]; then
      _SHUNT_HTTP_ROLE=code-writer
    else
      continue
    fi
    _SHUNT_HTTP_AGENT="$agent" _SHUNT_HTTP_ID="$id" _SHUNT_HTTP_REQUEST_BODY="$rb"
    _SHUNT_HTTP_ROLE_REQUEST_BODY="$rrb"
    _SHUNT_HTTP_CONTEXT_TOKENS="$ct" _SHUNT_HTTP_OVERSIZE_POLICY="$op"
    _SHUNT_HTTP_THINKING_FIELD="$tf" _SHUNT_HTTP_THINKING_BODY="$tb"
    return 0
  done < <(jq -r '.models[] | [.id, (.agent // ""), ((.request_body // {}) | tojson), ((.role_request_body // {}) | tojson), ((.context_tokens // "") | if type == "number" then floor | tostring else tostring end), (.oversize_policy // ""),
    (if .thinking == true then "thinking_options", (.thinking_options | tojson) else "thinking_off_options", (.thinking_off_options | tojson) end)] | join("\u001f")' "$SHUNT_MODELS_FILE")
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
    || { echo "shunt: the $role prompt is missing at $file (incomplete plugin install)." >&2; return "$SHUNT_TRY_INVOKE_CONFIG"; }
  printf -v "$2" '%s' "$(<"$file")"
}

# _shunt_http_append_file <outfile> <label> <file>
# Appends the file's content to the prompt in a block labelled with <label>.
_shunt_http_append_file() {
  [ -f "$3" ] && [ -r "$3" ] || { echo "shunt: cannot read attached file '$3'." >&2; return "$SHUNT_TRY_INVOKE_CONFIG"; }
  { printf '\n--- file: %s ---\n' "$2"; cat -- "$3"; printf '\n--- end of file ---\n'; } >>"$1"
}

# _shunt_http_build_prompt <outfile> <question> [file...]
# The question, then each attached file in a labelled block (the HTTP API has
# no equivalent of `opencode run -f`).
_shunt_http_build_prompt() {
  local out="$1" question="$2" f
  shift 2
  printf '%s\n' "$question" >"$out"
  for f in "$@"; do
    _shunt_http_append_file "$out" "$f" "$f" || return $?
  done
}

# _shunt_http_build_chunk_prompt <outfile> <question> <label> <chunk-file>
# Like _shunt_http_build_prompt for one chunk, labelled with the original file's
# name instead of the chunk temp file.
_shunt_http_build_chunk_prompt() {
  printf '%s\n' "$2" >"$1"
  _shunt_http_append_file "$1" "$3" "$4"
}

# _shunt_http_check_context_tokens
# Fails with a message unless the resolved context_tokens is empty or a plain
# integer of at most SHUNT_HTTP_MAX_CONTEXT_DIGITS digits (a hand-edited value
# such as 1e30 would otherwise abort bash arithmetic).
_shunt_http_check_context_tokens() {
  local ct="$_SHUNT_HTTP_CONTEXT_TOKENS"
  [ -z "$ct" ] && return 0
  if [[ "$ct" =~ ^[1-9][0-9]*$ ]] && [ "${#ct}" -le "$SHUNT_HTTP_MAX_CONTEXT_DIGITS" ]; then
    return 0
  fi
  echo "shunt: model $_SHUNT_HTTP_ID has an invalid context_tokens in models.json (config problem, no request sent). Run: shunt-models set-context $_SHUNT_HTTP_ID <tokens>." >&2
  return 1
}

# _shunt_http_guard_size <bytes>
# Checks the estimated request size against the resolved model's context budget.
# Returns 0 when the request may be sent. Returns SHUNT_HTTP_NEEDS_CHUNKING when it
# is too big for a bulk-reader whose policy is map_reduce (nothing said yet, the
# caller chunks). Otherwise explains on stderr, sends nothing and returns
# SHUNT_TRY_INVOKE_OVERSIZE when the input is too big (policy fail, or
# code-write), or SHUNT_TRY_INVOKE_CONFIG for a config problem (no context_tokens,
# invalid policy). An absent oversize_policy means
# SHUNT_HTTP_DEFAULT_OVERSIZE_POLICY. Code-write always refuses when too big,
# before the policy is looked at.
_shunt_http_guard_size() {
  local id="$_SHUNT_HTTP_ID" ct="$_SHUNT_HTTP_CONTEXT_TOKENS" policy="$_SHUNT_HTTP_OVERSIZE_POLICY"
  local tokens=$(( ($1 + SHUNT_HTTP_BYTES_PER_TOKEN - 1) / SHUNT_HTTP_BYTES_PER_TOKEN )) budget
  _shunt_http_check_context_tokens || return "$SHUNT_TRY_INVOKE_CONFIG"
  if [ -z "$ct" ]; then
    [ "$tokens" -le "$SHUNT_HTTP_UNKNOWN_CONTEXT_MAX_TOKENS" ] && return 0
    echo "shunt: model $id has no context_tokens. Run: shunt-models detect-context $id --write, or shunt-models set-context $id <tokens> (config problem, no request sent)." >&2
    return "$SHUNT_TRY_INVOKE_CONFIG"
  fi
  budget=$(( ct * SHUNT_HTTP_CONTEXT_BUDGET_PERCENT / 100 ))
  [ "$tokens" -le "$budget" ] && return 0
  if [ "$_SHUNT_HTTP_ROLE" != code-writer ] \
    && [ "${policy:-$SHUNT_HTTP_DEFAULT_OVERSIZE_POLICY}" = map_reduce ]; then
    return "$SHUNT_HTTP_NEEDS_CHUNKING"
  fi
  echo "shunt: model $id: input is too large for the model (about $tokens tokens, budget $budget), no request sent." >&2
  case "${policy:-$SHUNT_HTTP_DEFAULT_OVERSIZE_POLICY}" in
    fail | map_reduce) return "$SHUNT_TRY_INVOKE_OVERSIZE" ;;
    *)
      echo "shunt: model $id has an invalid oversize_policy (config problem)." >&2
      return "$SHUNT_TRY_INVOKE_CONFIG"
      ;;
  esac
}

# _shunt_http_normalize <response-file>
# Prints the normalized JSON of a chat completion, or returns 1 when the body
# has no choices[0]. Token counts and cost come from provider data, so they are
# cleaned here: a token count is a non-negative whole number (anything else is
# 0), cost is taken from usage.cost or cost only when a non-negative number.
# Nothing else ever reaches bash arithmetic or the usage log.
_shunt_http_normalize() {
  jq -e -c '
    def tokens: if type == "number" and . >= 0 and . < 1e15 then floor else 0 end;
    select((.choices | type) == "array" and (.choices | length) > 0) |
    (.choices[0].message.content // "") as $c |
    ((.usage | objects) // null) as $u |
    {text: (if ($c | type) == "string" then $c else "" end),
     finish_reason: (.choices[0].finish_reason // "")}
    + (if $u == null then {} else
        {usage: {input: ($u.prompt_tokens | tokens), output: ($u.completion_tokens | tokens)}} end)
    + ((($u.cost // .cost) | if type == "number" and . >= 0 and . < 1e15 then . else null end) as $cost
        | if $cost == null then {} else {cost: $cost} end)
  ' "$1" 2>/dev/null
}

# Per-call request state, set by _shunt_http_setup and shared by every request of
# one call (the single request, or all the map and merge requests of a chunked
# call). The key only ever lives in the 0600 header file behind _SHUNT_HTTP_HDR_ARGS.
_SHUNT_HTTP_PROVIDER="" _SHUNT_HTTP_BASE_URL="" _SHUNT_HTTP_SYSTEM="" _SHUNT_HTTP_KEY=""
_SHUNT_HTTP_BODY_FILE="" _SHUNT_HTTP_RESP_FILE="" _SHUNT_HTTP_ERR_FILE=""
_SHUNT_HTTP_AUTH_READY=0 _SHUNT_HTTP_HDR_ARGS=() _SHUNT_HTTP_OUT=""

# _shunt_http_setup <agent>
# Resolves the agent (unless the dispatcher already did), validates the provider
# and request_body, loads the role prompt and allocates the reusable temp files.
# No request is sent and no key is read yet.
_shunt_http_setup() {
  local agent="$1" id
  _SHUNT_HTTP_AUTH_READY=0 _SHUNT_HTTP_HDR_ARGS=() _SHUNT_HTTP_KEY=""
  # The dispatcher already resolved this agent. A direct caller has not.
  [ "$_SHUNT_HTTP_AGENT" = "$agent" ] || _shunt_http_resolve "$agent" \
    || { echo "shunt: no model in the registry for agent '$agent'." >&2; return "$SHUNT_TRY_INVOKE_CONFIG"; }
  id="$_SHUNT_HTTP_ID"
  _SHUNT_HTTP_PROVIDER="${id%%/*}"
  _SHUNT_HTTP_BASE_URL=$(shunt_provider_base_url "$_SHUNT_HTTP_PROVIDER") || return "$SHUNT_TRY_INVOKE_CONFIG"
  _shunt_http_check_base_url "$_SHUNT_HTTP_PROVIDER" "$_SHUNT_HTTP_BASE_URL" _SHUNT_HTTP_BASE_URL || return $?
  jq -e 'type == "object"' <<<"$_SHUNT_HTTP_REQUEST_BODY" >/dev/null 2>&1 \
    || { echo "shunt: model '$id': request_body must be a JSON object." >&2; return "$SHUNT_TRY_INVOKE_CONFIG"; }
  jq -e 'type == "object" and all(.[]; type == "object")' <<<"$_SHUNT_HTTP_ROLE_REQUEST_BODY" >/dev/null 2>&1 \
    || { echo "shunt: model '$id': role_request_body must be a JSON object of JSON objects." >&2; return "$SHUNT_TRY_INVOKE_CONFIG"; }
  jq -e 'type == "object" or type == "null"' <<<"$_SHUNT_HTTP_THINKING_BODY" >/dev/null 2>&1 \
    || { echo "shunt: model '$id': $_SHUNT_HTTP_THINKING_FIELD must be a JSON object or null." >&2; return "$SHUNT_TRY_INVOKE_CONFIG"; }
  # Effective body, shallow merges, later wins: request_body, then the explicit
  # per-model thinking options (their OpenCode camelCase names turned into
  # snake_case body fields: reasoningEffort becomes reasoning_effort), then the
  # role's keys. So a request_body.reasoning_effort written by a migration cannot
  # override a deliberate `thinking off`, while a role key still can.
  local role_key=bulk-read
  [ "$_SHUNT_HTTP_ROLE" = code-writer ] && role_key=code-write
  _SHUNT_HTTP_REQUEST_BODY=$(jq -c --arg role "$role_key" --argjson rrb "$_SHUNT_HTTP_ROLE_REQUEST_BODY" \
    --argjson think "$_SHUNT_HTTP_THINKING_BODY" \
    '. + (($think // {}) | with_entries(.key |= gsub("(?<c>[A-Z])"; "_" + (.c | ascii_downcase))))
      + ($rrb[$role] // {})' <<<"$_SHUNT_HTTP_REQUEST_BODY") || return "$SHUNT_TRY_INVOKE_CONFIG"
  _shunt_http_system_prompt "$_SHUNT_HTTP_ROLE" _SHUNT_HTTP_SYSTEM || return $?
  _shunt_http_new_tmp _SHUNT_HTTP_BODY_FILE && _shunt_http_new_tmp _SHUNT_HTTP_RESP_FILE \
    && _shunt_http_new_tmp _SHUNT_HTTP_ERR_FILE
}

# _shunt_http_prepare_auth
# Writes the auth header file once per call, just before the first request.
_shunt_http_prepare_auth() {
  [ "$_SHUNT_HTTP_AUTH_READY" = 1 ] && return 0
  local hdr key rc=0
  # The file is registered (_SHUNT_HTTP_HDR_FILE) before the key is written to it.
  shunt_provider_write_auth_header_file "$_SHUNT_HTTP_PROVIDER" _SHUNT_HTTP_HDR_FILE || rc=$?
  # 1 = key problem (CONFIG), anything else = temp file failure (ERROR).
  [ "$rc" -eq 0 ] || { [ "$rc" -eq 1 ] && return "$SHUNT_TRY_INVOKE_CONFIG"; return "$SHUNT_TRY_INVOKE_ERROR"; }
  hdr="$_SHUNT_HTTP_HDR_FILE"
  if [ -n "$hdr" ]; then
    key=$(<"$hdr")
    _SHUNT_HTTP_KEY="${key#Authorization: Bearer }"
    _SHUNT_HTTP_HDR_ARGS=(-H "@$hdr")
  fi
  _SHUNT_HTTP_AUTH_READY=1
}

# _shunt_http_build_request <prompt-file>
# Writes the JSON request body for the given user prompt to the body file. The
# registered request_body goes first so it can never replace model or messages.
_shunt_http_build_request() {
  jq -n -c --arg model "${_SHUNT_HTTP_ID#*/}" --rawfile prompt "$1" --arg system "$_SHUNT_HTTP_SYSTEM" \
    --argjson rb "$_SHUNT_HTTP_REQUEST_BODY" \
    '$rb + {model: $model, messages: [{role: "system", content: $system}, {role: "user", content: $prompt}]}' \
    >"$_SHUNT_HTTP_BODY_FILE"
}

# _shunt_http_check_reply <http_code> <curl_status>
# Maps the outcome of one curl run to a status (see the table on top). On success
# stores the path of the normalized response in _SHUNT_HTTP_OUT.
_shunt_http_check_reply() {
  local http_code="$1" curl_status="$2" provider="$_SHUNT_HTTP_PROVIDER" key="$_SHUNT_HTTP_KEY" out finish
  local status_known=0
  # An auth or rate-limit status is mapped even when its body was too large (or
  # curl stopped at the cap with exit 63): the status says more than the size.
  case "$http_code" in
    401 | 403 | 429)
      if [ "$curl_status" -eq 0 ] || [ "$curl_status" -eq "$SHUNT_HTTP_CURL_TOO_LARGE" ]; then status_known=1; fi ;;
  esac
  if [ "$status_known" -eq 0 ] && { [ "$curl_status" -eq "$SHUNT_HTTP_CURL_TOO_LARGE" ] \
    || { [ "$curl_status" -eq 0 ] && _shunt_http_too_large "$_SHUNT_HTTP_RESP_FILE"; }; }; then
    echo "shunt: provider '$provider' sent a response larger than $(_shunt_http_max_response_bytes) bytes." >&2
    return "$SHUNT_TRY_INVOKE_ERROR"
  fi
  if [ "$curl_status" -eq 28 ]; then
    return "$SHUNT_TRY_INVOKE_TIMEOUT"
  elif [ "$curl_status" -ne 0 ] && [ "$status_known" -eq 0 ]; then
    echo "shunt: request to provider '$provider' failed (curl exit $curl_status): $(_shunt_http_excerpt "$_SHUNT_HTTP_ERR_FILE" "$key")" >&2
    if [ "${_SHUNT_HTTP_ASSUMED_HTTPS:-0}" = 1 ]; then
      echo "shunt: provider '$provider': cannot reach $_SHUNT_HTTP_BASE_URL (no scheme in base_url, https was assumed; write http://... explicitly for a plain http endpoint)." >&2
    fi
    return "$SHUNT_TRY_INVOKE_ERROR"
  fi
  case "$http_code" in
    2??) ;;
    401 | 403)
      echo "shunt: auth failed for provider $provider: the key was rejected or is missing. Re-enter it through /model-config (it opens a password window), or without a desktop: ! $_SHUNT_HTTP_MODELS_CMD key set $(printf '%q' "$provider")" >&2
      return "$SHUNT_TRY_INVOKE_AUTH"
      ;;
    400 | 404 | 413)
      echo "shunt: provider '$provider' answered HTTP $http_code: $(_shunt_http_excerpt "$_SHUNT_HTTP_RESP_FILE" "$key")" >&2
      return "$SHUNT_TRY_INVOKE_ERROR"
      ;;
    *)
      echo "shunt: provider '$provider' answered HTTP ${http_code//[^0-9]/}." >&2
      return "$SHUNT_TRY_INVOKE_ERROR"
      ;;
  esac
  out=$(shunt_tmpfile) || { echo "shunt: cannot create a temp file for the reply." >&2; return "$SHUNT_TRY_INVOKE_ERROR"; }
  if ! _shunt_http_normalize "$_SHUNT_HTTP_RESP_FILE" >"$out"; then
    rm -f "$out"
    echo "shunt: provider '$provider' sent a reply that is not a chat completion." >&2
    return "$SHUNT_TRY_INVOKE_ERROR"
  fi
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
  _SHUNT_HTTP_OUT="$out"
}


# _shunt_http_send
# POSTs the body file. On success _SHUNT_HTTP_OUT holds the normalized response
# file, which the caller owns. Returns a SHUNT_TRY_INVOKE_* status otherwise.
_shunt_http_send() {
  local http_code curl_status=0 status=0
  _SHUNT_HTTP_OUT=""
  _shunt_http_request_max_time || return $?
  _shunt_http_prepare_auth || return $?
  http_code=$(curl -q -sS --globoff --max-time "$_SHUNT_HTTP_MAX_TIME" --proto '=http,https' \
    --max-filesize "$(_shunt_http_max_response_bytes)" \
    -H 'Content-Type: application/json' ${_SHUNT_HTTP_HDR_ARGS[@]+"${_SHUNT_HTTP_HDR_ARGS[@]}"} \
    --data-binary "@$_SHUNT_HTTP_BODY_FILE" -o "$_SHUNT_HTTP_RESP_FILE" -w '%{http_code}' \
    "${_SHUNT_HTTP_BASE_URL%/}/chat/completions" 2>"$_SHUNT_HTTP_ERR_FILE" </dev/null) || curl_status=$?
  _shunt_http_check_reply "$http_code" "$curl_status" || status=$?
  # A request cut short by the remaining time ran into the total deadline.
  if [ "$status" -eq "$SHUNT_TRY_INVOKE_TIMEOUT" ] && [ "$_SHUNT_HTTP_MAX_TIME_CAPPED" = 1 ]; then
    _shunt_http_deadline_note
    status=$SHUNT_TRY_INVOKE_DEADLINE
  fi
  return "$status"
}

# _shunt_http_ask <prompt-file>
# One request: builds the body for the prompt and sends it.
_shunt_http_ask() {
  _shunt_http_build_request "$1" \
    || { echo "shunt: cannot build the request body (model $_SHUNT_HTTP_ID)." >&2; return "$SHUNT_TRY_INVOKE_ERROR"; }
  _shunt_http_send
}


# _shunt_http_call <agent> <question> [file...]
# The work of _shunt_transport_http. Temp files are registered for cleanup by
# the caller. Prints the normalized response file path on success.
_shunt_http_call() {
  local agent="$1" question="$2" prompt_file guard=0
  shift 2
  _shunt_http_init_deadline || return $?
  _shunt_http_setup "$agent" || return $?
  _shunt_http_new_tmp prompt_file || return $?
  _shunt_http_build_prompt "$prompt_file" "$question" "$@" || return $?
  _shunt_http_guard_size $(( $(_shunt_http_bytes "$_SHUNT_HTTP_SYSTEM") + $(wc -c <"$prompt_file") )) || guard=$?
  case "$guard" in
    0) ;;
    "$SHUNT_HTTP_NEEDS_CHUNKING") _shunt_http_map_reduce "$question" "$@"; return $? ;;
    *) return "$guard" ;;
  esac
  _shunt_http_ask "$prompt_file" || return $?
  echo "$_SHUNT_HTTP_OUT"
}

# _shunt_transport_http <agent> <question> [file...]
# Prints the path to a temp file holding the normalized response. Never exits
# the process: returns a SHUNT_TRY_INVOKE_* status, always with the reason
# already explained on stderr. The temp files, the auth header file included,
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
