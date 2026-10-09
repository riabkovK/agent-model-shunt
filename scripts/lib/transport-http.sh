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
# Secret rules: the key only ever lives in a 0600 header file handed to curl as
# -H @file, never in argv or on stderr. Redirects are never followed (no -L), so
# the Authorization header cannot be replayed to another host.

SHUNT_HTTP_EXCERPT_CHARS=300
# Oversize guard: tokens are estimated as ceil(bytes / SHUNT_HTTP_BYTES_PER_TOKEN)
# and must fit in SHUNT_HTTP_CONTEXT_BUDGET_PERCENT of the model's context_tokens.
# A model without context_tokens is only trusted with requests up to
# SHUNT_HTTP_UNKNOWN_CONTEXT_MAX_TOKENS.
SHUNT_HTTP_BYTES_PER_TOKEN=3
SHUNT_HTTP_CONTEXT_BUDGET_PERCENT=60
SHUNT_HTTP_UNKNOWN_CONTEXT_MAX_TOKENS=4000
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
      return 1
      ;;
    *)
      echo "shunt: provider '$provider': base_url is malformed or has credentials in it (config problem, no request sent)." >&2
      return 1
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
  done < <(jq -r '.models[] | [.id, (.agent // ""), ((.request_body // {}) | tojson), ((.role_request_body // {}) | tojson), ((.context_tokens // "") | tostring), (.oversize_policy // ""),
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
    || { echo "shunt: the $role prompt is missing at $file (incomplete plugin install)." >&2; return 1; }
  printf -v "$2" '%s' "$(<"$file")"
}

# _shunt_http_append_file <outfile> <label> <file>
# Appends the file's content to the prompt in a block labelled with <label>.
_shunt_http_append_file() {
  [ -f "$3" ] && [ -r "$3" ] || { echo "shunt: cannot read attached file '$3'." >&2; return 1; }
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
    _shunt_http_append_file "$out" "$f" "$f" || return 1
  done
}

# _shunt_http_build_chunk_prompt <outfile> <question> <label> <chunk-file>
# Like _shunt_http_build_prompt for one chunk, labelled with the original file's
# name instead of the chunk temp file.
_shunt_http_build_chunk_prompt() {
  printf '%s\n' "$2" >"$1"
  _shunt_http_append_file "$1" "$3" "$4"
}

# _shunt_http_guard_size <bytes>
# Checks the estimated request size against the resolved model's context budget.
# Returns 0 when the request may be sent. Returns SHUNT_HTTP_NEEDS_CHUNKING when it
# is too big for a bulk-reader whose policy is map_reduce (nothing said yet, the
# caller chunks). Otherwise explains on stderr, sends nothing and returns
# SHUNT_TRY_INVOKE_OVERSIZE when the input is too big (policy fail, or
# code-write), or SHUNT_TRY_INVOKE_ERROR for a config problem (no context_tokens,
# invalid policy). An absent oversize_policy means
# SHUNT_HTTP_DEFAULT_OVERSIZE_POLICY. Code-write always refuses when too big,
# before the policy is looked at.
_shunt_http_guard_size() {
  local id="$_SHUNT_HTTP_ID" ct="$_SHUNT_HTTP_CONTEXT_TOKENS" policy="$_SHUNT_HTTP_OVERSIZE_POLICY"
  local tokens=$(( ($1 + SHUNT_HTTP_BYTES_PER_TOKEN - 1) / SHUNT_HTTP_BYTES_PER_TOKEN )) budget
  if [ -z "$ct" ]; then
    [ "$tokens" -le "$SHUNT_HTTP_UNKNOWN_CONTEXT_MAX_TOKENS" ] && return 0
    echo "shunt: model $id has no context_tokens. Run: shunt-models detect-context $id --write, or shunt-models set-context $id <tokens> (config problem, no request sent)." >&2
    return "$SHUNT_TRY_INVOKE_ERROR"
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
      return "$SHUNT_TRY_INVOKE_ERROR"
      ;;
  esac
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
    || { echo "shunt: no model in the registry for agent '$agent'." >&2; return 1; }
  id="$_SHUNT_HTTP_ID"
  _SHUNT_HTTP_PROVIDER="${id%%/*}"
  _SHUNT_HTTP_BASE_URL=$(shunt_provider_base_url "$_SHUNT_HTTP_PROVIDER") || return 1
  _shunt_http_check_base_url "$_SHUNT_HTTP_PROVIDER" "$_SHUNT_HTTP_BASE_URL" _SHUNT_HTTP_BASE_URL || return 1
  jq -e 'type == "object"' <<<"$_SHUNT_HTTP_REQUEST_BODY" >/dev/null 2>&1 \
    || { echo "shunt: model '$id': request_body must be a JSON object." >&2; return 1; }
  jq -e 'type == "object" and all(.[]; type == "object")' <<<"$_SHUNT_HTTP_ROLE_REQUEST_BODY" >/dev/null 2>&1 \
    || { echo "shunt: model '$id': role_request_body must be a JSON object of JSON objects." >&2; return 1; }
  jq -e 'type == "object" or type == "null"' <<<"$_SHUNT_HTTP_THINKING_BODY" >/dev/null 2>&1 \
    || { echo "shunt: model '$id': $_SHUNT_HTTP_THINKING_FIELD must be a JSON object or null." >&2; return 1; }
  # Effective body, shallow merges, later wins: the thinking options with their
  # OpenCode camelCase names turned into snake_case body fields (reasoningEffort
  # becomes reasoning_effort), then request_body, then the role's keys on top.
  local role_key=bulk-read
  [ "$_SHUNT_HTTP_ROLE" = code-writer ] && role_key=code-write
  _SHUNT_HTTP_REQUEST_BODY=$(jq -c --arg role "$role_key" --argjson rrb "$_SHUNT_HTTP_ROLE_REQUEST_BODY" \
    --argjson think "$_SHUNT_HTTP_THINKING_BODY" \
    '(($think // {}) | with_entries(.key |= gsub("(?<c>[A-Z])"; "_" + (.c | ascii_downcase))))
      + . + ($rrb[$role] // {})' <<<"$_SHUNT_HTTP_REQUEST_BODY") || return 1
  _shunt_http_system_prompt "$_SHUNT_HTTP_ROLE" _SHUNT_HTTP_SYSTEM || return 1
  _shunt_http_new_tmp _SHUNT_HTTP_BODY_FILE && _shunt_http_new_tmp _SHUNT_HTTP_RESP_FILE \
    && _shunt_http_new_tmp _SHUNT_HTTP_ERR_FILE || return 1
}

# _shunt_http_prepare_auth
# Writes the auth header file once per call, just before the first request.
_shunt_http_prepare_auth() {
  [ "$_SHUNT_HTTP_AUTH_READY" = 1 ] && return 0
  local hdr key
  hdr=$(shunt_provider_write_auth_header_file "$_SHUNT_HTTP_PROVIDER") || return 1
  if [ -n "$hdr" ]; then
    _SHUNT_HTTP_TMP+=("$hdr")
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
  if [ "$curl_status" -eq 28 ]; then
    return "$SHUNT_TRY_INVOKE_TIMEOUT"
  elif [ "$curl_status" -ne 0 ]; then
    echo "shunt: request to provider '$provider' failed (curl exit $curl_status): $(_shunt_http_excerpt "$_SHUNT_HTTP_ERR_FILE" "$key")" >&2
    if [ "${_SHUNT_HTTP_ASSUMED_HTTPS:-0}" = 1 ]; then
      echo "shunt: provider '$provider': cannot reach $_SHUNT_HTTP_BASE_URL (no scheme in base_url, https was assumed; write http://... explicitly for a plain http endpoint)." >&2
    fi
    return "$SHUNT_TRY_INVOKE_ERROR"
  fi
  case "$http_code" in
    2??) ;;
    401 | 403)
      echo "shunt: auth failed for provider $provider. Check the key with: $_SHUNT_HTTP_MODELS_CMD key status $provider (set it with: ! $_SHUNT_HTTP_MODELS_CMD key set $provider)" >&2
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
  out=$(shunt_tmpfile) || return 1
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

# ---- total deadline ----------------------------------------------------------
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
      return 1
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

# _shunt_http_send
# POSTs the body file. On success _SHUNT_HTTP_OUT holds the normalized response
# file, which the caller owns. Returns a SHUNT_TRY_INVOKE_* status otherwise.
_shunt_http_send() {
  local http_code curl_status=0 status=0
  _SHUNT_HTTP_OUT=""
  _shunt_http_request_max_time || return $?
  _shunt_http_prepare_auth || return 1
  http_code=$(curl -q -sS --globoff --max-time "$_SHUNT_HTTP_MAX_TIME" --proto '=http,https' \
    -H 'Content-Type: application/json' "${_SHUNT_HTTP_HDR_ARGS[@]}" \
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
  _shunt_http_build_request "$1" || return 1
  _shunt_http_send
}

# ---- map_reduce chunking ------------------------------------------------------

# Usage totals over all requests of one chunked call.
_SHUNT_HTTP_AGG_USAGE=0 _SHUNT_HTTP_AGG_IN=0 _SHUNT_HTTP_AGG_OUT=0 _SHUNT_HTTP_AGG_COST=""

_shunt_http_agg_reset() {
  _SHUNT_HTTP_AGG_USAGE=0 _SHUNT_HTTP_AGG_IN=0 _SHUNT_HTTP_AGG_OUT=0 _SHUNT_HTTP_AGG_COST=""
}

# _shunt_http_agg_add <normalized-response-file>
_shunt_http_agg_add() {
  local has in out cost
  read -r has in out cost < <(jq -r '[(if (.usage | type) == "object" then 1 else 0 end),
    (.usage.input // 0), (.usage.output // 0), (.cost // "")] | join(" ")' "$1")
  [ "$has" = 1 ] && _SHUNT_HTTP_AGG_USAGE=1
  _SHUNT_HTTP_AGG_IN=$(( _SHUNT_HTTP_AGG_IN + in ))
  _SHUNT_HTTP_AGG_OUT=$(( _SHUNT_HTTP_AGG_OUT + out ))
  if [ -n "$cost" ]; then
    _SHUNT_HTTP_AGG_COST=$(jq -n --arg a "${_SHUNT_HTTP_AGG_COST:-0}" --arg b "$cost" '($a | tonumber) + ($b | tonumber)')
  fi
  return 0
}

# _shunt_http_ask_counted <prompt-file>
# _shunt_http_ask, plus the usage of the answer added to the totals.
_shunt_http_ask_counted() {
  _shunt_http_ask "$1" || return $?
  _shunt_http_agg_add "$_SHUNT_HTTP_OUT"
}

# _shunt_http_agg_finalize <normalized-response-file>
# Rewrites the file so its usage and cost are the totals of the whole call.
_shunt_http_agg_finalize() {
  local tmp
  tmp=$(shunt_tmpfile) || return 1
  jq -c --argjson has "$_SHUNT_HTTP_AGG_USAGE" --argjson i "$_SHUNT_HTTP_AGG_IN" \
    --argjson o "$_SHUNT_HTTP_AGG_OUT" --arg c "$_SHUNT_HTTP_AGG_COST" \
    'del(.usage, .cost)
     + (if $has == 1 then {usage: {input: $i, output: $o}} else {} end)
     + (if $c == "" then {} else {cost: ($c | tonumber)} end)' "$1" >"$tmp" \
    && mv -f "$tmp" "$1" || { rm -f "$tmp"; return 1; }
}

# _shunt_http_budget_bytes
# Prints the request size, in bytes, the resolved model accepts.
_shunt_http_budget_bytes() {
  echo $(( _SHUNT_HTTP_CONTEXT_TOKENS * SHUNT_HTTP_CONTEXT_BUDGET_PERCENT / 100 * SHUNT_HTTP_BYTES_PER_TOKEN ))
}

# _shunt_http_bytes <string>
_shunt_http_bytes() {
  printf '%s' "$1" | wc -c
}

# The chunk plan, one entry per chunk across all files, in request order.
_CH_FILE=() _CH_START=() _CH_END=() _CH_OFF=() _CH_LEN=() _CH_PART=() _CH_OF=()

# _shunt_http_add_chunk <file> <start-line> <end-line> <byte-offset|-1> <byte-length>
_shunt_http_add_chunk() {
  _CH_FILE+=("$1") _CH_START+=("$2") _CH_END+=("$3") _CH_OFF+=("$4") _CH_LEN+=("$5")
}

# _shunt_http_line_ranges <file> <budget>
# Prints "first last kind" per chunk of whole lines, kind L, or a single line
# longer than the budget as kind B. Consecutive L chunks share up to
# SHUNT_HTTP_CHUNK_OVERLAP_LINES lines, and at most a quarter of the budget. Byte lengths are counted in the C locale.
_shunt_http_line_ranges() {
  LC_ALL=C awk -v budget="$2" -v ov="$SHUNT_HTTP_CHUNK_OVERLAP_LINES" '
    { len[NR] = length($0) + 1 }
    END {
      s = 1; e = 0; sum = 0
      for (i = 1; i <= NR; i++) {
        if (len[i] > budget) {
          if (e >= s) print s, e, "L"
          print i, i, "B"
          s = i + 1; e = i; sum = 0
          continue
        }
        if (e >= s && sum + len[i] > budget) {
          print s, e, "L"
          ns = e - ov + 1
          if (ns <= s) ns = s + 1
          sum = 0
          for (j = ns; j <= e; j++) sum += len[j]
          while (ns <= e && (sum + len[i] > budget || sum > budget / 4)) { sum -= len[ns]; ns++ }
          if (ns > e) { s = i; sum = 0 } else { s = ns }
        } else if (e < s) {
          s = i; sum = 0
        }
        e = i; sum += len[i]
      }
      if (e >= s) print s, e, "L"
    }' <"$1"
}

# _shunt_http_utf8_cut <file> <pos>
# Prints where to split <file> at or just before byte offset <pos>: the last of
# offsets pos-3..pos whose byte does not continue a UTF-8 character (10xxxxxx),
# so no character is cut in half. A UTF-8 character has at most 3 continuation
# bytes. Prints <pos> when all four bytes are continuation bytes (not UTF-8).
# Uses only tail -c +N, head -c and od -A n -t u1, which BSD and GNU share.
_shunt_http_utf8_cut() {
  local pos="$2" from i bytes=()
  from=$(( pos > 3 ? pos - 3 : 0 ))
  read -r -a bytes < <(tail -c +$(( from + 1 )) "$1" | head -c $(( pos - from + 1 )) | od -A n -t u1 -v)
  for (( i = ${#bytes[@]} - 1; i >= 0; i-- )); do
    if [ $(( bytes[i] & 192 )) -ne 128 ]; then
      echo $(( from + i ))
      return 0
    fi
  done
  echo "$pos"
}

# _shunt_http_cut_before_blank_tail <line-file> <off> <end> <len> <budget>
# The piece <off>..<end> of a line is followed by whitespace only. Sets
# _SHUNT_HTTP_CUT to the start of the piece's last non-whitespace character, so
# the last piece carries it along with the whitespace, when that piece still
# fits the budget and the cut stays after <off>. Otherwise to <end> unchanged.
# The piece is part of one line, so awk reads it as a single record.
_shunt_http_cut_before_blank_tail() {
  local k cut
  _SHUNT_HTTP_CUT=$3
  k=$(LC_ALL=C awk '{ print match($0, /[ \t\r\f\v]*$/) - 1 }' \
    < <(tail -c +$(( $2 + 1 )) "$1" | head -c $(( $3 - $2 ))))
  case "$k" in '' | *[!0-9]*) return 0 ;; esac
  [ "$k" -gt 0 ] || return 0
  cut=$(_shunt_http_utf8_cut "$1" $(( $2 + k - 1 )))
  [ "$cut" -gt "$2" ] && [ $(( $4 - cut )) -le "$5" ] && _SHUNT_HTTP_CUT=$cut
  return 0
}

# _shunt_http_plan_long_line <file> <line> <content-budget-bytes>
# Appends byte pieces of one line longer than the budget, each at most the
# budget and split on a UTF-8 character boundary. When the rest after a piece
# would be only whitespace (typically the line's own newline), the piece ends
# one character earlier, so the last request carries real content. Stops once
# the plan is over SHUNT_HTTP_MAX_CHUNKS, as the call fails then anyway.
_shunt_http_plan_long_line() {
  local f="$1" s="$2" budget="$3" line_file len off end cut
  _shunt_http_new_tmp line_file || return 1
  sed -n "${s}p" <"$f" >"$line_file"
  len=$(wc -c <"$line_file")
  for (( off = 0; off < len; off = end )); do
    end=$(( off + budget ))
    if [ "$end" -ge "$len" ]; then
      end=$len
    else
      cut=$(_shunt_http_utf8_cut "$line_file" "$end")
      [ "$cut" -le "$off" ] || end=$cut
      if [ $(( len - end )) -le "$budget" ] \
        && ! LC_ALL=C grep -q '[^[:space:]]' < <(tail -c +$(( end + 1 )) "$line_file"); then
        _shunt_http_cut_before_blank_tail "$line_file" "$off" "$end" "$len" "$budget"
        end=$_SHUNT_HTTP_CUT
      fi
    fi
    _shunt_http_add_chunk "$f" "$s" "$s" "$off" $(( end - off ))
    [ "${#_CH_FILE[@]}" -le "$SHUNT_HTTP_MAX_CHUNKS" ] || break
  done
  rm -f "$line_file"
}

# _shunt_http_plan_file <file> <content-budget-bytes>
# Appends the chunks of one file to the plan: the whole file when it fits, else
# line ranges with overlap, else byte pieces for a line longer than the budget.
_shunt_http_plan_file() {
  local f="$1" budget="$2" base=${#_CH_FILE[@]} size lines s e kind n i
  size=$(wc -c <"$f")
  if [ "$size" -le "$budget" ]; then
    lines=$(awk 'END { print NR }' <"$f")
    _shunt_http_add_chunk "$f" 1 $(( lines > 0 ? lines : 1 )) -1 0
  else
    while read -r s e kind; do
      if [ "$kind" = B ]; then
        _shunt_http_plan_long_line "$f" "$s" "$budget" || return 1
      else
        _shunt_http_add_chunk "$f" "$s" "$e" -1 0
      fi
      [ "${#_CH_FILE[@]}" -le "$SHUNT_HTTP_MAX_CHUNKS" ] || break
    done < <(_shunt_http_line_ranges "$f" "$budget")
  fi
  n=$(( ${#_CH_FILE[@]} - base ))
  for (( i = 0; i < n; i++ )); do
    _CH_PART[base + i]=$(( i + 1 )) _CH_OF[base + i]=$n
  done
}

# _shunt_http_chunk_question <var> <question> <note>
# Sets <var> to the question of one chunk request, as sent.
_shunt_http_chunk_question() {
  printf -v "$1" '%s\n\n(This is %s. Answer for this part only.)' "$2" "$3"
}

# _shunt_http_chunk_overhead <question> <label> <size> <probe-file> <empty-file>
# Prints the bytes a chunk request of a file named <label> and <size> bytes adds
# around its content: the role prompt plus the chunk prompt built, with the same
# functions the map step uses, around the empty file. The note gets the longest
# form a chunk of that file can have, every number with as many digits as
# <size>, which bounds line numbers, byte offsets and part counts. This is the
# decoded text the oversize guard estimates tokens from. JSON escaping only
# grows the request on the wire, not what the model reads.
_shunt_http_chunk_overhead() {
  local n="${3//[!0-9]/}" q
  n=${n:-0}
  n=${n//?/9}
  _shunt_http_chunk_question q "$1" "part $n of $n of $2, line $n, bytes $n-$n"
  _shunt_http_build_chunk_prompt "$4" "$q" "$2" "$5" || return 1
  echo $(( $(_shunt_http_bytes "$_SHUNT_HTTP_SYSTEM") + $(wc -c <"$4") ))
}

# _shunt_http_plan_all <question> <file>...
# Fills the chunk plan. Refuses with SHUNT_TRY_INVOKE_OVERSIZE when the role
# prompt and question leave too little room for file content, or the input
# needs more than SHUNT_HTTP_MAX_CHUNKS chunks.
_shunt_http_plan_all() {
  local question="$1" f room overhead probe empty
  shift
  _CH_FILE=() _CH_START=() _CH_END=() _CH_OFF=() _CH_LEN=() _CH_PART=() _CH_OF=()
  _shunt_http_new_tmp probe && _shunt_http_new_tmp empty || return 1
  # The empty name checks the question alone, which also covers a call without files.
  for f in "" "$@"; do
    overhead=$(_shunt_http_chunk_overhead "$question" "$f" "$( [ -z "$f" ] || wc -c <"$f")" "$probe" "$empty") \
      || return 1
    room=$(( $(_shunt_http_budget_bytes) - overhead ))
    if [ "$room" -lt "$SHUNT_HTTP_MIN_CHUNK_BYTES" ]; then
      echo "shunt: model $_SHUNT_HTTP_ID: the role prompt and the question leave no room for file content in the context budget (no request sent)." >&2
      return "$SHUNT_TRY_INVOKE_OVERSIZE"
    fi
    [ -z "$f" ] || _shunt_http_plan_file "$f" "$room" || return 1
    [ "${#_CH_FILE[@]}" -le "$SHUNT_HTTP_MAX_CHUNKS" ] || break
  done
  rm -f "$probe" "$empty"
  if [ "${#_CH_FILE[@]}" -gt "$SHUNT_HTTP_MAX_CHUNKS" ]; then
    echo "shunt: model $_SHUNT_HTTP_ID: the input needs more chunks than the limit of $SHUNT_HTTP_MAX_CHUNKS (no request sent)." >&2
    return "$SHUNT_TRY_INVOKE_OVERSIZE"
  elif [ "${#_CH_FILE[@]}" -eq 0 ]; then
    echo "shunt: model $_SHUNT_HTTP_ID: the input gives no chunks to send (no request sent)." >&2
    return "$SHUNT_TRY_INVOKE_ERROR"
  fi
}

# _shunt_http_chunk_note <index>
# Prints "part i of n of <file>, lines a-b" (or the byte range for a split line).
_shunt_http_chunk_note() {
  local i="$1" where
  if [ "${_CH_OFF[i]}" -ge 0 ]; then
    where="line ${_CH_START[i]}, bytes $(( _CH_OFF[i] + 1 ))-$(( _CH_OFF[i] + _CH_LEN[i] ))"
  else
    where="lines ${_CH_START[i]}-${_CH_END[i]}"
  fi
  printf 'part %s of %s of %s, %s' "${_CH_PART[i]}" "${_CH_OF[i]}" "${_CH_FILE[i]}" "$where"
}

# _shunt_http_write_chunk <index> <outfile>
_shunt_http_write_chunk() {
  local i="$1" f="${_CH_FILE[$1]}"
  if [ "${_CH_OFF[i]}" -ge 0 ]; then
    sed -n "${_CH_START[i]}p" <"$f" | tail -c +$(( _CH_OFF[i] + 1 )) | head -c "${_CH_LEN[i]}" >"$2" || true
  else
    sed -n "${_CH_START[i]},${_CH_END[i]}p" <"$f" >"$2"
  fi
}

# _shunt_http_merge_prompt <outfile> <question> <from> <to>
# The question, the merge instruction and partial answers from..to-1 of the
# _MR_TEXT and _MR_LABEL arrays.
_shunt_http_merge_prompt() {
  local out="$1" i
  printf '%s\n\n%s\n' "$2" "$SHUNT_HTTP_MERGE_INSTRUCTION" >"$out"
  for (( i = $3; i < $4; i++ )); do
    printf '\n--- partial answer %s of %s (%s) ---\n%s\n' "$(( i + 1 ))" "${#_MR_TEXT[@]}" "${_MR_LABEL[i]}" "${_MR_TEXT[i]}" >>"$out"
  done
}

_MR_TEXT=() _MR_LABEL=()

# _shunt_http_merge_fail <why>
_shunt_http_merge_fail() {
  echo "shunt: model $_SHUNT_HTTP_ID: the partial answers cannot be merged ($1), no result." >&2
  return "$SHUNT_TRY_INVOKE_ERROR"
}

# _shunt_http_merge_group <prompt-file> <question> <from> <to>
# One group merge request. Appends the merged answer to _NEW_TEXT/_NEW_LABEL.
_shunt_http_merge_group() {
  local text
  _shunt_http_merge_prompt "$1" "$2" "$3" "$4"
  _shunt_http_ask_counted "$1" || return $?
  text=$(jq -r '.text' "$_SHUNT_HTTP_OUT")
  rm -f "$_SHUNT_HTTP_OUT"
  _NEW_TEXT+=("$text") _NEW_LABEL+=("merged parts ${_MR_LABEL[$3]} .. ${_MR_LABEL[$(( $4 - 1 ))]}")
}

# _shunt_http_merge_round <prompt-file> <question>
# Groups neighbouring partial answers so each group's merge request fits the
# budget, and replaces the partials with one merged answer per group.
_shunt_http_merge_round() {
  local pf="$1" question="$2" limit base i g=0 sz sum
  limit=$(( $(_shunt_http_budget_bytes) - $(_shunt_http_bytes "$_SHUNT_HTTP_SYSTEM") ))
  _shunt_http_merge_prompt "$pf" "$question" 0 0
  base=$(wc -c <"$pf")
  sum=$base
  _NEW_TEXT=() _NEW_LABEL=()
  for (( i = 0; i < ${#_MR_TEXT[@]}; i++ )); do
    sz=$(( $(_shunt_http_bytes "${_MR_TEXT[i]}${_MR_LABEL[i]}") + SHUNT_HTTP_PARTIAL_RESERVE_BYTES ))
    [ $(( base + sz )) -le "$limit" ] || { _shunt_http_merge_fail "one partial answer alone is too big"; return $?; }
    if [ "$i" -gt "$g" ] && [ $(( sum + sz )) -gt "$limit" ]; then
      _shunt_http_merge_group_or_keep "$pf" "$question" "$g" "$i" || return $?
      g=$i sum=$base
    fi
    sum=$(( sum + sz ))
  done
  _shunt_http_merge_group_or_keep "$pf" "$question" "$g" "${#_MR_TEXT[@]}" || return $?
  _MR_TEXT=("${_NEW_TEXT[@]}") _MR_LABEL=("${_NEW_LABEL[@]}")
}

# _shunt_http_merge_group_or_keep <prompt-file> <question> <from> <to>
# A group of one partial needs no request and is carried over unchanged.
_shunt_http_merge_group_or_keep() {
  if [ $(( $4 - $3 )) -eq 1 ]; then
    _NEW_TEXT+=("${_MR_TEXT[$3]}") _NEW_LABEL+=("${_MR_LABEL[$3]}")
  else
    _shunt_http_merge_group "$@"
  fi
}

# _shunt_http_merge <prompt-file> <question>
# Reduce step: merges _MR_TEXT into the final answer, leaving its response file in
# _SHUNT_HTTP_OUT. Groups first while the partials do not fit in one request, at
# most SHUNT_HTTP_MAX_MERGE_DEPTH group rounds.
_shunt_http_merge() {
  local pf="$1" question="$2" depth=0 before limit
  limit=$(( $(_shunt_http_budget_bytes) - $(_shunt_http_bytes "$_SHUNT_HTTP_SYSTEM") ))
  while :; do
    _shunt_http_merge_prompt "$pf" "$question" 0 "${#_MR_TEXT[@]}"
    if [ "$(wc -c <"$pf")" -le "$limit" ]; then
      _shunt_http_ask_counted "$pf"
      return $?
    fi
    [ "$depth" -lt "$SHUNT_HTTP_MAX_MERGE_DEPTH" ] \
      || { _shunt_http_merge_fail "still too big after $SHUNT_HTTP_MAX_MERGE_DEPTH rounds of merging, depth cap reached"; return $?; }
    before=${#_MR_TEXT[@]}
    _shunt_http_merge_round "$pf" "$question" || return $?
    [ "${#_MR_TEXT[@]}" -lt "$before" ] || { _shunt_http_merge_fail "merging made no progress"; return $?; }
    depth=$(( depth + 1 ))
  done
}

# _shunt_http_map_reduce <question> <file>...
# Sends each chunk with the question (map), then merges the partial answers into
# one (reduce). Prints the final normalized response path with usage totals over
# every request. Any failing request aborts and no later request is sent.
_shunt_http_map_reduce() {
  local question="$1" i total note chunk_question prompt_file chunk_file
  shift
  _shunt_http_plan_all "$question" "$@" || return $?
  total=${#_CH_FILE[@]}
  _shunt_http_new_tmp prompt_file && _shunt_http_new_tmp chunk_file || return 1
  _shunt_http_agg_reset
  _MR_TEXT=() _MR_LABEL=()
  _SHUNT_HTTP_CHUNKS_TOTAL=$total _SHUNT_HTTP_CHUNKS_DONE=0
  echo "shunt: model $_SHUNT_HTTP_ID: input is too large for one request, asking in $total parts and merging." >&2
  for (( i = 0; i < total; i++ )); do
    note=$(_shunt_http_chunk_note "$i")
    _shunt_http_write_chunk "$i" "$chunk_file" || return 1
    _shunt_http_chunk_question chunk_question "$question" "$note"
    _shunt_http_build_chunk_prompt "$prompt_file" "$chunk_question" "${_CH_FILE[i]}" "$chunk_file" || return 1
    _shunt_http_ask_counted "$prompt_file" || return $?
    _SHUNT_HTTP_CHUNKS_DONE=$(( i + 1 ))
    if [ "$total" -gt 1 ]; then
      _MR_TEXT+=("$(jq -r '.text' "$_SHUNT_HTTP_OUT")") _MR_LABEL+=("${note#part * of * of }")
      rm -f "$_SHUNT_HTTP_OUT"
    fi
  done
  if [ "$total" -gt 1 ]; then
    _shunt_http_merge "$prompt_file" "$question" || return $?
  fi
  _shunt_http_agg_finalize "$_SHUNT_HTTP_OUT" || { rm -f "$_SHUNT_HTTP_OUT"; return 1; }
  echo "$_SHUNT_HTTP_OUT"
}

# _shunt_http_call <agent> <question> [file...]
# The work of _shunt_transport_http. Temp files are registered for cleanup by
# the caller. Prints the normalized response file path on success.
_shunt_http_call() {
  local agent="$1" question="$2" prompt_file guard=0
  shift 2
  _shunt_http_init_deadline || return 1
  _shunt_http_setup "$agent" || return $?
  _shunt_http_new_tmp prompt_file || return 1
  _shunt_http_build_prompt "$prompt_file" "$question" "$@" || return 1
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
