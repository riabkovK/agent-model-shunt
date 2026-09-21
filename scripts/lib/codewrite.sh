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
# Allowance for delimiters, fence lines and CRLF on top of the two caps when
# bounding the raw response size before it is split.
SHUNT_CW_RESPONSE_SLACK_BYTES=4096
# PATH_MAX. A longer target is refused before anything is created.
SHUNT_CW_MAX_TARGET_BYTES=4096

# Exit codes of shunt_cw_parse.
SHUNT_CW_EXIT_REFUSAL=10
SHUNT_CW_EXIT_UNUSABLE=11

SHUNT_CW_DELIM_NOTES='<<<SHUNT-NOTES>>>'
SHUNT_CW_DELIM_CODE='<<<SHUNT-CODE>>>'

# Scratch state shared between the internal helpers. Not part of the API.
_SHUNT_CW_ERR=""
_SHUNT_CW_ROOT=""
_SHUNT_CW_BASE=""
_SHUNT_CW_ANCESTOR=""
_SHUNT_CW_RESOLVED=""
_SHUNT_CW_MISSING=()
_SHUNT_CW_PARTS=()
_SHUNT_CW_DIR=""
_SHUNT_CW_TMP=""
_SHUNT_CW_CREATED=()

# Splits the response in one pass. Reads the two delimiter lines and the
# limits from the environment, writes the notes and code files itself and
# prints one reason token. Kept as data so that sourcing stays free of side
# effects. Byte counts rely on the caller setting LC_ALL=C.
_SHUNT_CW_AWK_PROGRAM='
function blank(s) { return s ~ /^[ \t\r]*$/ }
BEGIN {
  section = 0
  d_notes = ENVIRON["CW_DELIM_NOTES"]
  d_code = ENVIRON["CW_DELIM_CODE"]
}
{
  line = $0
  sub(/\r$/, "", line)
  if (line == d_notes) { notes_count++; if (!notes_first) notes_first = NR; section = 1; next }
  if (line == d_code) { code_count++; if (!code_first) code_first = NR; section = 2; next }
  if (section == 0) { if (!blank($0)) pre_text = 1; next }
  if (section == 1) { nn++; notes[nn] = $0 } else { nc++; code[nc] = $0 }
}
END {
  if (!notes_count) { print "missing-notes-delimiter"; exit }
  if (!code_count) { print "missing-code-delimiter"; exit }
  if (notes_count > 1) { print "duplicate-notes-delimiter"; exit }
  if (code_count > 1) { print "duplicate-code-delimiter"; exit }
  if (code_first < notes_first) { print "out-of-order"; exit }
  if (pre_text) { print "text-before-delimiter"; exit }

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

# _shunt_cw_limit <env-var-name> <default>
# Prints the value of the named variable as a decimal number, or the default
# when it is unset, empty, not a plain integer or too long to be safe in
# shell arithmetic. The 10# prefix keeps a leading zero from reading as octal.
_shunt_cw_limit() {
  local value="${!1:-}"
  case "$value" in
    ''|*[!0-9]*) echo "$2" ;;
    *)
      if [ "${#value}" -gt 15 ]; then
        echo "$2"
      else
        echo $((10#$value))
      fi
      ;;
  esac
}

# _shunt_cw_byte_count <file>
# Prints the size of the file in bytes as a bare number.
_shunt_cw_byte_count() {
  echo $(( $(wc -c <"$1") ))
}

# _shunt_cw_canon_dir <absolute-path>
# Prints the physical (symlink-free) absolute path of an existing directory.
# Fails when the path is not a directory or cannot be entered. Callers only
# pass absolute paths, so a leading dash cannot be read as "cd -".
_shunt_cw_canon_dir() {
  (CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P)
}

# _shunt_cw_has_bidi_controls <file>
# Succeeds when the file contains a Unicode bidirectional override or isolate
# (U+202A to U+202E, U+2066 to U+2069). They let source code render
# differently from what a compiler reads ("Trojan Source").
_shunt_cw_has_bidi_controls() {
  local args=() seq
  for seq in '\342\200\252' '\342\200\253' '\342\200\254' '\342\200\255' '\342\200\256' \
      '\342\201\246' '\342\201\247' '\342\201\250' '\342\201\251'; do
    args+=(-e "$(printf "$seq")")
  done
  LC_ALL=C grep -aqF "${args[@]}" "$1"
}

# _shunt_cw_has_c1_controls <file>
# Succeeds when the file contains a C1 control character (U+0080 to U+009F,
# the UTF-8 bytes C2 80 to C2 9F). Some terminals act on them (U+009B is a
# CSI, an escape sequence introducer), so they get the same treatment as the
# C0 controls. Fixed byte sequences, so the answer does not depend on the
# locale or on the grep implementation. A raw C2 byte is always a lead byte in
# valid UTF-8, so valid text has no false hit.
_shunt_cw_has_c1_controls() {
  local args=() tens ones
  for tens in 0 1 2 3; do
    for ones in 0 1 2 3 4 5 6 7; do
      args+=(-e "$(printf "\\302\\2$tens$ones")")
    done
  done
  LC_ALL=C grep -aqF "${args[@]}" "$1"
}

# shunt_cw_strip_invisible <text>
# Prints the text without the characters that hide or reorder what a reader
# sees:
#   C1 controls                        U+0080 to U+009F
#   soft hyphen, grapheme joiner       U+00AD, U+034F
#   Arabic letter mark                 U+061C
#   filler characters                  U+115F, U+1160 (Hangul), U+17B4, U+17B5
#                                      (Khmer), U+3164, U+FFA0, U+2800 (Braille
#                                      blank)
#   Mongolian vowel separator          U+180E
#   zero width and format characters   U+200B to U+200F, U+2060 to U+2064, the
#                                      BOM U+FEFF, U+2065 and U+206A to U+206F
#   line and paragraph separators      U+2028, U+2029
#   bidi overrides and isolates        U+202A to U+202E, U+2066 to U+2069
#   variation selectors                U+FE00 to U+FE0F, U+E0100 to U+E01EF
#   interlinear annotation marks       U+FFF9 to U+FFFB
#   musical formatting characters      U+1D173 to U+1D17A
#   the Unicode Tag block              U+E0000 to U+E007F
# The zero width joiner and non-joiner (U+200C, U+200D) and U+FE0F are in the
# list, so they are stripped here. Only generated code may keep them (emoji
# sequences), see _shunt_cw_has_invisible_chars.
# Everything else, C0 controls and newlines included, is kept as it is.
# Works on the raw bytes in the C locale, so it gives the same answer under
# any LC_ALL and with any tr, sed or grep. Runs to a fixed point: removing one
# sequence can join the bytes around it into a new one (a sequence nested in
# another), and one pass would leave that behind.
shunt_cw_strip_invisible() {
  local LC_ALL=C s="$1" prev pat
  local pats=(
    $'\xc2[\x80-\x9f\xad]'
    $'\xcd\x8f'
    $'\xd8\x9c'
    $'\xe1\x85[\x9f\xa0]'
    $'\xe1\x9e[\xb4\xb5]'
    $'\xe1\xa0\x8e'
    $'\xe2\x80[\x8b-\x8f\xa8-\xae]'
    $'\xe2\x81[\xa0-\xaf]'
    $'\xe2\xa0\x80'
    $'\xe3\x85\xa4'
    $'\xef\xb8[\x80-\x8f]'
    $'\xef\xbb\xbf'
    $'\xef\xbe\xa0'
    $'\xef\xbf[\xb9-\xbb]'
    $'\xf0\x9d\x85[\xb3-\xba]'
    $'\xf3\xa0[\x80\x81\x84-\x86][\x80-\xbf]'
    $'\xf3\xa0\x87[\x80-\xaf]'
  )
  while :; do
    prev="$s"
    for pat in "${pats[@]}"; do
      s="${s//$pat/}"
    done
    [ "$s" != "$prev" ] || break
  done
  printf '%s' "$s"
}

# _shunt_cw_has_unsafe_chars <text>
# Succeeds when the text has a C0 control (a newline included), DEL or ANY
# character that shunt_cw_strip_invisible removes (see its list, U+200C, U+200D
# and U+FE0F count here). Used on paths, which are refused rather than
# cleaned, and on the raw --target value BEFORE normalization (normalizing
# would drop a trailing newline). Byte based, so unlike [[:cntrl:]] it does not
# change with the locale (in a UTF-8 locale the class misses U+202E, in the C
# locale it misses the C1 controls).
_shunt_cw_has_unsafe_chars() {
  local LC_ALL=C
  case "$1" in
    *[$'\001'-$'\037\177']*) return 0 ;;
  esac
  [ "$(shunt_cw_strip_invisible "$1")" != "$1" ]
}

# _shunt_cw_has_invisible_chars <file>
# Succeeds when the file holds a character that shunt_cw_strip_invisible
# removes (zero width and format characters, separators, the Tag block, filler
# characters, variation selectors and the rest of its list), except U+200C,
# U+200D and U+FE0F, which stay allowed in code because emoji sequences and
# some scripts need them. Derived from shunt_cw_strip_invisible on purpose, so
# the two lists cannot drift apart. The exceptions are dropped first, which is
# safe because the caller has already checked that the file is valid UTF-8
# (removing whole characters cannot join bytes into a new sequence). The
# trailing x keeps the command substitution from eating trailing newlines. A
# file that cannot be read counts as a hit.
_shunt_cw_has_invisible_chars() {
  local LC_ALL=C content kept
  content=$(cat -- "$1" 2>/dev/null && printf x) || return 0
  kept="${content//$'\xe2\x80\x8c'/}"
  kept="${kept//$'\xe2\x80\x8d'/}"
  kept="${kept//$'\xef\xb8\x8f'/}"
  [ "$(shunt_cw_strip_invisible "$kept")" != "$kept" ]
}

# _shunt_cw_check_invisible <file>
# Prints "invisible-characters" and fails when _shunt_cw_has_invisible_chars
# does. Generated CODE is refused for these (a reader cannot see them, and
# the Tag block is a known channel for hidden instructions). NOTES are not
# refused, they are stripped when printed.
_shunt_cw_check_invisible() {
  if _shunt_cw_has_invisible_chars "$1"; then
    echo "invisible-characters"
    return 1
  fi
  return 0
}

# _shunt_cw_has_lone_cr_or_ff <file>
# Succeeds when the file holds a form feed, or a carriage return that is not
# immediately followed by a line feed (a CR at the very end of the file counts
# as lone). A line such as "x=1<CR>EVIL" renders as "EVIL" in a terminal or a
# diff while the file holds both parts. CRLF line endings are fine. The
# trailing x keeps the command substitution from eating trailing newlines and
# makes a final CR lone. A file that cannot be read counts as a hit.
_shunt_cw_has_lone_cr_or_ff() {
  local LC_ALL=C content
  content=$(cat -- "$1" 2>/dev/null && printf x) || return 0
  content="${content//$'\r\n'/}"
  case "$content" in
    *[$'\r\f']*) return 0 ;;
  esac
  return 1
}

# _shunt_cw_check_code_controls <code-file> [<response-file>]
# Prints "control-characters" and fails when _shunt_cw_has_lone_cr_or_ff does
# on the code. With a response file it also fails when that file ends in a
# bare CR, because the parser writes every code line with a line feed and
# would turn a final "abc<CR>" into a CRLF ending. Generated CODE is refused
# for these, _shunt_cw_check_text keeps them for the NOTES part, which strips
# them when printed.
_shunt_cw_check_code_controls() {
  if _shunt_cw_has_lone_cr_or_ff "$1"; then
    echo "control-characters"
    return 1
  fi
  if [ -n "${2:-}" ] && [ "$(tail -c 1 -- "$2" | LC_ALL=C tr -cd '\r' | wc -c)" -eq 1 ]; then
    echo "control-characters"
    return 1
  fi
  return 0
}

# _shunt_cw_check_text <file>
# Prints a reason token and fails when the file has NUL bytes, other raw
# control characters (everything below 0x20 except tab, line feed, form feed
# and carriage return, plus DEL), C1 controls (U+0080 to U+009F), bidi
# controls, or is not valid UTF-8. The invisible and format characters are a
# separate gate for the code part only, see _shunt_cw_check_invisible, and so
# are a lone CR and a form feed, see _shunt_cw_check_code_controls. The
# UTF-8 test is a strict round trip through UTF-16, compared byte for byte
# with the input. A plain UTF-8 to UTF-8 conversion is not used: the musl
# iconv in the Alpine test image silently drops invalid bytes and exits 0,
# and glibc lets some out-of-range sequences through.
_shunt_cw_check_text() {
  local size kept
  size=$(_shunt_cw_byte_count "$1")
  kept=$(( $(LC_ALL=C tr -d '\000' <"$1" | wc -c) ))
  if [ "$size" -ne "$kept" ]; then
    echo "nul-bytes"
    return 1
  fi
  kept=$(( $(LC_ALL=C tr -d '\001-\010\013\016-\037\177' <"$1" | wc -c) ))
  if [ "$size" -ne "$kept" ]; then
    echo "control-characters"
    return 1
  fi
  if _shunt_cw_has_c1_controls "$1"; then
    echo "control-characters"
    return 1
  fi
  if ! iconv -f UTF-8 -t UTF-16LE <"$1" 2>/dev/null \
      | iconv -f UTF-16LE -t UTF-8 2>/dev/null \
      | cmp -s - "$1"; then
    echo "invalid-utf8"
    return 1
  fi
  if _shunt_cw_has_bidi_controls "$1"; then
    echo "bidi-controls"
    return 1
  fi
  return 0
}

# shunt_cw_sensitive_component <slash-separated-path>
# Prints the first component (or, for the few multi-component names, the
# consecutive components joined by a slash) that names a credential, key,
# state or history store and succeeds, fails when there is none. The files are
# sent to a third-party model, and a script run through the Bash tool is not
# subject to Claude Code's Read deny rules, so the obvious secret stores are
# refused here. Covered: .env files, ssh, gpg, aws, azure, kube, docker, gcloud
# (.config/gcloud and application_default_credentials.json), gh, vault and
# pass stores, netrc, npmrc, pypirc, s3cfg, boto, terraform state and
# variable files, keepass, private keys and certificates, ssh host keys,
# shell and tool history, and this plugin's and OpenCode's own config and
# auth. Also covered:
#   secret files     secrets.json|yml|yaml, .dev.vars*, serviceAccountKey.json,
#                    *-credentials.json, client_secret_*.json,
#                    firebase-adminsdk-*.json, wrangler.toml,
#                    local.settings.json
#   tool config      .yarnrc, .yarnrc.yml, .gitconfig, .my.cnf, _netrc,
#                    .authinfo*, .terraformrc, .claude.json, .composer/auth.json,
#                    .m2/settings.xml
#   key material     *.gpg, *.ppk, *.p8, *.asc, *.ovpn
#   config dirs      .config/rclone, .config/doctl, .config/heroku,
#                    .config/op, .config/sops
# The `credentials.*`, `*.key` and `id_rsa*` patterns are broad on
# purpose, a false refusal costs one flag while a leaked key cannot be
# recalled. Case-insensitive, in the C locale, and trailing dots and spaces
# are ignored per component (Windows treats '.git.' as '.git'). Empty and
# dot-only components are skipped.
shunt_cw_sensitive_component() {
  local rest part trimmed prev="" prev2=""
  rest=$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z')
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    trimmed="${part%"${part##*[!. ]}"}"
    if [ -n "$trimmed" ]; then
      case "$trimmed" in
        .env*|*.env|.ssh|.aws|.azure|.gnupg|.kube|.netrc|.npmrc|.pypirc|.git-credentials|.docker) echo "$trimmed"; return 0 ;;
        .git|.claude|.mcp.json|.htpasswd|.pgpass|.credentials.json|.*history) echo "$trimmed"; return 0 ;;
        .vault-token|.password-store|.dockercfg|.s3cfg|.boto|application_default_credentials.json) echo "$trimmed"; return 0 ;;
        *.tfstate|*.tfstate.*|*.tfvars|*.tfvars.json|*.kdbx) echo "$trimmed"; return 0 ;;
        id_rsa*|id_dsa*|id_ecdsa*|id_ed25519*|ssh_host_*_key|*.pem|*.key|*.p12|*.pfx|*.keystore|*.jks) echo "$trimmed"; return 0 ;;
        credentials|credentials.*|*.credentials) echo "$trimmed"; return 0 ;;
        secrets.json|secrets.yml|secrets.yaml|.dev.vars*|serviceaccountkey.json|*-credentials.json) echo "$trimmed"; return 0 ;;
        client_secret_*.json|firebase-adminsdk-*.json|wrangler.toml|local.settings.json) echo "$trimmed"; return 0 ;;
        .yarnrc|.yarnrc.yml|.gitconfig|.my.cnf|_netrc|.authinfo*|.terraformrc|.claude.json) echo "$trimmed"; return 0 ;;
        *.gpg|*.ppk|*.p8|*.asc|*.ovpn) echo "$trimmed"; return 0 ;;
      esac
      case "$prev/$trimmed" in
        .config/gh|.config/gcloud|.config/opencode|.config/agent-model-shunt) echo "$prev/$trimmed"; return 0 ;;
        .config/rclone|.config/doctl|.config/heroku|.config/op|.config/sops) echo "$prev/$trimmed"; return 0 ;;
        .composer/auth.json|.m2/settings.xml) echo "$prev/$trimmed"; return 0 ;;
      esac
      case "$prev2/$prev/$trimmed" in
        .local/share/opencode) echo "$prev2/$prev/$trimmed"; return 0 ;;
      esac
      prev2="$prev"
      prev="$trimmed"
    fi
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *) rest="" ;;
    esac
  done
  return 1
}

# shunt_cw_project_root
# Prints the canonical project root: $CLAUDE_PROJECT_DIR when it is set and a
# directory, else the git top level, else the current directory. Note that
# Claude Code does not export CLAUDE_PROJECT_DIR to Bash tool commands (only
# to hooks), so in practice the git top level or the cwd decides.
#
# The target rule only looks BELOW the root, so a root that itself sits
# inside a dotted or sensitive directory would make that directory
# writable (the cwd inside .git, or in ~/.claude or ~/.ssh, none of which is
# a git work tree). When the root is the cwd fallback, ANY component of its
# path on the short root list (_shunt_cw_find_denied_root, not the dot rule,
# which would refuse a cwd below ~/.cache) or the sensitive names is refused. A root from
# CLAUDE_PROJECT_DIR or from the git top level is an explicit choice, so a
# git worktree below .claude/worktrees keeps working.
shunt_cw_project_root() {
  local dir="" from_cwd=0 canon hit
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
  if [ "$from_cwd" -eq 1 ] && hit=$(_shunt_cw_find_denied_root "${canon#/}" || shunt_cw_sensitive_component "${canon#/}"); then
    echo "shunt: refusing to write: there is no git work tree here, so the project root would be the current directory $(printf '%q' "$(shunt_cw_strip_invisible "$canon")"), and its path has the component '$(printf '%q' "$(shunt_cw_strip_invisible "$hit")")' (git, CI, tool config or credential directories are off limits). Run code-write inside a git work tree or export CLAUDE_PROJECT_DIR=<your project directory>." >&2
    return 1
  fi
  printf '%s\n' "$canon"
}

# _shunt_cw_split_path <relative-path>
# Splits a path into _SHUNT_CW_PARTS BEFORE any normalization, so that '.',
# '..' and empty components are refused as such and never silently resolved.
# Sets _SHUNT_CW_ERR and fails on a bad component.
_shunt_cw_split_path() {
  local rest="$1" part
  _SHUNT_CW_PARTS=()
  while :; do
    part="${rest%%/*}"
    case "$part" in
      '') _SHUNT_CW_ERR="the path has an empty component"; return 1 ;;
      .) _SHUNT_CW_ERR="the path has a '.' component"; return 1 ;;
      ..) _SHUNT_CW_ERR="the path has a '..' component"; return 1 ;;
    esac
    _SHUNT_CW_PARTS+=("$part")
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *) break ;;
    esac
  done
}

# _shunt_cw_find_denied <slash-separated-path>
# Prints the first component of a TARGET path that code-write must not write
# to and succeeds. Fails when there is none. The rule is structural:
#   1. any component that starts with a dot, after trailing dots and spaces
#      are trimmed (.git .github .claude .env .envrc .mcp.json .husky .vscode
#      .cursorrules .npmrc .config .local and any dotted name to come). A
#      component that trims down to nothing, like '...', counts as dotted.
#      A component that is exactly '.' or '..' is not decided here, the split
#      step refuses those with their own messages, and neither is an empty one.
#   2. a short fixed list of non-dot names that steer the agent or the build
#      when written without a permission prompt: claude.md, claude.local.md,
#      agents.md, gemini.md, jenkinsfile, opencode.json, makefile,
#      gnumakefile, justfile, rakefile, vagrantfile, conftest.py.
# Both are matched as whole components at any depth. Matching is
# case-insensitive (a case-insensitive filesystem makes '.GIT' the same as
# '.git') and ignores trailing dots and spaces (Windows treats '.git.' as
# '.git'). The case fold runs in the C locale on purpose, in a Turkish locale
# 'I' would not lower to 'i'. A target like this has to be written by Claude
# itself with the Write tool, which asks for permission.
_shunt_cw_find_denied() {
  local rest part trimmed
  rest=$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z')
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    case "$part" in
      ''|.|..) ;;
      *)
        trimmed="${part%"${part##*[!. ]}"}"
        case "$trimmed" in
          ''|.*) echo "${trimmed:-$part}"; return 0 ;;
          claude.md|claude.local.md|agents.md|gemini.md|jenkinsfile|opencode.json|makefile|gnumakefile|justfile|rakefile|vagrantfile|conftest.py) echo "$trimmed"; return 0 ;;
        esac
        ;;
    esac
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *) rest="" ;;
    esac
  done
  return 1
}

# _shunt_cw_find_denied_root <slash-separated-path>
# The check for a project root that fell back to the current directory. It
# must not use the dot rule of _shunt_cw_find_denied, that would refuse every
# cwd below a dotted ancestor such as ~/.cache or ~/.dotfiles. It refuses only
# a short fixed list, matched on whole components with the same C-locale case
# fold and trailing dot and space trim: .git .claude .github .config .local
# .ssh .gnupg .aws .kube. Prints the first hit and succeeds, else fails.
_shunt_cw_find_denied_root() {
  local rest part trimmed
  rest=$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z')
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    trimmed="${part%"${part##*[!. ]}"}"
    case "$trimmed" in
      .git|.claude|.github|.config|.local|.ssh|.gnupg|.aws|.kube) echo "$trimmed"; return 0 ;;
    esac
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *) rest="" ;;
    esac
  done
  return 1
}

# _shunt_cw_denied_error <slash-separated-path>
# Sets _SHUNT_CW_ERR and succeeds when the path hits the target rule.
_shunt_cw_denied_error() {
  local denied
  if denied=$(_shunt_cw_find_denied "$1"); then
    _SHUNT_CW_ERR="the path component '$denied' is not allowed (dotted names such as .git, .github, .claude, .env* and .mcp.json, and CLAUDE.md, AGENTS.md, GEMINI.md, opencode.json, Jenkinsfile and Makefile are off limits). A target like this must be written by Claude itself with the Write tool, which asks for permission, not by code-write"
    return 0
  fi
  return 1
}

# _shunt_cw_placement_error <root> <canonical-dir> <tail>
# Succeeds when <canonical-dir> is the root or lies inside it (compared on
# whole path components, so /tmp/proj-evil is not inside /tmp/proj) and no
# component of the root-relative path, including the not yet created <tail>,
# is refused by the target rule. Sets _SHUNT_CW_ERR and fails otherwise.
_shunt_cw_placement_error() {
  local root="$1" canon="$2" tail="$3" rel
  case "$canon" in
    "$root"|"$root"/*) ;;
    *) _SHUNT_CW_ERR="it resolves outside the project root"; return 1 ;;
  esac
  rel="${canon#"$root"}"
  rel="${rel#/}"
  if [ -n "$tail" ]; then
    rel="${rel:+$rel/}$tail"
  fi
  if _shunt_cw_denied_error "$rel"; then
    return 1
  fi
  return 0
}

# _shunt_cw_prepare <root> <target>
# The purely lexical half of the target check. Sets _SHUNT_CW_ROOT (the
# canonical root), _SHUNT_CW_BASE (the directory the walk starts from) and
# _SHUNT_CW_PARTS. Sets _SHUNT_CW_ERR and fails on any refusal.
_shunt_cw_prepare() {
  local root_in="$1" target="$2" root path

  case "$root_in" in
    /*) ;;
    *) _SHUNT_CW_ERR="the project root must be an absolute path"; return 1 ;;
  esac
  if _shunt_cw_has_unsafe_chars "$root_in"; then
    _SHUNT_CW_ERR="the project root path contains control characters or invisible Unicode characters"
    return 1
  fi
  root=$(_shunt_cw_canon_dir "$root_in") || {
    _SHUNT_CW_ERR="the project root '$root_in' is not a directory"
    return 1
  }
  if [ "$root" = "/" ]; then
    _SHUNT_CW_ERR="the project root is the filesystem root"
    return 1
  fi
  if _shunt_cw_has_unsafe_chars "$root"; then
    _SHUNT_CW_ERR="the project root path contains control characters or invisible Unicode characters"
    return 1
  fi
  if [ -z "$target" ]; then
    _SHUNT_CW_ERR="the target is empty"
    return 1
  fi
  if [ "${#target}" -gt "$SHUNT_CW_MAX_TARGET_BYTES" ]; then
    _SHUNT_CW_ERR="the target is longer than $SHUNT_CW_MAX_TARGET_BYTES characters"
    return 1
  fi
  if _shunt_cw_has_unsafe_chars "$target"; then
    _SHUNT_CW_ERR="the target contains control characters or invisible Unicode characters"
    return 1
  fi
  case "$target" in
    */) _SHUNT_CW_ERR="the target ends with a slash"; return 1 ;;
  esac

  _SHUNT_CW_ROOT="$root"
  _SHUNT_CW_BASE="$root"
  path="$target"
  case "$target" in
    /*)
      # Validate the components of the whole absolute path first. Then, when
      # it is spelled under the canonical root, walk from the root using only
      # the part below it. Any other absolute spelling (an alias reaching the
      # root through a symlink) walks from / and gets the lexical target rule on
      # its full path, which is stricter than needed but never lax.
      _shunt_cw_split_path "${target#/}" || return 1
      case "$target" in
        "$root"/*) path="${target#"$root"/}" ;;
        *) _SHUNT_CW_BASE="/"; path="${target#/}" ;;
      esac
      ;;
  esac
  # Lexical target-rule pass over the components as given, on top of the
  # canonical pass later: a symlink named .claude that points to an innocent
  # directory must still be refused.
  if _shunt_cw_denied_error "$path"; then
    return 1
  fi
  _shunt_cw_split_path "$path"
}

# _shunt_cw_resolve <root> <target>
# Pure check, changes nothing on disk. On success sets _SHUNT_CW_ROOT (the
# canonical root), _SHUNT_CW_ANCESTOR (the canonical nearest existing
# ancestor directory), _SHUNT_CW_MISSING (the components still to create, the
# last one being the file name) and _SHUNT_CW_RESOLVED. On refusal sets
# _SHUNT_CW_ERR and fails.
_shunt_cw_resolve() {
  local cur next canon joined="" i=0 n k
  _SHUNT_CW_ERR=""
  _SHUNT_CW_ROOT=""
  _SHUNT_CW_BASE=""
  _SHUNT_CW_ANCESTOR=""
  _SHUNT_CW_RESOLVED=""
  _SHUNT_CW_MISSING=()
  _shunt_cw_prepare "$1" "$2" || return 1

  # Walk down while components exist. A dangling symlink counts as existing.
  cur="$_SHUNT_CW_BASE"
  n=${#_SHUNT_CW_PARTS[@]}
  while [ "$i" -lt "$n" ]; do
    next="${cur%/}/${_SHUNT_CW_PARTS[$i]}"
    if [ -e "$next" ] || [ -L "$next" ]; then
      cur="$next"
      i=$((i + 1))
    else
      break
    fi
  done
  if [ "$i" -eq "$n" ]; then
    if [ "$_SHUNT_CW_BASE" = "/" ]; then
      # Same answer as for a missing path outside the root, so the message
      # does not tell whether an arbitrary file exists.
      _SHUNT_CW_ERR="it is not a new path inside the project root"
    else
      _SHUNT_CW_ERR="it already exists (code-write only creates new files)"
    fi
    return 1
  fi

  canon=$(_shunt_cw_canon_dir "$cur") || {
    _SHUNT_CW_ERR="'$cur' exists but is not a directory that can be entered (a file, or a dangling or broken symlink)"
    return 1
  }
  if _shunt_cw_has_unsafe_chars "$canon"; then
    _SHUNT_CW_ERR="the resolved directory contains control characters or invisible Unicode characters"
    return 1
  fi
  for ((k = i; k < n; k++)); do
    _SHUNT_CW_MISSING+=("${_SHUNT_CW_PARTS[$k]}")
    joined="${joined:+$joined/}${_SHUNT_CW_PARTS[$k]}"
  done
  _shunt_cw_placement_error "$_SHUNT_CW_ROOT" "$canon" "$joined" || return 1

  _SHUNT_CW_ANCESTOR="$canon"
  _SHUNT_CW_RESOLVED="${canon%/}/$joined"
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
# the short name list) including ones that do
# not exist yet, an absolute path or symlink that resolves outside the root,
# a nearest existing ancestor that is not a directory, and ANY existing
# target (file, directory, symlink, dangling symlink).
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
# Protocol: whitespace, then a line "<<<SHUNT-NOTES>>>", the notes, a line
# "<<<SHUNT-CODE>>>", the code. Delimiters are whole-line exact matches (one
# trailing CR is tolerated, nothing else), exactly one of each, NOTES first.
# Only an outer markdown fence around the whole CODE section is removed.
#
# Prints one reason token on stdout, nothing else. Exit status:
#   0   ok, both files written. Reason: ok
#   10  deliberate refusal, empty CODE with non-empty NOTES. Not a model
#       failure. Only <out-dir>/notes is meaningful. Reason: deliberate-refusal
#   11  unusable response, a model failure (failover and breaker). No output
#       files are left. Reasons: empty-response, missing-notes-delimiter,
#       missing-code-delimiter, duplicate-notes-delimiter,
#       duplicate-code-delimiter, out-of-order, text-before-delimiter,
#       empty-code, oversize, nul-bytes, control-characters, invalid-utf8,
#       bidi-controls
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
    CW_DELIM_NOTES="$SHUNT_CW_DELIM_NOTES" CW_DELIM_CODE="$SHUNT_CW_DELIM_CODE" \
    CW_MAX_NOTES="$max_notes" CW_MAX_CODE="$max_code" \
    CW_NOTES_OUT="$out_dir/notes" CW_CODE_OUT="$out_dir/code" \
    awk "$_SHUNT_CW_AWK_PROGRAM" "$response") || reason=""

  # Invisible characters, a lone CR and a form feed are refused in the code
  # only, NOTES are stripped when printed. Nothing is left behind for a
  # refused answer.
  if [ "$reason" = "ok" ] \
      && ! invisible=$(_shunt_cw_check_code_controls "$out_dir/code" "$response" \
        && _shunt_cw_check_invisible "$out_dir/code"); then
    rm -f -- "$out_dir/code" "$out_dir/notes"
    echo "$invisible"
    return "$SHUNT_CW_EXIT_UNUSABLE"
  fi

  case "$reason" in
    ok) status=0 ;;
    deliberate-refusal) status="$SHUNT_CW_EXIT_REFUSAL" ;;
    missing-notes-delimiter|missing-code-delimiter|duplicate-notes-delimiter|duplicate-code-delimiter|out-of-order|text-before-delimiter|empty-code|oversize)
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
      && _shunt_cw_check_invisible "$1"); then
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
