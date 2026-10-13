# Safe new-file write core for code-write (docs/TODO.md, "Code-writer").
# The delegate model only returns text. This library is what turns that text
# into a file: it validates the target path, parses the response protocol,
# enforces content limits and publishes the file without ever overwriting.
#
# Meant to be sourced by scripts/code-write. No top-level side effects. Needs
# bash, coreutils, awk, grep and iconv (all present in the test image).
# Written to also run on the bash 3.2 that macOS ships: no associative
# arrays, no case modification expansions, no negative array indexes.
#
# Public functions:
#   shunt_cw_project_root                     print the canonical project root
#   shunt_cw_normalize_path <path>            drop '.', empty and 'a/..' segments
#   shunt_cw_sensitive_component <path>       name a credential or state store in a path
#   shunt_cw_strip_invisible <text>           drop C1, zero width, bidi, filler, variation and Tag characters
#   shunt_cw_check_target <root> <target>     validate, print the resolved path
#   shunt_cw_parse <response-file> <out-dir>  split a model response
#   shunt_cw_publish <root> <target> <code-file>   create the file, no clobber
#   shunt_cw_cleanup                          roll back an interrupted publish
#
# Failure classification for callers (decision 8 in docs/TODO.md):
#   - shunt_cw_check_target failing is a refusal BEFORE the model call, it is
#     never a model failure and must not touch the circuit breaker.
#   - shunt_cw_parse exits 11 for an unusable response (a model failure that
#     goes to failover and the breaker), 10 for a deliberate refusal by the
#     model (not a failure, notes go to Claude), 0 for a usable response.
#   - shunt_cw_publish failing happens after a good response, so it is not the
#     model's fault.
#
# Signals: a process killed between the temp file and the final link leaves
# a .shunt-cw.* temp file and possibly empty directories it created. A caller
# that wants to avoid that runs `trap shunt_cw_cleanup INT TERM HUP` around
# shunt_cw_publish. The function is a no-op once a publish has finished.
#
# Residual risk, accepted and to be recorded in the ADR: TOCTOU. Every check
# is a path check, and something running in parallel with this process that
# swaps a directory for a symlink between the last check and the final link
# call can still redirect the write. The window is kept small (the parent is
# re-checked right before publish and the outcome of the link is verified)
# but cannot be closed from bash.

# Size caps. Overridable through the environment for tests. A value that is
# not a plain integer of at most 15 digits is ignored.
SHUNT_CW_DEFAULT_MAX_CODE_BYTES=262144
SHUNT_CW_DEFAULT_MAX_NOTES_BYTES=32768
# Allowance for tag lines, fence lines and CRLF on top of the two caps when
# bounding the raw response size before it is split.
SHUNT_CW_RESPONSE_SLACK_BYTES=4096

# Exit codes of shunt_cw_parse.
SHUNT_CW_EXIT_REFUSAL=10
SHUNT_CW_EXIT_UNUSABLE=11

SHUNT_CW_TAG_NOTES_OPEN='<SHUNT-NOTES>'
SHUNT_CW_TAG_NOTES_CLOSE='</SHUNT-NOTES>'
SHUNT_CW_TAG_CODE_OPEN='<SHUNT-CODE>'
SHUNT_CW_TAG_CODE_CLOSE='</SHUNT-CODE>'

# Scratch state shared between the internal helpers. Not part of the API.
_SHUNT_CW_ERR=""
_SHUNT_CW_ROOT=""
_SHUNT_CW_ANCESTOR=""
_SHUNT_CW_RESOLVED=""
_SHUNT_CW_MISSING=()
_SHUNT_CW_DIR=""
_SHUNT_CW_TMP=""
_SHUNT_CW_CREATED=()

# Splits the response in one pass. Reads the four tag lines and the limits
# from the environment, writes the notes and code files itself and prints one
# reason token. Kept as data so that sourcing stays free of side effects. Byte
# counts rely on the caller setting LC_ALL=C.
#
# The section variable follows the tags: 0 before the first tag, 1 inside the
# notes, 2 between the sections, 3 inside the code, 4 after the closing code
# tag. Text outside 1 and 3 must be blank, and is only judged once the tags
# are known to be complete and in order.
_SHUNT_CW_AWK_PROGRAM='
function blank(s) { return s ~ /^[ \t\r]*$/ }
BEGIN {
  section = 0
  t_notes_open = ENVIRON["CW_TAG_NOTES_OPEN"]
  t_notes_close = ENVIRON["CW_TAG_NOTES_CLOSE"]
  t_code_open = ENVIRON["CW_TAG_CODE_OPEN"]
  t_code_close = ENVIRON["CW_TAG_CODE_CLOSE"]
}
{
  line = $0
  sub(/\r$/, "", line)
  if (line == t_notes_open) { notes_open++; if (!notes_open_at) notes_open_at = NR; section = 1; next }
  if (line == t_notes_close) { notes_close++; if (!notes_close_at) notes_close_at = NR; section = 2; next }
  if (line == t_code_open) { code_open++; if (!code_open_at) code_open_at = NR; section = 3; next }
  if (line == t_code_close) { code_close++; if (!code_close_at) code_close_at = NR; section = 4; next }
  if (section == 1) { nn++; notes[nn] = $0; next }
  if (section == 3) { nc++; code[nc] = $0; next }
  if (!blank($0)) {
    if (section == 0) pre_text = 1
    else if (section == 2) mid_text = 1
    else post_text = 1
  }
}
END {
  if (!notes_open) { print "missing-notes-delimiter"; exit }
  if (!code_open) { print "missing-code-delimiter"; exit }
  if (!notes_close || !code_close) { print "missing-closing-tag"; exit }
  if (notes_open > 1) { print "duplicate-notes-delimiter"; exit }
  if (code_open > 1) { print "duplicate-code-delimiter"; exit }
  if (notes_close > 1 || code_close > 1) { print "duplicate-closing-tag"; exit }
  if (!(notes_open_at < notes_close_at && notes_close_at < code_open_at && code_open_at < code_close_at)) { print "out-of-order"; exit }
  if (pre_text) { print "text-before-delimiter"; exit }
  if (mid_text) { print "text-between-sections"; exit }
  if (post_text) { print "text-after-closing-tag"; exit }

  # Strip ONLY an outer fence: the first non-blank line opens it (3 or more
  # backticks, optional info string without backticks) and the last
  # non-blank line closes it (backticks only, at least as many as the
  # opening). Everything in between is kept verbatim, inner fences included.
  first = 0; last = 0
  for (i = 1; i <= nc; i++) if (!blank(code[i])) { first = i; break }
  for (i = nc; i >= 1; i--) if (!blank(code[i])) { last = i; break }
  from = 1; to = nc
  if (first > 0 && last > first) {
    fence_open = code[first]; sub(/[ \t\r]+$/, "", fence_open)
    if (match(fence_open, /^`+/) && RLENGTH >= 3 && substr(fence_open, RLENGTH + 1) !~ /`/) {
      width = RLENGTH
      fence_close = code[last]; sub(/[ \t\r]+$/, "", fence_close)
      if (fence_close ~ /^`+$/ && length(fence_close) >= width) { from = first + 1; to = last - 1 }
    }
  }

  notes_bytes = 0; notes_empty = 1
  for (i = 1; i <= nn; i++) { notes_bytes += length(notes[i]) + 1; if (!blank(notes[i])) notes_empty = 0 }
  code_bytes = 0; code_empty = 1
  for (i = from; i <= to; i++) { code_bytes += length(code[i]) + 1; if (!blank(code[i])) code_empty = 0 }

  if (notes_bytes > ENVIRON["CW_MAX_NOTES"] + 0) { print "oversize"; exit }
  if (code_empty && notes_empty) { print "empty-code"; exit }
  if (code_bytes > ENVIRON["CW_MAX_CODE"] + 0) { print "oversize"; exit }

  notes_out = ENVIRON["CW_NOTES_OUT"]; code_out = ENVIRON["CW_CODE_OUT"]
  printf "" > notes_out
  for (i = 1; i <= nn; i++) print notes[i] >> notes_out
  close(notes_out)
  printf "" > code_out
  if (!code_empty) for (i = from; i <= to; i++) print code[i] >> code_out
  close(code_out)
  print (code_empty ? "deliberate-refusal" : "ok")
}
'

# _shunt_cw_seam <name>
# Test seam, a no-op in production. Called with "after-mkdir" and
# "before-link" so tests can act at the exact moments the TOCTOU window
# opens. Tests redefine this function after sourcing the library.
_shunt_cw_seam() {
  :
}

# The checks below run in Python (scripts/py/shunt/cw_text.py, cw_target.py,
# reached through `shunt_py codewrite <sub>`, see lib/py.sh). The functions here
# are thin wrappers that keep the old names, stdout, stderr text and exit
# codes. Every argument goes after `--`, so a value starting with a dash is not
# read as an option. The yes/no wrappers fail closed: an interpreter that dies
# (exit 2, or 127 when it is missing) counts as a hit, never as "clean".

# shellcheck source=py.sh
source "${BASH_SOURCE[0]%/*}/py.sh"

# _shunt_cw_py_hit <sub> <args...>
# Runs a yes/no check: succeeds on exit 0 (a hit), fails only on exit 10 (none)
# and succeeds on any other status (failing closed). A crashing interpreter can
# exit 1, so 1 does not mean "none".
_shunt_cw_py_hit() {
  local rc=0
  shunt_py codewrite "$@" || rc=$?
  [ "$rc" -ne 10 ]
}

# _shunt_cw_limit <env-var-name> <default>
# Prints the value of the named variable as a decimal number, or the default
# when it is unset, empty, not a plain integer or longer than 15 digits.
_shunt_cw_limit() {
  shunt_py codewrite limit -- "${!1:-}" "$2" || echo "$2"
}

# _shunt_cw_byte_count <file>
# Prints the size of the file in bytes as a bare number.
_shunt_cw_byte_count() {
  echo $(( $(wc -c <"$1") ))
}

# _shunt_cw_canon_dir <absolute-path>
# Prints the physical (symlink-free) absolute path of an existing directory.
# Fails when the path is not a directory or cannot be entered.
_shunt_cw_canon_dir() {
  shunt_py codewrite canon-dir -- "$1"
}

# _shunt_cw_has_unsafe_chars <text>
# Succeeds when the text has a C0 control (a newline included), DEL or ANY
# character that shunt_cw_strip_invisible removes. Used on paths, which are
# refused rather than cleaned.
_shunt_cw_has_unsafe_chars() {
  _shunt_cw_py_hit unsafe -- "$1"
}

# shunt_cw_strip_invisible <text>
# Prints the text without C1 controls, zero width, bidi, filler, variation,
# interlinear, musical and Tag block characters (full list in cw_text.py). C0
# controls and newlines are kept. Works on the raw bytes, to a fixed point.
shunt_cw_strip_invisible() {
  shunt_py codewrite strip-invisible -- "$1"
}

# _shunt_cw_check_text <file>
# _shunt_cw_check_code_controls <code-file>
# _shunt_cw_check_invisible <file>
# _shunt_cw_check_protocol_tags <code-file>
# Each prints a reason token and fails when the file is refused, else succeeds
# silently. text: NUL, raw control, C1, invalid UTF-8, bidi. code_controls: a
# form feed or lone CR. invisible: zero width and format characters (ZWNJ,
# ZWJ and U+FE0F stay allowed). protocol_tags: a whole line that looks like a
# SHUNT-CODE or SHUNT-NOTES tag. Any failure of the interpreter also fails.
_shunt_cw_check_text() { shunt_py codewrite check-text -- "$1"; }
_shunt_cw_check_code_controls() { shunt_py codewrite check-controls -- "$1"; }
_shunt_cw_check_invisible() { shunt_py codewrite check-invisible -- "$1"; }
_shunt_cw_check_protocol_tags() { shunt_py codewrite check-tags -- "$1"; }

# shunt_cw_sensitive_component <slash-separated-path>
# Prints the first component (or, for the few multi-component names, the
# consecutive components joined by a slash) that names a credential, key,
# state or history store and succeeds, fails when there is none. The list is
# in cw_target.py. Case-insensitive in the C locale, trailing dots and spaces
# ignored per component. An interpreter that dies counts as a hit.
shunt_cw_sensitive_component() {
  local out rc=0
  out=$(shunt_py codewrite sensitive -- "$1") || rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" ;;
    10) return 1 ;;
    *) echo "?"; return 0 ;;
  esac
}

# shunt_cw_project_root
# Prints the canonical project root: $CLAUDE_PROJECT_DIR when it is set and a
# directory, else the git top level, else the current directory. A root that
# is the cwd fallback is refused when a component of its path is on the short
# root list or is a sensitive name (the target rule only looks BELOW the root).
shunt_cw_project_root() {
  local dir="" from_cwd=0 canon hit rc
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    dir="$CLAUDE_PROJECT_DIR"
  else
    dir=$(git rev-parse --show-toplevel 2>/dev/null) || dir=""
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
      dir="$PWD"
      from_cwd=1
    fi
  fi
  canon=$(_shunt_cw_canon_dir "$dir") || {
    echo "shunt: cannot resolve the project root '$dir'." >&2
    return 1
  }
  if [ "$from_cwd" -eq 1 ]; then
    rc=0
    hit=$(shunt_py codewrite root-hit -- "$canon") || rc=$?
    if [ "$rc" -ne 10 ]; then
      echo "shunt: refusing to write: there is no git work tree here, so the project root would be the current directory $(printf '%q' "$(shunt_cw_strip_invisible "$canon")"), and its path has the component '$(printf '%q' "$(shunt_cw_strip_invisible "$hit")")' (git, CI, tool config or credential directories are off limits). Run code-write inside a git work tree or export CLAUDE_PROJECT_DIR=<your project directory>." >&2
      return 1
    fi
  fi
  printf '%s\n' "$canon"
}

# _shunt_cw_placement_error <root> <canonical-dir> <tail>
# Succeeds when <canonical-dir> is the root or lies inside it and no component
# of the root-relative path, including the not yet created <tail>, is refused
# by the target rule. Sets _SHUNT_CW_ERR and fails otherwise.
_shunt_cw_placement_error() {
  local out rc=0
  out=$(shunt_py codewrite placement -- "$1" "$2" "$3") || rc=$?
  [ "$rc" -eq 0 ] && return 0
  _SHUNT_CW_ERR="${out:-internal error while checking the placement}"
  return 1
}

# _shunt_cw_resolve <root> <target>
# Pure check, changes nothing on disk. On success sets _SHUNT_CW_ROOT (the
# canonical root), _SHUNT_CW_ANCESTOR (the canonical nearest existing
# ancestor directory), _SHUNT_CW_MISSING (the components still to create, the
# last one being the file name) and _SHUNT_CW_RESOLVED. On refusal sets
# _SHUNT_CW_ERR and fails.
_shunt_cw_resolve() {
  local out line n=0 rc=0
  _SHUNT_CW_ERR=""
  _SHUNT_CW_ROOT=""
  _SHUNT_CW_ANCESTOR=""
  _SHUNT_CW_RESOLVED=""
  _SHUNT_CW_MISSING=()
  out=$(shunt_py codewrite resolve -- "$1" "$2") || rc=$?
  if [ "$rc" -ne 0 ]; then
    _SHUNT_CW_ERR="${out:-internal error while checking the target}"
    return 1
  fi
  # Components never hold a newline (the unsafe character check refuses it).
  while IFS= read -r line; do
    case "$n" in
      0) _SHUNT_CW_ROOT="$line" ;;
      1) _SHUNT_CW_ANCESTOR="$line" ;;
      2) _SHUNT_CW_RESOLVED="$line" ;;
      *) _SHUNT_CW_MISSING+=("$line") ;;
    esac
    n=$((n + 1))
  done <<<"$out"
}

# _shunt_cw_print_refusal <target>
# Prints the refusal for the last failed _shunt_cw_resolve to stderr. The target
# is shown quoted (C0 controls and newlines become visible escapes) and with the
# invisible and bidi characters stripped first, so a refused name can neither
# reorder the line nor carry hidden text.
_shunt_cw_print_refusal() {
  local shown
  # The trailing x keeps the command substitution from eating a trailing newline.
  shown=$(shunt_cw_strip_invisible "$1" && printf x)
  echo "shunt: refusing target $(printf '%q' "${shown%x}"): $_SHUNT_CW_ERR" >&2
}

# shunt_cw_check_target <root> <target>
# Validates a target path without touching the disk. Meant to run BEFORE the
# model call. On success prints the resolved absolute path (canonical
# ancestor plus the components still to create) and returns 0. On refusal
# prints one "shunt: refusing target ..." line to stderr and returns 1.
#
# Refused: empty or over-long target, control characters (newlines
# included), a trailing slash, any '.', '..' or empty component (checked on
# the raw components), any component refused by the target rule (dotted or on
# the short name list) including ones that do not exist yet, an absolute path
# or symlink that resolves outside the root, a nearest existing ancestor that
# is not a directory, and ANY existing target (file, directory, symlink,
# dangling symlink).
shunt_cw_check_target() {
  if ! _shunt_cw_resolve "${1:-}" "${2:-}"; then
    _shunt_cw_print_refusal "${2:-}"
    return 1
  fi
  printf '%s\n' "$_SHUNT_CW_RESOLVED"
}

# shunt_cw_normalize_path <path>
# Prints the path with '.' and empty segments dropped and 'a/..' collapsed,
# purely lexically (a symlink named 'a' is not looked at, the target check
# resolves symlinks afterwards). An absolute path cannot climb above '/'. A
# relative path keeps the '..' it cannot collapse and prints '.' when nothing
# is left. An empty path, a path ending in a slash and one with control
# characters are printed unchanged, so shunt_cw_check_target refuses them as
# before. Meant to run BEFORE shunt_cw_check_target, which stays strict.
shunt_cw_normalize_path() {
  local path="${1:-}" rest part acc="" is_abs=0
  if _shunt_cw_has_unsafe_chars "$path"; then
    printf '%s\n' "$path"
    return 0
  fi
  case "$path" in
    ""|*/) printf '%s\n' "$path"; return 0 ;;
    /*) is_abs=1 ;;
  esac
  rest="$path"
  while :; do
    part="${rest%%/*}"
    case "$part" in
      ''|.) ;;
      ..)
        case "$acc" in
          '') [ "$is_abs" -eq 1 ] || acc=".." ;;
          ..|*/..) acc="$acc/.." ;;
          */*) acc="${acc%/*}" ;;
          *) acc="" ;;
        esac
        ;;
      *) acc="${acc:+$acc/}$part" ;;
    esac
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *) break ;;
    esac
  done
  if [ "$is_abs" -eq 1 ]; then
    printf '/%s\n' "$acc"
  else
    printf '%s\n' "${acc:-.}"
  fi
}

# shunt_cw_parse <response-file> <out-dir>
# Splits a raw model response into <out-dir>/notes and <out-dir>/code.
# Files instead of stdout because the content may be large and binary-ish,
# and a shell variable cannot hold NUL bytes. The caller supplies a
# directory it owns (a mktemp -d one) and removes it afterwards. NOTES is
# untrusted text from the model, the caller should label it as such when it
# shows it to Claude.
#
# Protocol, every tag on a line of its own:
#   <SHUNT-NOTES>
#   the notes
#   </SHUNT-NOTES>
#   <SHUNT-CODE>
#   the file content
#   </SHUNT-CODE>
# Tags are whole-line exact matches (one trailing CR is tolerated, nothing
# else), exactly one of each, in that order. Only blank lines may come before
# the first tag, between the two sections and after the closing CODE tag. A
# reply cut off by a length limit lacks its closing tag, which is why every
# section is closed: the end of the code is a line, not the end of the reply.
# The code is the lines strictly between the CODE tags. Only an outer markdown
# fence around the whole CODE section is removed.
#
# Prints one reason token on stdout, nothing else. Exit status:
#   0   ok, both files written. Reason: ok
#   10  deliberate refusal, empty CODE with non-empty NOTES. Not a model
#       failure. Only <out-dir>/notes is meaningful. Reason: deliberate-refusal
#   11  unusable response, a model failure (failover and breaker). No output
#       files are left. Reasons: empty-response, missing-notes-delimiter,
#       missing-code-delimiter, missing-closing-tag, duplicate-notes-delimiter,
#       duplicate-code-delimiter, duplicate-closing-tag, out-of-order,
#       text-before-delimiter, text-between-sections, text-after-closing-tag,
#       empty-code, oversize, nul-bytes, control-characters, invalid-utf8,
#       bidi-controls, invisible-characters, protocol-tag-in-code
#   2   bad arguments or a missing tool, nothing about the response
shunt_cw_parse() {
  local response="${1:-}" out_dir="${2:-}"
  local max_code max_notes size reason invisible status

  if [ "$#" -ne 2 ] || [ ! -f "$response" ] || [ ! -r "$response" ] \
      || [ ! -d "$out_dir" ] || [ ! -w "$out_dir" ]; then
    echo "shunt: usage: shunt_cw_parse <response-file> <writable-out-dir>" >&2
    return 2
  fi
  command -v iconv >/dev/null 2>&1 || { echo "shunt: 'iconv' not found in PATH." >&2; return 2; }
  command -v awk >/dev/null 2>&1 || { echo "shunt: 'awk' not found in PATH." >&2; return 2; }

  rm -f -- "$out_dir/code" "$out_dir/notes"
  max_code=$(_shunt_cw_limit SHUNT_CW_MAX_CODE_BYTES "$SHUNT_CW_DEFAULT_MAX_CODE_BYTES")
  max_notes=$(_shunt_cw_limit SHUNT_CW_MAX_NOTES_BYTES "$SHUNT_CW_DEFAULT_MAX_NOTES_BYTES")

  size=$(_shunt_cw_byte_count "$response")
  if [ "$size" -eq 0 ]; then
    echo "empty-response"
    return "$SHUNT_CW_EXIT_UNUSABLE"
  fi
  if [ "$size" -gt $((max_code + max_notes + SHUNT_CW_RESPONSE_SLACK_BYTES)) ]; then
    echo "oversize"
    return "$SHUNT_CW_EXIT_UNUSABLE"
  fi
  if ! reason=$(_shunt_cw_check_text "$response"); then
    echo "$reason"
    return "$SHUNT_CW_EXIT_UNUSABLE"
  fi

  reason=$(LC_ALL=C \
    CW_TAG_NOTES_OPEN="$SHUNT_CW_TAG_NOTES_OPEN" CW_TAG_NOTES_CLOSE="$SHUNT_CW_TAG_NOTES_CLOSE" \
    CW_TAG_CODE_OPEN="$SHUNT_CW_TAG_CODE_OPEN" CW_TAG_CODE_CLOSE="$SHUNT_CW_TAG_CODE_CLOSE" \
    CW_MAX_NOTES="$max_notes" CW_MAX_CODE="$max_code" \
    CW_NOTES_OUT="$out_dir/notes" CW_CODE_OUT="$out_dir/code" \
    awk "$_SHUNT_CW_AWK_PROGRAM" "$response") || reason=""

  # Invisible characters, a lone CR, a form feed and a protocol tag line are
  # refused in the code only, NOTES are stripped when printed. Nothing is left
  # behind for a refused answer.
  if [ "$reason" = "ok" ] \
      && ! invisible=$(_shunt_cw_check_code_controls "$out_dir/code" \
        && _shunt_cw_check_invisible "$out_dir/code" \
        && _shunt_cw_check_protocol_tags "$out_dir/code"); then
    rm -f -- "$out_dir/code" "$out_dir/notes"
    echo "$invisible"
    return "$SHUNT_CW_EXIT_UNUSABLE"
  fi

  case "$reason" in
    ok) status=0 ;;
    deliberate-refusal) status="$SHUNT_CW_EXIT_REFUSAL" ;;
    missing-notes-delimiter|missing-code-delimiter|missing-closing-tag \
    |duplicate-notes-delimiter|duplicate-code-delimiter|duplicate-closing-tag \
    |out-of-order|text-before-delimiter|text-between-sections \
    |text-after-closing-tag|empty-code|oversize)
      status="$SHUNT_CW_EXIT_UNUSABLE" ;;
    *)
      rm -f -- "$out_dir/code" "$out_dir/notes"
      echo "shunt: internal error while parsing the response." >&2
      return 2
      ;;
  esac
  echo "$reason"
  return "$status"
}

# shunt_cw_cleanup
# Best effort rollback of a failed or interrupted publish: removes the temp
# file, then removes ONLY the directories this call created, deepest first,
# and only when empty (rmdir refuses otherwise). Never touches anything else.
# Safe to call at any time, it does nothing after a completed publish.
shunt_cw_cleanup() {
  local i
  if [ -n "$_SHUNT_CW_TMP" ]; then
    rm -f -- "$_SHUNT_CW_TMP" 2>/dev/null || :
    _SHUNT_CW_TMP=""
  fi
  i=${#_SHUNT_CW_CREATED[@]}
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    rmdir -- "${_SHUNT_CW_CREATED[$i]}" 2>/dev/null || :
  done
  _SHUNT_CW_CREATED=()
  return 0
}

# _shunt_cw_fail <message>
# Reports a publish failure to stderr, rolls back, returns 1.
_shunt_cw_fail() {
  echo "shunt: cannot write the file: $1" >&2
  shunt_cw_cleanup
  return 1
}

# _shunt_cw_check_code_file <code-file>
# Content gate for publish, the same limits the parser applies. Prints the
# refusal message and fails, or succeeds silently.
_shunt_cw_check_code_file() {
  local size max reason
  size=$(_shunt_cw_byte_count "$1")
  max=$(_shunt_cw_limit SHUNT_CW_MAX_CODE_BYTES "$SHUNT_CW_DEFAULT_MAX_CODE_BYTES")
  if [ "$size" -eq 0 ]; then
    echo "shunt: refusing to write an empty file."
    return 1
  fi
  if [ "$size" -gt "$max" ]; then
    echo "shunt: refusing to write $size bytes, the cap is $max."
    return 1
  fi
  if ! reason=$(_shunt_cw_check_text "$1" && _shunt_cw_check_code_controls "$1" \
      && _shunt_cw_check_invisible "$1" && _shunt_cw_check_protocol_tags "$1"); then
    echo "shunt: refusing to write the content: $reason."
    return 1
  fi
}

# _shunt_cw_make_dirs
# Creates the missing directories one by one (mode 0755) below the resolved
# ancestor, recording each one this call created in _SHUNT_CW_CREATED so a
# rollback removes exactly those. Leaves the deepest directory in
# _SHUNT_CW_DIR. A directory that appeared concurrently is used but never
# recorded as ours.
_shunt_cw_make_dirs() {
  local i n dir="$_SHUNT_CW_ANCESTOR"
  n=${#_SHUNT_CW_MISSING[@]}
  for ((i = 0; i < n - 1; i++)); do
    dir="$dir/${_SHUNT_CW_MISSING[$i]}"
    if mkdir -m 755 -- "$dir" 2>/dev/null; then
      _SHUNT_CW_CREATED+=("$dir")
    elif [ ! -d "$dir" ] || [ -L "$dir" ]; then
      _shunt_cw_fail "cannot create the directory $dir."
      return 1
    fi
  done
  _SHUNT_CW_DIR="$dir"
}

# _shunt_cw_stage_tmp <code-file> <final-name>
# Defense in depth, then the temp file. The final parent must resolve inside
# the root and pass the target rule, and must still be exactly the canonical
# directory we built (a swapped-in symlink to any other directory fails
# here). The temp file lives in the target directory so the publish is a
# same-filesystem link. It is created 0600 under umask 077 and made 0644,
# never with an exec bit. Sets _SHUNT_CW_TMP.
_shunt_cw_stage_tmp() {
  local code_file="$1" final_name="$2" parent_real tmp
  parent_real=$(_shunt_cw_canon_dir "$_SHUNT_CW_DIR") \
    || { _shunt_cw_fail "the parent directory disappeared."; return 1; }
  _shunt_cw_placement_error "$_SHUNT_CW_ROOT" "$parent_real" "$final_name" \
    || { _shunt_cw_fail "$_SHUNT_CW_ERR."; return 1; }
  [ "$parent_real" = "$_SHUNT_CW_DIR" ] \
    || { _shunt_cw_fail "the parent directory changed while publishing."; return 1; }

  tmp=$(umask 077; mktemp "$_SHUNT_CW_DIR/.shunt-cw.XXXXXX" 2>/dev/null) \
    || { _shunt_cw_fail "cannot create a temporary file in $_SHUNT_CW_DIR."; return 1; }
  _SHUNT_CW_TMP="$tmp"
  cat -- "$code_file" >"$tmp" 2>/dev/null \
    || { _shunt_cw_fail "cannot write the temporary file."; return 1; }
  cmp -s -- "$code_file" "$tmp" \
    || { _shunt_cw_fail "the temporary file does not match the content (disk full?)."; return 1; }
  chmod 644 -- "$tmp" \
    || { _shunt_cw_fail "cannot set the file mode."; return 1; }
}

# _shunt_cw_remove_stray <final> <temp-name> <code-file>
# ln and mv put the file INSIDE the destination when it turned out to be a
# directory (or a symlink to one), and report success. Removes that stray
# copy, but only when it really is a byte-identical copy of our content.
_shunt_cw_remove_stray() {
  local stray="$1/$2"
  if [ -d "$1" ] && [ -f "$stray" ] && cmp -s -- "$3" "$stray"; then
    rm -f -- "$stray" 2>/dev/null || :
  fi
}

# _shunt_cw_link_no_clobber <temp> <final> <code-file>
# Publishes the temp file under the final name without ever replacing
# anything. The primary primitive is a hard link (link(2) fails if the name
# exists, dangling symlinks included). When hard links are unavailable it
# falls back to mv -n. In both cases the outcome is verified, never the exit
# status alone: mv -n exits 0 without moving when the target exists, and
# ln or mv given a directory at the final name drop the file inside it.
_shunt_cw_link_no_clobber() {
  local tmp="$1" final="$2" code_file="$3" name="${1##*/}"
  if [ -e "$final" ] || [ -L "$final" ]; then
    return 1
  fi
  if ln -- "$tmp" "$final" 2>/dev/null; then
    if [ -f "$final" ] && [ ! -L "$final" ] && [ "$final" -ef "$tmp" ]; then
      rm -f -- "$tmp" 2>/dev/null || :
      _SHUNT_CW_TMP=""
      return 0
    fi
    _shunt_cw_remove_stray "$final" "$name" "$code_file"
    return 1
  fi
  if [ -e "$final" ] || [ -L "$final" ]; then
    return 1
  fi
  mv -n -- "$tmp" "$final" 2>/dev/null || :
  if [ ! -e "$tmp" ] && [ -f "$final" ] && [ ! -L "$final" ] && cmp -s -- "$code_file" "$final"; then
    _SHUNT_CW_TMP=""
    return 0
  fi
  _shunt_cw_remove_stray "$final" "$name" "$code_file"
  return 1
}

# shunt_cw_publish <root> <target> <code-file>
# Creates the new file. Call it LAST, after a successful model response.
# Prints the final absolute path on success. Returns 1 on any refusal or
# failure (message on stderr, nothing left behind), 2 on bad arguments.
#
# Everything is re-validated here, the early shunt_cw_check_target call is
# only for failing before the model call. Order: content checks, target
# check, mkdir of the missing directories only, re-check of the final
# parent, temp file, then the no-clobber publish. The file ends up 0644 and
# the directories this call creates 0755, whatever the umask.
shunt_cw_publish() {
  local root="${1:-}" target="${2:-}" code_file="${3:-}" message final_name

  if [ "$#" -ne 3 ] || [ ! -f "$code_file" ] || [ ! -r "$code_file" ]; then
    echo "shunt: usage: shunt_cw_publish <root> <target> <readable-code-file>" >&2
    return 2
  fi
  command -v iconv >/dev/null 2>&1 || { echo "shunt: 'iconv' not found in PATH." >&2; return 2; }
  if ! message=$(_shunt_cw_check_code_file "$code_file"); then
    echo "$message" >&2
    return 1
  fi
  if ! _shunt_cw_resolve "$root" "$target"; then
    _shunt_cw_print_refusal "$target"
    return 1
  fi

  _SHUNT_CW_TMP=""
  _SHUNT_CW_CREATED=()
  final_name="${_SHUNT_CW_MISSING[$((${#_SHUNT_CW_MISSING[@]} - 1))]}"
  _shunt_cw_make_dirs || return 1
  _shunt_cw_seam after-mkdir
  _shunt_cw_stage_tmp "$code_file" "$final_name" || return 1
  _shunt_cw_seam before-link
  _shunt_cw_link_no_clobber "$_SHUNT_CW_TMP" "$_SHUNT_CW_DIR/$final_name" "$code_file" \
    || { _shunt_cw_fail "the file could not be published without overwriting (the target appeared or the link was refused), nothing was overwritten."; return 1; }

  _SHUNT_CW_CREATED=()
  printf '%s\n' "$_SHUNT_CW_DIR/$final_name"
}
