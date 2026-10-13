# Safe new-file write core for code-write (docs/TODO.md, "Code-writer").
# The delegate model only returns text. This library is what turns that text
# into a file: it validates the target path, parses the response protocol,
# enforces content limits and publishes the file without ever overwriting.
#
# Meant to be sourced by scripts/code-write. No top-level side effects. Needs
# bash, coreutils and python3 (the checks, the response parser and the publish
# stages run in scripts/py/shunt/cw_*.py, see py.sh).
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
# Residual risk, accepted and to be recorded in the ADR: TOCTOU between the
# publish stages. Each stage works relative to a directory descriptor opened
# with O_NOFOLLOW, and the final link refuses when the staged temp file is not
# in the directory it opens, so a swapped-in symlink or directory cannot
# redirect the write. A change of the directories ABOVE the one we hold is only
# caught by the canonical path re-check of the staging step.

# Exit codes of shunt_cw_parse.
SHUNT_CW_EXIT_REFUSAL=10
SHUNT_CW_EXIT_UNUSABLE=11

# Scratch state shared between the internal helpers. Not part of the API.
_SHUNT_CW_ERR=""
_SHUNT_CW_ROOT=""
_SHUNT_CW_ANCESTOR=""
_SHUNT_CW_RESOLVED=""
_SHUNT_CW_MISSING=()
_SHUNT_CW_DIR=""
_SHUNT_CW_TMP=""
_SHUNT_CW_CREATED=()

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
  shunt_py codewrite normalize -- "${1:-}"
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
  local response="${1:-}" out_dir="${2:-}" reason status=0

  if [ "$#" -ne 2 ] || [ ! -f "$response" ] || [ ! -r "$response" ] \
      || [ ! -d "$out_dir" ] || [ ! -w "$out_dir" ]; then
    echo "shunt: usage: shunt_cw_parse <response-file> <writable-out-dir>" >&2
    return 2
  fi
  reason=$(shunt_py codewrite parse -- "$response" "$out_dir") || status=$?
  case "$status" in
    0|"$SHUNT_CW_EXIT_REFUSAL"|"$SHUNT_CW_EXIT_UNUSABLE")
      echo "$reason"
      return "$status"
      ;;
    *)
      rm -f -- "$out_dir/code" "$out_dir/notes"
      echo "shunt: internal error while parsing the response." >&2
      return 2
      ;;
  esac
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
# refusal message and fails, or succeeds silently. Fails closed if Python dies.
_shunt_cw_check_code_file() {
  local out rc=0
  out=$(shunt_py codewrite check-code-file -- "$1") || rc=$?
  [ "$rc" -eq 0 ] && return 0
  echo "${out:-shunt: refusing to write the content: internal error.}"
  return 1
}

# The publish stages run in Python (scripts/py/shunt/cw_publish.py). Each one
# rolls back what it created when it fails or gets a signal. Bash keeps the
# order, the test seam between the stages and the rollback record
# (_SHUNT_CW_TMP, _SHUNT_CW_CREATED) for shunt_cw_cleanup. A failed stage prints
# its reason on stdout and exits non-zero (any non-zero status is a failure).

# _shunt_cw_make_dirs
# Creates the missing directories one by one (mode 0755) below the resolved
# ancestor, recording each one this call created in _SHUNT_CW_CREATED. Leaves
# the deepest directory in _SHUNT_CW_DIR. A directory that appeared
# concurrently is used but never recorded as ours.
_shunt_cw_make_dirs() {
  local out line n=0 rc=0
  out=$(shunt_py codewrite make-dirs -- "$_SHUNT_CW_ANCESTOR" "${_SHUNT_CW_MISSING[@]}") || rc=$?
  if [ "$rc" -ne 0 ]; then
    _shunt_cw_fail "${out:-internal error while creating the directories.}"
    return 1
  fi
  while IFS= read -r line; do
    if [ "$n" -eq 0 ]; then _SHUNT_CW_DIR="$line"; else _SHUNT_CW_CREATED+=("$line"); fi
    n=$((n + 1))
  done <<<"$out"
}

# _shunt_cw_stage_tmp <code-file> <final-name>
# Re-checks the final parent (inside the root, passes the target rule, still
# exactly the directory we built), then writes the temp file 0600 and makes it
# 0644 in the target directory. The name is chosen here, before the stage
# runs, so a rollback knows it even when a signal lands in between. Sets
# _SHUNT_CW_TMP.
_shunt_cw_stage_tmp() {
  local out rc=0 name=".shunt-cw.$$.$RANDOM$RANDOM$RANDOM"
  _SHUNT_CW_TMP="$_SHUNT_CW_DIR/$name"
  out=$(shunt_py codewrite stage-tmp -- "$_SHUNT_CW_ROOT" "$_SHUNT_CW_DIR" "$2" "$1" "$name") || rc=$?
  if [ "$rc" -ne 0 ]; then
    _shunt_cw_fail "${out:-internal error while writing the temporary file.}"
    return 1
  fi
}

# _shunt_cw_link_no_clobber <temp> <final>
# Publishes the temp file under the final name without ever replacing
# anything (hard link, which fails if the name exists, dangling symlinks
# included). Succeeds only when the outcome was verified. The temp file is
# gone afterwards either way.
_shunt_cw_link_no_clobber() {
  if shunt_py codewrite link -- "${1%/*}" "${1##*/}" "${2##*/}" >/dev/null; then
    _SHUNT_CW_TMP=""
    return 0
  fi
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
  _shunt_cw_link_no_clobber "$_SHUNT_CW_TMP" "$_SHUNT_CW_DIR/$final_name" \
    || { _shunt_cw_fail "the file could not be published without overwriting (the target appeared or the link was refused), nothing was overwritten."; return 1; }

  _SHUNT_CW_CREATED=()
  printf '%s\n' "$_SHUNT_CW_DIR/$final_name"
}
