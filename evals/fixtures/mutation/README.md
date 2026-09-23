# Fixture provenance and design

Unlike `evals/fixtures/echo/`, `pricing.go` in this directory is **original
code written for this project**, not a third-party import — that is the
whole point of it: the code-writer live-eval's mutation-check scenario
(`pricing`, see `evals/live-eval-benchmark.sh`) needs code under test that
compiles standalone with no third-party dependency, so a mechanically
mutated copy of it can be dropped into a scratch directory and built with
nothing but the Go standard library. Mutating the real `github.com/labstack/echo/v5`
module used by the `cors`/`router` scenarios would need a `go.mod`
`replace`-directive against a whole vendored/mutated copy of that module;
this fixture exists specifically to avoid that (decision recorded in
`docs/TODO.md`).

## Authoring constraints

These constraints exist because `evals/mutate-go.sh` (the mutator) is a
plain text/regex transform over gofmt'd source, not a Go AST tool. Any
change to `pricing.go` must keep respecting them, or mutation sites will
stop being found or will stop compiling:

- Integer cents only, no floats.
- No string concatenation with `+` (the arithmetic operator mutant does
  not distinguish string `+` from numeric `+`); use `errors.New` with a
  fixed message instead.
- Keep `gofmt` formatting. The mutator's arithmetic operator matcher looks
  for a single space-delimited binary operator (` + `, ` - `, ` * `, or
  `/`) per line; mixed-precedence expressions on one line (e.g.
  `a + b*c`) get tightened by `gofmt` in a way the matcher does not
  special-case, so each arithmetic expression is kept on its own
  statement with at most one precedence level.
- A line that must never be mutated (see "Known equivalent mutant" below)
  ends with `// mutate:skip`.

## Mutation sites

Every `if`/`for` boundary comparison (`>=`, `<=`, `>`, `<`), every `if`
condition (negation), every arithmetic operator, and every standalone
integer literal in this file is a candidate mutation site for
`evals/mutate-go.sh`. The hand-written suite in `pricing_reference_test.go`
is deliberately built to kill every one of them: exact boundary values
(`9`/`10`/`99`/`100` for `Tier`, `0` for both `qty` and `unitCents`
validation, `100`/`101` for the discount-percent ceiling) are tested on
purpose, not incidentally, precisely so a boundary-flip mutant is
observable.

## Known skipped mutants

Two lines carry `// mutate:skip`, for two different reasons. Both are
excluded from `evals/mutate-go.sh --list`'s candidate set entirely (the
skip applies to the whole line, not to one operator category, so any
otherwise-killable mutant on the same line is also given up; accepted as
a simplicity tradeoff in the mutator).

**Equivalent mutant** — the discount cap in `DiscountPercent`:

```go
if pct > maxDiscountPercent { // mutate:skip (clamp boundary is an equivalent mutant, see README)
    pct = maxDiscountPercent
}
```

Mutating `>` to `>=` here is a textbook equivalent mutant: at the exact
boundary `pct == maxDiscountPercent`, clamping to `maxDiscountPercent` is a
no-op either way, so no input can ever distinguish the mutant from the
original. Any clamp/min-to-a-threshold pattern has this property for a
boundary-flip mutation at its own threshold value. Accepting a
guaranteed-unkillable mutant here would make `--self-test` unable to reach
100% kills and would misreport a genuinely strong test suite as weak.

**Unreachable branch** — the `DiscountPercent` error check inside
`OrderTotalCents`:

```go
pct, err := DiscountPercent(tier, loyaltyYears)
if err != nil {
    return 0, err // mutate:skip (unreachable: Tier's output is exhaustive, see README)
}
```

`tier` here is always `Tier(item.Qty)`'s return value, and `Tier` only
ever returns `"bulk"`, `"volume"`, or `"retail"` — exactly the three cases
`DiscountPercent`'s `switch` handles without error. This branch can never
execute through `OrderTotalCents`, so no black-box test reaching
`DiscountPercent` only through `OrderTotalCents` can ever kill a mutant on
this line; it is untestable from this entry point by construction, not a
weakness of `pricing_reference_test.go`.

## Self-test

`evals/mutation-check.sh --self-test` copies `pricing.go` and
`pricing_reference_test.go` into a scratch run directory and runs the full
mutation check against them. It must report every valid mutant killed
(`mutants_survived == 0`). This is the gate proving the fixture has no
undocumented equivalent mutants and that the mutation pipeline itself
works end to end. Run it after any change to `pricing.go` or to the
mutator's operator set.
