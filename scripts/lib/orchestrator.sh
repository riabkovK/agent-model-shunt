# Fragment library for the orchestrator rule: a short delegation rule that is
# assembled from per-skill fragment files (skills/*/orchestrator.md). This file
# only parses, sanitizes and lists fragments. It never executes fragment
# content: the only substitution is the literal token {{MIN_LINES}}, replaced
# by a digits-only value, and nothing here uses eval or command substitution
# on fragment text.
#
# Fragment format: an optional first line `role: <name>`, then 1 to 6 bullet
# lines that each start with `- `. Blank lines are ignored. Anything else makes
# the fragment invalid (non-zero return, no output), so a broken fragment is
# skipped rather than half-rendered.
#
# Meant to be sourced. Functions never exit and only use prefixed globals.
#
# Compatibility: bash 3.2, GNU and BusyBox/BSD userland.

SHUNT_ORCHESTRATOR_MAX_FILE_BYTES=4096
SHUNT_ORCHESTRATOR_MAX_LINE_CHARS=160
SHUNT_ORCHESTRATOR_MAX_BODY_CHARS=600
SHUNT_ORCHESTRATOR_MAX_BULLETS=6
SHUNT_ORCHESTRATOR_DEFAULT_MIN_LINES=350
# Same shape as the registry role names (bulk-read, code-write).
SHUNT_ORCHESTRATOR_ROLE_MAX_CHARS=32

# Plugin root, derived without a subshell.
_SHUNT_ORCHESTRATOR_ROOT="${BASH_SOURCE[0]%/*}/../.."

# Results of the last _shunt_orchestrator_load call.
_SHUNT_ORCHESTRATOR_ROLE=""
_SHUNT_ORCHESTRATOR_BODY=""

# shunt_orchestrator_min_lines <value>
# Prints <value> if it is a plain positive integer of at most 9 digits,
# otherwise the default (350).
shunt_orchestrator_min_lines() {
  local v="${1:-}"
  case "$v" in
    ''|*[!0-9]*) v="$SHUNT_ORCHESTRATOR_DEFAULT_MIN_LINES" ;;
  esac
  # Strip leading zeros so 0007 is not read as octal; reject 0 and huge values.
  while [ "${#v}" -gt 1 ] && [ "${v:0:1}" = 0 ]; do v="${v:1}"; done
  if [ "${#v}" -gt 9 ] || [ "$v" = 0 ]; then
    v="$SHUNT_ORCHESTRATOR_DEFAULT_MIN_LINES"
  fi
  printf '%s\n' "$v"
}

# _shunt_orchestrator_sanitize <file>
# Prints at most MAX_FILE_BYTES of the file with ANSI escape sequences, CR and
# other control characters removed and tabs turned into spaces. UTF-8 text is
# kept, except invisible or terminal-active code points that could hide an
# instruction or drive a terminal: C1 controls, zero-width and bidi marks,
# line/paragraph separators, BOM and the Unicode tag block.
_shunt_orchestrator_sanitize() {
  local esc bel c1 zw sep wj bom tag
  esc=$(printf '\033')
  bel=$(printf '\007')
  c1=$(printf '\302[\200-\237]')
  zw=$(printf '\342\200[\213-\217]')
  sep=$(printf '\342\200[\250-\256]')
  wj=$(printf '\342\201[\240-\257]')
  bom=$(printf '\357\273\277')
  tag=$(printf '\363\240[\200-\201][\200-\277]')
  head -c $((SHUNT_ORCHESTRATOR_MAX_FILE_BYTES + 1)) <"$1" | tr '\t' ' ' | tr -d '\r' \
    | LC_ALL=C sed -e "s|${esc}\\][^${esc}${bel}]*${bel}||g" -e "s|${esc}\\][^${esc}${bel}]*${esc}\\\\||g" \
      -e "s|${esc}\\[[0-9;?]*[ -/]*[@-~]||g" -e "s|${esc}[@-Z\\\\-_]||g" \
      -e "s|${c1}||g" -e "s|${zw}||g" -e "s|${sep}||g" -e "s|${wj}||g" -e "s|${bom}||g" -e "s|${tag}||g" \
    | tr -d '\000-\010\013-\037\177'
}

# _shunt_orchestrator_load <file> [min_lines]
# Parses and sanitizes one fragment into _SHUNT_ORCHESTRATOR_ROLE and
# _SHUNT_ORCHESTRATOR_BODY. Returns non-zero (leaving both empty) when the
# file is unusable or the fragment is invalid.
_shunt_orchestrator_load() {
  local file="$1" min_lines text line first=1 bullets=0 role="" body="" token size
  _SHUNT_ORCHESTRATOR_ROLE=""
  _SHUNT_ORCHESTRATOR_BODY=""
  min_lines=$(shunt_orchestrator_min_lines "${2:-}")
  token='{{MIN_LINES}}'

  [ -f "$file" ] && [ -r "$file" ] || return 1
  # Count at most MAX+1 bytes so a file that lies about its size (or grows
  # while we read) cannot make us slurp more than the cap.
  size=$(head -c $((SHUNT_ORCHESTRATOR_MAX_FILE_BYTES + 1)) <"$file" 2>/dev/null | wc -c | tr -d ' ') || return 1
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$size" -le "$SHUNT_ORCHESTRATOR_MAX_FILE_BYTES" ] || return 1

  text=$(_shunt_orchestrator_sanitize "$file") || return 1

  while IFS= read -r line; do
    # Blank (or whitespace only) lines are ignored.
    case "$line" in *[!\ ]*) ;; *) continue ;; esac
    if [ "$first" = 1 ]; then
      first=0
      case "$line" in
        role:\ *)
          role="${line#role: }"
          case "$role" in
            ''|*[!abcdefghijklmnopqrstuvwxyz0-9-]*|-*|*-) return 1 ;;
          esac
          [ "${#role}" -le "$SHUNT_ORCHESTRATOR_ROLE_MAX_CHARS" ] || return 1
          continue
          ;;
      esac
    fi
    case "$line" in
      '- '*) ;;
      *) return 1 ;;
    esac
    bullets=$((bullets + 1))
    [ "$bullets" -le "$SHUNT_ORCHESTRATOR_MAX_BULLETS" ] || return 1
    line="${line//"$token"/$min_lines}"
    line="${line:0:$SHUNT_ORCHESTRATOR_MAX_LINE_CHARS}"
    if [ -z "$body" ]; then body="$line"; else body="$body"$'\n'"$line"; fi
  done <<EOT
$text
EOT

  [ "$bullets" -ge 1 ] || return 1
  _SHUNT_ORCHESTRATOR_ROLE="$role"
  _SHUNT_ORCHESTRATOR_BODY="${body:0:$SHUNT_ORCHESTRATOR_MAX_BODY_CHARS}"
  return 0
}

# shunt_orchestrator_role <file>
# Prints the fragment's role (empty line if it declares none). Non-zero and no
# output when the fragment is invalid.
shunt_orchestrator_role() {
  _shunt_orchestrator_load "$1" || return 1
  printf '%s\n' "$_SHUNT_ORCHESTRATOR_ROLE"
}

# shunt_orchestrator_body <file> [min_lines]
# Prints the sanitized bullet lines with {{MIN_LINES}} substituted. Non-zero
# and no output when the fragment is invalid.
shunt_orchestrator_body() {
  _shunt_orchestrator_load "$1" "${2:-}" || return 1
  printf '%s\n' "$_SHUNT_ORCHESTRATOR_BODY"
}

# shunt_orchestrator_list [plugin_root]
# Prints the built-in fragment paths (skills/*/orchestrator.md), sorted with
# LC_ALL=C. The root defaults to the plugin this file lives in.
shunt_orchestrator_list() {
  local root="${1:-$_SHUNT_ORCHESTRATOR_ROOT}" f
  for f in "$root"/skills/*/orchestrator.md; do
    # Names holding a newline would break the one-path-per-line output.
    case "$f" in *$'\n'*) continue ;; esac
    [ -e "$f" ] && printf '%s\n' "$f"
  done | LC_ALL=C sort
}

SHUNT_ORCHESTRATOR_MAX_RENDER_CHARS=3000

# _shunt_orchestrator_role_state <role>
# Sets REPLY to ready, unavailable or open. Needs models.sh and breaker.sh
# sourced. Returns non-zero when the registry cannot be read.
_shunt_orchestrator_role_state() {
  local role="$1" cands c
  local -a ids=()
  cands=$(shunt_models_candidates "$role" quiet 2>/dev/null) || return 1
  while IFS= read -r c; do
    [ -n "$c" ] && ids+=("$c")
  done <<EOT
$cands
EOT
  if [ "${#ids[@]}" -eq 0 ]; then
    REPLY=unavailable
  elif shunt_breaker_any_closed "${ids[@]}"; then
    REPLY=ready
  else
    REPLY=open
  fi
}

# shunt_orchestrator_render [plugin_root]
# Prints the plain-text delegation rule for session start. Needs models.sh and
# breaker.sh sourced. Only fixed state strings and fragment text are printed,
# never a model id, name or other registry value. Prints nothing and returns
# non-zero when the registry exists but cannot be read. Output is capped at
# MAX_RENDER_CHARS by dropping whole trailing lines.
shunt_orchestrator_render() {
  local root="${1:-$_SHUNT_ORCHESTRATOR_ROOT}" min_lines f role state seen="" out line total=0 n
  local header='Shunt delegation (cheap models; Claude keeps judgment).'
  local -a rows=("$header")

  min_lines=$(shunt_orchestrator_min_lines "${SHUNT_MIN_LINES:-}")

  if ! shunt_models_available; then
    # A present but invalid registry is an error, a missing one is a setup hint.
    [ ! -e "$SHUNT_MODELS_FILE" ] || return 1
    rows+=('No delegate models configured; run /model-config to set them up.')
  else
    case "${SHUNT_HOOKS_DISABLED:-}" in
      1|true|TRUE|yes|YES) rows+=('Reads are not hook-gated; delegate by judgment only.') ;;
    esac
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      _shunt_orchestrator_load "$f" "$min_lines" || continue
      role="$_SHUNT_ORCHESTRATOR_ROLE"
      # A role the registry does not know is treated like an invalid fragment.
      [ -z "$role" ] || shunt_models_role_known "$role" || continue
      state=ready
      if [ -n "$role" ]; then
        # One registry and breaker lookup per role, however many fragments share it.
        case "$seen" in
          *"|$role="*) state="${seen#*"|$role="}"; state="${state%%|*}" ;;
          *)
            _shunt_orchestrator_role_state "$role" || return 1
            state="$REPLY"
            seen="$seen|$role=$state|"
            ;;
        esac
      fi
      case "$state" in
        unavailable) rows+=("$role: unavailable, handle directly.") ;;
        open) rows+=("$role: breaker open, handle directly until cooldown.") ;;
        *)
          while IFS= read -r line; do rows+=("$line"); done <<EOT
$_SHUNT_ORCHESTRATOR_BODY
EOT
          ;;
      esac
    done <<EOT
$(shunt_orchestrator_list "$root")
EOT
  fi

  out=""
  for line in "${rows[@]}"; do
    n=$((${#line} + 1))
    [ $((total + n)) -le "$SHUNT_ORCHESTRATOR_MAX_RENDER_CHARS" ] || break
    out="$out$line"$'\n'
    total=$((total + n))
  done
  printf '%s' "$out"
}
