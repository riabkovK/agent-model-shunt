#!/usr/bin/env python3
"""Aggregates evals/results/baseline-benchmark.jsonl into summary stats and
prints a comparison table: no-resume vs resume (Claude reading files
directly) vs shunt (delegated via scripts/bulk-read), per scenario.

Usage: aggregate-baseline-results.py <rows.jsonl> <summary-out.json>
"""
import json
import statistics as st
import sys
from collections import defaultdict


def mean_min_max(vals):
    if not vals:
        return None
    return {"mean": st.mean(vals), "min": min(vals), "max": max(vals), "n": len(vals)}


def main():
    rows_path, summary_path = sys.argv[1], sys.argv[2]
    rows = [json.loads(line) for line in open(rows_path) if line.strip()]

    by_key = defaultdict(list)
    for r in rows:
        by_key[(r["scenario"], r["kind"])].append(r)

    scenarios = sorted({r["scenario"] for r in rows})
    kinds = ["no-resume", "resume", "shunt", "shunt-live"]

    summary = {"scenarios": {}}
    for sc in scenarios:
        summary["scenarios"][sc] = {}
        for kind in kinds:
            group = [r for r in by_key.get((sc, kind), []) if not r.get("failed")]
            tokens = [r["context_tokens"] for r in group]
            durs = [r["duration_ms"] for r in group]
            costs = [r["cost_usd"] for r in group if r.get("cost_usd") is not None]
            entry = {
                "context_tokens": mean_min_max(tokens),
                "duration_ms": mean_min_max(durs),
            }
            if costs:
                entry["cost_usd"] = mean_min_max(costs)
            summary["scenarios"][sc][kind] = entry

    # derived: shunt(-live) vs no-resume / resume, tokens and time, % and absolute
    for sc in scenarios:
        s = summary["scenarios"][sc]
        for shunt_kind, diff_key in (("shunt", "shunt_vs"), ("shunt-live", "shunt_live_vs")):
            diffs = {}
            for baseline_kind in ("no-resume", "resume"):
                base = s.get(baseline_kind, {})
                shunt = s.get(shunt_kind, {})
                if not base.get("context_tokens") or not shunt.get("context_tokens"):
                    continue
                base_tok = base["context_tokens"]["mean"]
                shunt_tok = shunt["context_tokens"]["mean"]
                base_ms = base["duration_ms"]["mean"]
                shunt_ms = shunt["duration_ms"]["mean"]
                diffs[baseline_kind] = {
                    "tokens_saved": base_tok - shunt_tok,
                    "tokens_saved_pct": (base_tok - shunt_tok) / base_tok * 100 if base_tok else None,
                    "time_added_ms": shunt_ms - base_ms,
                    "time_added_pct": (shunt_ms - base_ms) / base_ms * 100 if base_ms else None,
                }
            s[diff_key] = diffs

    json.dump(summary, open(summary_path, "w"), indent=2)

    # human-readable table
    print(f"{'scenario':<24}{'kind':<12}{'n':>3}  tokens (mean/min/max)            time ms (mean/min/max)")
    for sc in scenarios:
        for kind in kinds:
            e = summary["scenarios"][sc].get(kind, {})
            tok = e.get("context_tokens")
            dur = e.get("duration_ms")
            if not tok or not dur:
                print(f"{sc:<24}{kind:<12}  no data")
                continue
            tok_s = f"{tok['mean']:.0f} / {tok['min']:.0f} / {tok['max']:.0f}"
            dur_s = f"{dur['mean']:.0f} / {dur['min']:.0f} / {dur['max']:.0f}"
            print(f"{sc:<24}{kind:<12}{tok['n']:>3}  {tok_s:<34}{dur_s}")
        for shunt_kind, diff_key in (("shunt", "shunt_vs"), ("shunt-live", "shunt_live_vs")):
            diffs = summary["scenarios"][sc].get(diff_key, {})
            for baseline_kind, d in diffs.items():
                print(
                    f"{'':<24}{shunt_kind} vs {baseline_kind:<10} "
                    f"tokens: {d['tokens_saved']:+.0f} ({d['tokens_saved_pct']:+.1f}%)   "
                    f"time: {d['time_added_ms']:+.0f}ms ({d['time_added_pct']:+.1f}%)"
                )
        print()

    print(f"Summary written to {summary_path}")


if __name__ == "__main__":
    main()
