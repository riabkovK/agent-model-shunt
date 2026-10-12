# HTTP transport, map_reduce chunking: usage aggregation, chunk planning
# (line ranges, UTF-8 safe cuts), the chunk requests and the merge rounds.
# Sourced by transport-http.sh, which supplies the helpers (ask, tmp files,
# size constants) and the SHUNT_TRY_INVOKE_* statuses. Not meant to be sourced
# on its own.

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
  # Defense in depth: the normalizer already makes these whole numbers, but a
  # value that is not one must never reach the arithmetic below.
  [[ "$in" =~ ^[0-9]+$ ]] || in=0
  [[ "$out" =~ ^[0-9]+$ ]] || out=0
  [[ "$cost" =~ ^[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]] || cost=""
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

# _shunt_http_lines <file> <first> <last>
# Prints lines <first>..<last> byte for byte. sed -n 'Np' in BusyBox and BSD
# adds a newline to a last line that has none. head and tail do not, and head
# is the writer here, so the pipe never ends in SIGPIPE. Fails when head cannot
# read the file (status 141 when a later reader closes the pipe early).
_shunt_http_lines() {
  local -a st
  head -n "$3" "$1" | tail -n "+$2"
  st=("${PIPESTATUS[@]}")
  [ "${st[0]}" -eq 0 ] || return "${st[0]}"
  return "${st[1]}"
}

# _shunt_http_line_ranges <file> <budget>
# Prints "first last kind" per chunk of whole lines, kind L, or a single line
# longer than the budget as kind B. Consecutive L chunks share up to
# SHUNT_HTTP_CHUNK_OVERLAP_LINES lines, and at most a quarter of the budget. Byte lengths are counted in the C locale.
_shunt_http_line_ranges() {
  LC_ALL=C awk -v budget="$2" -v ov="$SHUNT_HTTP_CHUNK_OVERLAP_LINES" -v max="$SHUNT_HTTP_MAX_CHUNKS" '
    # Streams: a range is printed as soon as it is closed, lengths before the
    # current range are freed, and reading stops once more than max ranges are
    # out, because the plan is refused then anyway.
    function out(a, b, k) {
      print a, b, k
      if (++printed > max) { stopped = 1; exit }
    }
    BEGIN { s = 1; e = 0; sum = 0; lo = 1 }
    {
      i = NR
      len[i] = length($0) + 1
      if (len[i] > budget) {
        if (e >= s) out(s, e, "L")
        out(i, i, "B")
        s = i + 1; e = i; sum = 0
        next
      }
      if (e >= s && sum + len[i] > budget) {
        out(s, e, "L")
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
      for (; lo < s; lo++) delete len[lo]
    }
    END { if (!stopped && e >= s) print s, e, "L" }' <"$1"
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
  _shunt_http_lines "$f" "$s" "$s" >"$line_file" || return 1
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
# The byte slice ends in head -c, which may close the pipe early. That makes
# the upstream stages die of SIGPIPE (141), or exit 1 with EPIPE when the shell
# was started with SIGPIPE ignored. Both are fine, as the readability of the
# source is checked up front. The final head -c writes the file and must succeed.
_shunt_http_write_chunk() {
  local i="$1" f="${_CH_FILE[$1]}" s
  local -a st
  [ -r "$f" ] || { echo "shunt: cannot read $f to cut a chunk from it." >&2; return 1; }
  if [ "${_CH_OFF[i]}" -ge 0 ]; then
    _shunt_http_lines "$f" "${_CH_START[i]}" "${_CH_START[i]}" 2>/dev/null | tail -c +$(( _CH_OFF[i] + 1 )) 2>/dev/null \
      | head -c "${_CH_LEN[i]}" >"$2"
    st=("${PIPESTATUS[@]}")
    for s in "${st[0]}" "${st[1]}"; do
      [ "$s" -eq 0 ] || [ "$s" -eq 1 ] || [ "$s" -eq 141 ] || return 1
    done
    [ "${st[2]}" -eq 0 ]
  else
    _shunt_http_lines "$f" "${_CH_START[i]}" "${_CH_END[i]}" >"$2"
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
