#!/usr/bin/env python3
"""Aggregates evals/results/live-eval-benchmark.jsonl into summary stats and
prints a comparison table: direct (Claude writes the Go test itself) vs
shunt (delegated via scripts/code-write), per scenario. Mirrors
aggregate-baseline-results.py's shape.

Usage: aggregate-live-eval-results.py <rows.jsonl> <summary-out.json>
"""
import json
import statistics as st
import sys
from collections import defaultdict


def mean_min_max(vals):
    if not vals:
        return None
    return {"mean": st.mean(vals), "min": min(vals), "max": max(vals), "n": len(vals)}


def rate(numerator, denominator):
    if not denominator:
        return None
    return numerator / denominator


def main():
    rows_path, summary_path = sys.argv[1], sys.argv[2]
    rows = [json.loads(line) for line in open(rows_path) if line.strip()]

    by_key = defaultdict(list)
    for r in rows:
        by_key[(r["scenario"], r["kind"])].append(r)

    scenarios = sorted({r["scenario"] for r in rows})
    kinds = ["direct", "shunt"]

    summary = {"scenarios": {}}
    for sc in scenarios:
        summary["scenarios"][sc] = {}
        for kind in kinds:
            group = by_key.get((sc, kind), [])
            created = [r for r in group if r["outcome"] == "created"]
            durs = [r["duration_ms"] for r in group if r.get("duration_ms") is not None]
            out_tokens = [r["output_tokens"] for r in created if r.get("output_tokens") is not None]
            in_tokens = [r["input_tokens"] for r in created if r.get("input_tokens") is not None]
            costs = [r["cost_usd"] for r in group if r.get("cost_usd") is not None]
            build_oks = [r["build_ok"] for r in created if r.get("build_ok") is not None]
            tests_total = sum(r["tests_total"] for r in created if r.get("tests_total") is not None)
            tests_passed = sum(r["tests_passed"] for r in created if r.get("tests_passed") is not None)

            entry = {
                "n": len(group),
                "outcomes": {o: sum(1 for r in group if r["outcome"] == o) for o in ("created", "declined", "failed")},
                "duration_ms": mean_min_max(durs),
                "output_tokens": mean_min_max(out_tokens),
                "input_tokens": mean_min_max(in_tokens),
                "build_ok_rate": rate(sum(1 for b in build_oks if b), len(build_oks)),
                "tests_pass_rate": rate(tests_passed, tests_total),
                "tests_total": tests_total,
                "tests_passed": tests_passed,
            }
            if costs:
                entry["cost_usd"] = mean_min_max(costs)
            summary["scenarios"][sc][kind] = entry

    # derived: shunt vs direct, Claude-side output tokens and real $ cost.
    for sc in scenarios:
        s = summary["scenarios"][sc]
        direct = s.get("direct", {})
        shunt = s.get("shunt", {})
        diff = {}
        # Only meaningful once both sides actually have data - a shunt group
        # with zero rows (e.g. LIVE_EVAL_KINDS=direct) must not be silently
        # read as "100% saved".
        if direct.get("output_tokens") and shunt.get("n"):
            direct_tok = direct["output_tokens"]["mean"]
            shunt_out = shunt.get("output_tokens")
            shunt_tok = shunt_out["mean"] if shunt_out else 0.0
            diff["output_tokens_saved"] = direct_tok - shunt_tok
            diff["output_tokens_saved_pct"] = (
                (direct_tok - shunt_tok) / direct_tok * 100 if direct_tok else None
            )
        if direct.get("cost_usd") and shunt.get("n"):
            direct_cost = direct["cost_usd"]["mean"]
            diff["cost_usd_saved"] = direct_cost  # shunt's Claude-side cost is 0
            diff["cost_usd_saved_pct"] = 100.0 if direct_cost else None
        s["shunt_vs_direct"] = diff

    json.dump(summary, open(summary_path, "w"), indent=2)

    # human-readable table
    print(f"{'scenario':<12}{'kind':<8}{'n':>3}  outcomes (created/declined/failed)  build_ok  tests pass/total  time ms (mean/min/max)")
    for sc in scenarios:
        for kind in kinds:
            e = summary["scenarios"][sc].get(kind, {})
            if not e:
                print(f"{sc:<12}{kind:<8}  no data")
                continue
            oc = e["outcomes"]
            oc_s = f"{oc['created']}/{oc['declined']}/{oc['failed']}"
            build_s = f"{e['build_ok_rate']*100:.0f}%" if e["build_ok_rate"] is not None else "n/a"
            tests_s = f"{e['tests_passed']}/{e['tests_total']}"
            dur = e.get("duration_ms")
            dur_s = f"{dur['mean']:.0f} / {dur['min']:.0f} / {dur['max']:.0f}" if dur else "n/a"
            print(f"{sc:<12}{kind:<8}{e['n']:>3}  {oc_s:<36} {build_s:<9}{tests_s:<18}{dur_s}")
        diff = summary["scenarios"][sc].get("shunt_vs_direct", {})
        if diff:
            parts = []
            if "output_tokens_saved" in diff:
                pct = diff["output_tokens_saved_pct"]
                pct_s = f"{pct:+.1f}%" if pct is not None else "n/a"
                parts.append(f"output tokens: {diff['output_tokens_saved']:+.0f} ({pct_s})")
            if "cost_usd_saved" in diff:
                parts.append(f"cost: ${diff['cost_usd_saved']:.4f} saved (shunt's Claude-side cost is $0)")
            print(f"{'':<12}shunt vs direct  " + "   ".join(parts))
        print()

    print(f"Summary written to {summary_path}")


if __name__ == "__main__":
    main()
