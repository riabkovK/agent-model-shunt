load 'test_helper'

setup() {
  shunt_test_setup
  MUT="$REPO_ROOT/evals/mutate-go.sh"
}

teardown() {
  shunt_test_teardown
}

# Writes $2 (an ANSI-C-quoted, i.e. $'...', string so \t and \n are real
# tab/newline bytes) to the file at path $1.
write_go() {
  printf '%s' "$2" >"$1"
}

# ---- --list -----------------------------------------------------------

@test "--list reports exact ids, operators, line numbers and mutated lines for a multi-site file" {
  local f="$TEST_TMPDIR/multi.go"
  write_go "$f" $'package p\n\nfunc F(qty int) int {\n\tif qty >= 10 {\n\t\treturn 1\n\t}\n\tx := qty + 2\n\treturn x\n}\n'

  local expected
  expected=$'cond-boundary:4\tcond-boundary\t4\t\tif qty >= 10 {\t\tif qty > 10 {\n'
  expected+=$'cond-negate:4\tcond-negate\t4\t\tif qty >= 10 {\t\tif !(qty >= 10) {\n'
  expected+=$'int-literal:4\tint-literal\t4\t\tif qty >= 10 {\t\tif qty >= 11 {\n'
  expected+=$'int-literal:5\tint-literal\t5\t\t\treturn 1\t\t\treturn 2\n'
  expected+=$'arith-op:7\tarith-op\t7\t\tx := qty + 2\t\tx := qty - 2\n'
  expected+=$'int-literal:7\tint-literal\t7\t\tx := qty + 2\t\tx := qty + 3'

  run "$MUT" --list "$f"
  assert_success
  assert_output "$expected"
}

@test "--list ordering is stable across two separate invocations" {
  local f="$TEST_TMPDIR/multi.go"
  write_go "$f" $'package p\n\nfunc F(qty int) int {\n\tif qty >= 10 {\n\t\treturn 1\n\t}\n\tx := qty + 2\n\treturn x\n}\n'

  run "$MUT" --list "$f"
  assert_success
  local first="$output"

  run "$MUT" --list "$f"
  assert_success
  assert_equal "$output" "$first"
}

# ---- one exact-mutation assertion per operator -------------------------

@test "cond-boundary rewrites >= to > on a qualifying if line" {
  local f="$TEST_TMPDIR/boundary.go"
  write_go "$f" $'func F(n int) int {\n\tif n >= 5 {\n\t\treturn 1\n\t}\n\treturn 0\n}\n'

  run "$MUT" --list "$f"
  assert_success
  assert_output --partial $'cond-boundary:2\tcond-boundary\t2\t\tif n >= 5 {\t\tif n > 5 {'
}

@test "cond-negate wraps the if condition in !(...) preserving indentation" {
  local f="$TEST_TMPDIR/negate.go"
  write_go "$f" $'func F(ready bool) int {\n\tif ready {\n\t\treturn 1\n\t}\n\treturn 0\n}\n'

  run "$MUT" --list "$f"
  assert_success
  assert_output --partial $'cond-negate:2\tcond-negate\t2\t\tif ready {\t\tif !(ready) {'
}

@test "arith-op swaps the first + for a -" {
  local f="$TEST_TMPDIR/arith.go"
  write_go "$f" $'func F(a, b int) int {\n\ttotal := a + b\n\treturn total\n}\n'

  run "$MUT" --list "$f"
  assert_success
  assert_output --partial $'arith-op:2\tarith-op\t2\t\ttotal := a + b\t\ttotal := a - b'
}

@test "int-literal increments the first standalone decimal literal" {
  local f="$TEST_TMPDIR/intlit.go"
  write_go "$f" $'func F() int {\n\tn := 41\n\treturn n\n}\n'

  run "$MUT" --list "$f"
  assert_success
  assert_output --partial $'int-literal:2\tint-literal\t2\t\tn := 41\t\tn := 42'
}

# ---- skip rules ---------------------------------------------------------

@test "a comment-only line produces no mutation sites" {
  local f="$TEST_TMPDIR/comment.go"
  write_go "$f" $'func F() int {\n\t// total := a + 100\n\treturn 0\n}\n'

  run "$MUT" --list "$f"
  assert_success
  refute_output --partial "arith-op:2"
  refute_output --partial "int-literal:2"
}

@test "a line containing a string literal is left untouched even when it looks arithmetic" {
  local f="$TEST_TMPDIR/string.go"
  write_go "$f" $'func F(name string) string {\n\tmsg := "value: " + name\n\treturn msg\n}\n'

  run "$MUT" --list "$f"
  assert_success
  refute_output --partial "arith-op:"
}

@test "a line with a trailing // mutate:skip marker is left untouched" {
  local f="$TEST_TMPDIR/skip.go"
  write_go "$f" $'func F(a, b int) bool {\n\tif a > b { // mutate:skip\n\t\treturn true\n\t}\n\treturn false\n}\n'

  run "$MUT" --list "$f"
  assert_success
  refute_output --partial "cond-boundary:"
  refute_output --partial "cond-negate:"
}

@test "x++, x += 1, unary minus and a *ptr deref are never arith-op sites" {
  local f="$TEST_TMPDIR/notarith.go"
  write_go "$f" $'func G(x int, p *int) {\n\tx++\n\tx += 1\n\ty := -x\n\tz := *p\n\t_ = y\n\t_ = z\n}\n'

  run "$MUT" --list "$f"
  assert_success
  refute_output --partial "arith-op:"
}

@test "<-, << and >> are never cond-boundary sites" {
  local f="$TEST_TMPDIR/shift.go"
  write_go "$f" $'func H() {\n\tif x <- y {\n\t}\n\tif x << 1 {\n\t}\n\tif x >> 1 {\n\t}\n}\n'

  run "$MUT" --list "$f"
  assert_success
  refute_output --partial "cond-boundary:"
}

@test "== and != are never cond-boundary sites" {
  local f="$TEST_TMPDIR/eqne.go"
  write_go "$f" $'func H(a, b int) {\n\tif a == b {\n\t}\n\tif a != b {\n\t}\n}\n'

  run "$MUT" --list "$f"
  assert_success
  refute_output --partial "cond-boundary:"
}

@test "a Go raw string (backtick) literal is left untouched even when it looks arithmetic" {
  local f="$TEST_TMPDIR/backtick.go"
  write_go "$f" $'func F() string {\n\ttpl := `total: {{ 1 + 2 }}`\n\treturn tpl\n}\n'

  run "$MUT" --list "$f"
  assert_success
  refute_output --partial "arith-op:"
  refute_output --partial "int-literal:"
}

@test "cond-boundary fires on a } else if line" {
  local f="$TEST_TMPDIR/elseif.go"
  write_go "$f" $'func F(n int) int {\n\tif n >= 100 {\n\t\treturn 2\n\t} else if n >= 5 {\n\t\treturn 1\n\t}\n\treturn 0\n}\n'

  run "$MUT" --list "$f"
  assert_success
  assert_output --partial $'cond-boundary:4\tcond-boundary\t4\t\t} else if n >= 5 {\t\t} else if n > 5 {'
}

@test "cond-boundary fires on a case line with a non-string, comparison-free guard omitted (numeric switch case)" {
  local f="$TEST_TMPDIR/switchcase.go"
  write_go "$f" $'func F(n int) int {\n\tswitch {\n\tcase n >= 10:\n\t\treturn 1\n\t}\n\treturn 0\n}\n'

  run "$MUT" --list "$f"
  assert_success
  assert_output --partial $'cond-boundary:3\tcond-boundary\t3\t\tcase n >= 10:\t\tcase n > 10:'
}

# ---- --apply ------------------------------------------------------------

@test "--apply changes exactly one line and leaves the rest of the file intact" {
  local src="$TEST_TMPDIR/src.go" out="$TEST_TMPDIR/out.go"
  write_go "$src" $'func F(a, b int) int {\n\ttotal := a + b\n\treturn total\n}\n'

  run "$MUT" --apply "arith-op:2" "$src" "$out"
  assert_success
  [ -f "$out" ]

  # Compare line-by-line in bash rather than shelling out to `diff`: the
  # test image's busybox diff defaults to unified-diff markers (---/+++/@@)
  # instead of the classic </> ed-style markers, so a portable line-count
  # comparison is used instead of grepping diff's output.
  local src_lines out_lines idx changed=0
  mapfile -t src_lines <"$src"
  mapfile -t out_lines <"$out"
  assert_equal "${#out_lines[@]}" "${#src_lines[@]}"
  for ((idx = 0; idx < ${#src_lines[@]}; idx++)); do
    if [ "${src_lines[idx]}" != "${out_lines[idx]}" ]; then
      changed=$((changed + 1))
    fi
  done
  assert_equal "$changed" 1
}

@test "--apply applies a cond-negate id correctly, not just arith-op" {
  local src="$TEST_TMPDIR/src2.go" out="$TEST_TMPDIR/out2.go"
  write_go "$src" $'func F(ready bool) int {\n\tif ready {\n\t\treturn 1\n\t}\n\treturn 0\n}\n'

  run "$MUT" --apply "cond-negate:2" "$src" "$out"
  assert_success
  [ -f "$out" ]

  local out_lines
  mapfile -t out_lines <"$out"
  assert_equal "${out_lines[1]}" $'\tif !(ready) {'
}

@test "--apply refuses an unknown id with exit 1 and writes nothing" {
  local src="$TEST_TMPDIR/src.go" out="$TEST_TMPDIR/out.go"
  write_go "$src" $'func F(a, b int) int {\n\ttotal := a + b\n\treturn total\n}\n'

  run "$MUT" --apply "no-such-op:99" "$src" "$out"
  assert_failure
  assert_equal "$status" 1
  [ ! -e "$out" ]
  assert_output --partial "mutate-go:"
}

@test "--apply refuses to overwrite an already-existing out file with exit 2" {
  local src="$TEST_TMPDIR/src.go" out="$TEST_TMPDIR/out.go"
  write_go "$src" $'func F(a, b int) int {\n\ttotal := a + b\n\treturn total\n}\n'
  write_go "$out" "existing content"

  run "$MUT" --apply "arith-op:2" "$src" "$out"
  assert_failure
  assert_equal "$status" 2
  assert_equal "$(cat "$out")" "existing content"
  assert_output --partial "mutate-go:"
}

@test "--apply exits 2 on a missing source file" {
  local out="$TEST_TMPDIR/out.go"

  run "$MUT" --apply "arith-op:2" "$TEST_TMPDIR/does-not-exist.go" "$out"
  assert_failure
  assert_equal "$status" 2
  [ ! -e "$out" ]
  assert_output --partial "mutate-go:"
}

# ---- --select -----------------------------------------------------------

@test "--select returns at most N ids" {
  local f="$TEST_TMPDIR/multi.go"
  write_go "$f" $'package p\n\nfunc F(qty int) int {\n\tif qty >= 10 {\n\t\treturn 1\n\t}\n\tx := qty + 2\n\treturn x\n}\n'

  run "$MUT" --select 3 "$f"
  assert_success
  assert_equal "${#lines[@]}" 3
}

@test "--select round-robins across operator categories instead of taking the first N in document order" {
  local f="$TEST_TMPDIR/skewed.go"
  write_go "$f" $'func F(qty int) int {\n\ta := 1\n\tb := 2\n\tc := 3\n\tif qty >= 5 {\n\t\treturn 1\n\t}\n\treturn a\n}\n'

  run "$MUT" --select 2 "$f"
  assert_success
  assert_equal "${#lines[@]}" 2

  local op1="${lines[0]%%:*}" op2="${lines[1]%%:*}"
  [ "$op1" != "$op2" ]
}

@test "--select is deterministic across two separate invocations" {
  local f="$TEST_TMPDIR/skewed.go"
  write_go "$f" $'func F(qty int) int {\n\ta := 1\n\tb := 2\n\tc := 3\n\tif qty >= 5 {\n\t\treturn 1\n\t}\n\treturn a\n}\n'

  run "$MUT" --select 4 "$f"
  assert_success
  local first="$output"

  run "$MUT" --select 4 "$f"
  assert_success
  assert_equal "$output" "$first"
}

@test "--select with N >= total site count returns every site exactly once" {
  local f="$TEST_TMPDIR/multi.go"
  write_go "$f" $'package p\n\nfunc F(qty int) int {\n\tif qty >= 10 {\n\t\treturn 1\n\t}\n\tx := qty + 2\n\treturn x\n}\n'

  run "$MUT" --list "$f"
  assert_success
  local total="${#lines[@]}"

  run "$MUT" --select 999 "$f"
  assert_success
  assert_equal "${#lines[@]}" "$total"

  local all_ids
  all_ids=$(printf '%s\n' "${lines[@]}" | sort)
  local list_ids
  list_ids=$("$MUT" --list "$f" | cut -f1 | sort)
  assert_equal "$all_ids" "$list_ids"
}

@test "--select on a file with zero sites prints nothing and exits 0" {
  local f="$TEST_TMPDIR/nosites.go"
  write_go "$f" $'package p\n\n// just a comment\nvar s = "no sites here + 1"\n'

  run "$MUT" --select 5 "$f"
  assert_success
  assert_output ""
}
