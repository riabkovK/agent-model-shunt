#!/bin/bash
# mutate-go.sh — pure text-transform mutator for gofmt'd Go source.
#
# Used by the (future) evals/mutation-check.sh scenario to generate small,
# mechanical mutants of a Go fixture (see evals/fixtures/mutation/README.md
# for the authoring constraints a source file must respect for this
# mutator to find its sites and keep the result compiling). This is a text
# transform over gofmt'd lines, not a Go AST tool: it never parses or
# compiles anything itself.
#
# Everything here is plain bash (regex via [[ =~ ]], substring slicing,
# arrays), deliberately avoiding awk/sed. This script also has to run
# unmodified inside the bats test image (test/Dockerfile, bats/bats:1.14.0
# + apk-installed bash/jq/coreutils), whose /bin/sed and /usr/bin/awk are
# both busybox applets with a much smaller feature set than GNU sed/awk;
# the apk-installed bash package there is genuine GNU bash 5.x, so relying
# on bash's own regex/array/parameter-expansion features (rather than on
# awk or sed) is the portable choice for this environment.
#
# Subcommands:
#   mutate-go.sh --list <source.go>
#     One TSV line per mutation site on stdout:
#       <id>\t<operator>\t<line-no>\t<original-line>\t<mutated-line>
#     Ordered by line number ascending, then by the fixed operator order
#     cond-boundary, cond-negate, arith-op, int-literal. <id> is
#     "<operator>:<line-no>". Note: <original-line>/<mutated-line> may
#     themselves contain literal tab characters (gofmt indentation), so
#     naive tab-splitting of the whole row is not safe past field 3;
#     consumers that only need id/operator/line-no should cut on the
#     first three tabs only.
#
#   mutate-go.sh --select <n> <source.go>
#     Up to <n> ids (one per line, no other columns), chosen round-robin
#     across the operator categories present, in the fixed operator order
#     above, deterministic for a given input. Prints all sites if <n> is
#     >= the total site count. Prints nothing (exit 0) if there are no
#     sites at all.
#
#   mutate-go.sh --apply <id> <source.go> <out.go>
#     Writes a copy of <source.go> to <out.go> with exactly one line
#     changed. Exit 0 on success. Exit 1 if <id> does not name a real
#     site (nothing written). Exit 2 on bad arguments, an unreadable
#     <source.go>, or an already-existing <out.go> (no-clobber, matching
#     the publish convention in scripts/lib/codewrite.sh). One line on
#     stderr on every non-zero exit.
#
# Mutation operators:
#   cond-boundary  On a line matching ^[[:space:]]*(if|for|} else if|case)
#                  (word-boundary after the keyword), replace the first
#                  boundary comparison operator: >= -> >, <= -> <, > -> >=,
#                  < -> <=. Two-character tokens are matched before falling
#                  back to a bare >/<, and >>, <<, <- (channel receive) and
#                  -> are never treated as candidates.
#   cond-negate    On a line matching ^[[:space:]]*if (.*) \{$, rewrite
#                  "if X {" to "if !(X) {", preserving indentation. Applied
#                  unconditionally to every qualifying line.
#   arith-op       Anywhere on the line, the first (leftmost) occurrence of
#                  one of " + ", " - ", " * ", " / " (space-delimited, so
#                  ++/--/+=/-=/*=//= and unary minus never match) is
#                  swapped for a different one of the same four via a
#                  fixed mapping (+/-, and */).
#   int-literal    The first maximal run of decimal digits on the line that
#                  is not immediately preceded or followed by a letter,
#                  underscore or dot (so identifiers like line2, floats
#                  like 1.5, and longer numbers are not mismatched) is
#                  replaced by its value + 1. Known limitation: hex/octal/
#                  binary prefixed literals (0x.., 0o.., 0b..) are not
#                  specially recognized; the fixture this mutator targets
#                  never uses them, so this is a documented gap, not a bug
#                  fix target.
#
# Global skip rules, applied before any operator match on a line:
#   - blank/whitespace-only line
#   - comment-only line (^[[:space:]]*//)
#   - any line containing a double-quote or backtick character (kills
#     string-literal false positives, including Go raw strings, for all
#     four operators in one rule)
#   - any line containing the marker "// mutate:skip" anywhere in it. The
#     contract calls this a trailing marker, but the fixture's own
#     documented equivalent-mutant line carries extra explanatory text
#     after the marker (see evals/fixtures/mutation/pricing.go), so this
#     is implemented as "contains", not "ends with", to actually honor
#     that line.
#
# At most one mutation per (line, operator): if a line has two occurrences
# of the same operator category, only the first is a candidate. Different
# operator categories are independent and can each produce their own site
# on the same line.

set -uo pipefail

_MG_USAGE='mutate-go: usage: mutate-go.sh --list <source.go> | --select <n> <source.go> | --apply <id> <source.go> <out.go>'

# Fixed operator order used both for --list's tie-break and for --select's
# round-robin: cond-boundary, cond-negate, arith-op, int-literal.

# ---- global skip rules --------------------------------------------------

_mg_is_skipped() {
  local line="$1"
  [[ "$line" =~ ^[[:space:]]*$ ]] && return 0
  [[ "$line" =~ ^[[:space:]]*// ]] && return 0
  [[ "$line" == *'"'* ]] && return 0
  [[ "$line" == *'`'* ]] && return 0
  [[ "$line" == *'// mutate:skip'* ]] && return 0
  return 1
}

# ---- cond-boundary --------------------------------------------------------

_mg_boundary_line_ok() {
  local line="$1"
  local re_if='^[[:space:]]*if($|[^A-Za-z0-9_])'
  local re_for='^[[:space:]]*for($|[^A-Za-z0-9_])'
  local re_elseif='^[[:space:]]*\}[[:space:]]*else[[:space:]]+if($|[^A-Za-z0-9_])'
  local re_case='^[[:space:]]*case($|[^A-Za-z0-9_])'
  [[ "$line" =~ $re_if ]] && return 0
  [[ "$line" =~ $re_for ]] && return 0
  [[ "$line" =~ $re_elseif ]] && return 0
  [[ "$line" =~ $re_case ]] && return 0
  return 1
}

# On success sets MG_NEW, MG_START (0-based), MG_LEN and returns 0.
_mg_find_boundary() {
  local line="$1"
  local n=${#line} i c prev next
  for ((i = 0; i < n; i++)); do
    c="${line:i:1}"
    if [[ "$c" == ">" ]]; then
      if ((i > 0)); then prev="${line:i-1:1}"; else prev=""; fi
      next="${line:i+1:1}"
      if [[ "$prev" == "-" ]]; then
        continue
      elif [[ "$next" == "=" ]]; then
        MG_NEW=">"; MG_START=$i; MG_LEN=2
        return 0
      elif [[ "$next" == ">" ]]; then
        ((i++))
        continue
      else
        MG_NEW=">="; MG_START=$i; MG_LEN=1
        return 0
      fi
    elif [[ "$c" == "<" ]]; then
      next="${line:i+1:1}"
      if [[ "$next" == "=" ]]; then
        MG_NEW="<"; MG_START=$i; MG_LEN=2
        return 0
      elif [[ "$next" == "-" || "$next" == "<" ]]; then
        if [[ "$next" == "<" ]]; then ((i++)); fi
        continue
      else
        MG_NEW="<="; MG_START=$i; MG_LEN=1
        return 0
      fi
    fi
  done
  return 1
}

# ---- cond-negate ----------------------------------------------------------

# On success sets MG_INDENT, MG_COND and returns 0.
_mg_negate_match() {
  local line="$1"
  local re='^([[:space:]]*)if (.*) \{$'
  if [[ "$line" =~ $re ]]; then
    MG_INDENT="${BASH_REMATCH[1]}"
    MG_COND="${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# ---- arith-op ---------------------------------------------------------

# On success sets MG_NEW, MG_START (0-based), MG_LEN=3, returns 0.
_mg_find_arith() {
  local line="$1" best=-1 bestnew="" rest pos op
  local -A newop=([" + "]=" - " [" - "]=" + " [" * "]=" / " [" / "]=" * ")
  for op in " + " " - " " * " " / "; do
    if [[ "$line" == *"$op"* ]]; then
      rest="${line%%"$op"*}"
      pos=${#rest}
      if ((best == -1 || pos < best)); then
        best=$pos
        bestnew="${newop[$op]}"
      fi
    fi
  done
  if ((best == -1)); then
    return 1
  fi
  MG_NEW="$bestnew"; MG_START=$best; MG_LEN=3
  return 0
}

# ---- int-literal --------------------------------------------------------

# On success sets MG_START (0-based), MG_LEN, MG_VALUE and returns 0.
_mg_find_intlit() {
  local line="$1"
  local n=${#line} i c prev next start j
  for ((i = 0; i < n; i++)); do
    c="${line:i:1}"
    if [[ "$c" =~ [0-9] ]]; then
      if ((i > 0)); then prev="${line:i-1:1}"; else prev=""; fi
      if [[ -n "$prev" && "$prev" =~ [A-Za-z0-9_.] ]]; then
        continue
      fi
      start=$i
      j=$i
      while ((j < n)) && [[ "${line:j:1}" =~ [0-9] ]]; do
        ((j++))
      done
      next="${line:j:1}"
      if [[ -n "$next" && "$next" =~ [A-Za-z_.] ]]; then
        continue
      fi
      MG_START=$start
      MG_LEN=$((j - start))
      MG_VALUE="${line:start:MG_LEN}"
      return 0
    fi
  done
  return 1
}

# ---- site collection ------------------------------------------------------

declare -a MG_IDS MG_OPS MG_LINES MG_ORIG MG_MUT

# _mg_collect_sites <file>
# Populates the MG_IDS/MG_OPS/MG_LINES/MG_ORIG/MG_MUT parallel arrays, in
# line-ascending then fixed-operator order. Returns 1 if <file> can't be
# read.
_mg_collect_sites() {
  local file="$1" lineno=0 line mutated newval
  MG_IDS=(); MG_OPS=(); MG_LINES=(); MG_ORIG=(); MG_MUT=()
  [[ -r "$file" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    _mg_is_skipped "$line" && continue

    if _mg_boundary_line_ok "$line" && _mg_find_boundary "$line"; then
      mutated="${line:0:MG_START}${MG_NEW}${line:MG_START+MG_LEN}"
      MG_IDS+=("cond-boundary:${lineno}"); MG_OPS+=("cond-boundary")
      MG_LINES+=("$lineno"); MG_ORIG+=("$line"); MG_MUT+=("$mutated")
    fi

    if _mg_negate_match "$line"; then
      mutated="${MG_INDENT}if !(${MG_COND}) {"
      MG_IDS+=("cond-negate:${lineno}"); MG_OPS+=("cond-negate")
      MG_LINES+=("$lineno"); MG_ORIG+=("$line"); MG_MUT+=("$mutated")
    fi

    if _mg_find_arith "$line"; then
      mutated="${line:0:MG_START}${MG_NEW}${line:MG_START+MG_LEN}"
      MG_IDS+=("arith-op:${lineno}"); MG_OPS+=("arith-op")
      MG_LINES+=("$lineno"); MG_ORIG+=("$line"); MG_MUT+=("$mutated")
    fi

    if _mg_find_intlit "$line"; then
      newval=$((10#$MG_VALUE + 1))
      mutated="${line:0:MG_START}${newval}${line:MG_START+MG_LEN}"
      MG_IDS+=("int-literal:${lineno}"); MG_OPS+=("int-literal")
      MG_LINES+=("$lineno"); MG_ORIG+=("$line"); MG_MUT+=("$mutated")
    fi
  done <"$file"
  return 0
}

# ---- subcommands ------------------------------------------------------

cmd_list() {
  local file="$1" i
  if [[ ! -r "$file" ]]; then
    echo "mutate-go: cannot read source file: $file" >&2
    return 2
  fi
  _mg_collect_sites "$file"
  for ((i = 0; i < ${#MG_IDS[@]}; i++)); do
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "${MG_IDS[i]}" "${MG_OPS[i]}" "${MG_LINES[i]}" "${MG_ORIG[i]}" "${MG_MUT[i]}"
  done
  return 0
}

cmd_select() {
  local n="$1" file="$2" i op id gi c count=0 more=1
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    echo "mutate-go: --select count must be a non-negative integer" >&2
    return 2
  fi
  if [[ ! -r "$file" ]]; then
    echo "mutate-go: cannot read source file: $file" >&2
    return 2
  fi
  _mg_collect_sites "$file"
  if ((${#MG_IDS[@]} == 0)); then
    return 0
  fi

  local -a cb=() cn=() ao=() il=()
  for ((i = 0; i < ${#MG_IDS[@]}; i++)); do
    op="${MG_OPS[i]}"; id="${MG_IDS[i]}"
    case "$op" in
      cond-boundary) cb+=("$id") ;;
      cond-negate) cn+=("$id") ;;
      arith-op) ao+=("$id") ;;
      int-literal) il+=("$id") ;;
    esac
  done

  local -a names=(cb cn ao il)
  local -a cursors=(0 0 0 0)
  local -a selected=()
  while ((count < n && more)); do
    more=0
    for gi in 0 1 2 3; do
      local -n arr="${names[gi]}"
      c="${cursors[gi]}"
      if ((c < ${#arr[@]})); then
        selected+=("${arr[c]}")
        cursors[gi]=$((c + 1))
        count=$((count + 1))
        more=1
        if ((count >= n)); then
          break
        fi
      fi
    done
  done

  for id in "${selected[@]}"; do
    printf '%s\n' "$id"
  done
  return 0
}

cmd_apply() {
  local id="$1" file="$2" out="$3"
  local i target=-1 lineno=0 line wrote=0 tmp

  if [[ ! -r "$file" ]]; then
    echo "mutate-go: cannot read source file: $file" >&2
    return 2
  fi
  if [[ -e "$out" ]]; then
    echo "mutate-go: refusing to overwrite existing file: $out" >&2
    return 2
  fi

  _mg_collect_sites "$file"
  for ((i = 0; i < ${#MG_IDS[@]}; i++)); do
    if [[ "${MG_IDS[i]}" == "$id" ]]; then
      target=$i
      break
    fi
  done
  if ((target == -1)); then
    echo "mutate-go: unknown mutation id: $id" >&2
    return 1
  fi

  tmp="$(mktemp "${out}.XXXXXX")" || {
    echo "mutate-go: failed to create a temp file next to $out" >&2
    return 2
  }

  local target_line="${MG_LINES[target]}" mutated="${MG_MUT[target]}"
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    if ((lineno == target_line)); then
      printf '%s\n' "$mutated" >>"$tmp"
      wrote=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"

  if ((wrote == 0)); then
    rm -f -- "$tmp"
    echo "mutate-go: unknown mutation id: $id" >&2
    return 1
  fi

  mv -n -- "$tmp" "$out" 2>/dev/null || :
  if [[ -e "$tmp" ]]; then
    rm -f -- "$tmp"
    echo "mutate-go: refusing to overwrite existing file: $out" >&2
    return 2
  fi
  return 0
}

main() {
  case "${1:-}" in
    --list)
      if [[ $# -ne 2 ]]; then
        echo "$_MG_USAGE" >&2
        return 2
      fi
      cmd_list "$2"
      ;;
    --select)
      if [[ $# -ne 3 ]]; then
        echo "$_MG_USAGE" >&2
        return 2
      fi
      cmd_select "$2" "$3"
      ;;
    --apply)
      if [[ $# -ne 4 ]]; then
        echo "$_MG_USAGE" >&2
        return 2
      fi
      cmd_apply "$2" "$3" "$4"
      ;;
    *)
      echo "$_MG_USAGE" >&2
      return 2
      ;;
  esac
}

main "$@"
exit $?
