#!/usr/bin/env python3
"""Aggregates evals/results/fidelity-benchmark.jsonl into summary stats and
prints a per-question comparison: direct-read recall vs delegated-read
(final) recall against ground truth, plus any unsupported (possibly
hallucinated) claims.

Usage: aggregate-fidelity-results.py <rows.jsonl> <summary-out.json>
"""
import json
import statistics as st
import sys
from collections import defaultdict


def mean(vals):
    return st.mean(vals) if vals else None


def main():
    rows_path, summary_path = sys.argv[1], sys.argv[2]
    rows = [json.loads(line) for line in open(rows_path) if line.strip()]

    by_question = defaultdict(list)
    for r in rows:
        by_question[r["name"]].append(r)

    names = sorted(by_question)

    summary = {"questions": {}}
    for name in names:
        group = by_question[name]
        adversarial = group[0]["adversarial"]

        direct_recalls = [
            len(r["direct_recall"]["matched"]) / r["direct_recall"]["total"]
            for r in group if not r["direct_failed"] and r["direct_recall"]["total"]
        ]
        final_recalls = [
            len(r["final_recall"]["matched"]) / r["final_recall"]["total"]
            for r in group if not r["final_failed"] and r["final_recall"]["total"]
        ]
        unsupported_all = [c for r in group for c in r.get("unsupported_claims", [])]
        unmatched_direct = sorted({u for r in group if not r["direct_failed"] for u in r["direct_recall"]["unmatched"]})
        unmatched_final = sorted({u for r in group if not r["final_failed"] for u in r["final_recall"]["unmatched"]})

        summary["questions"][name] = {
            "adversarial": adversarial,
            "n": len(group),
            "direct_recall_mean": mean(direct_recalls),
            "final_recall_mean": mean(final_recalls),
            "direct_dropped_items": unmatched_direct,
            "delegate_dropped_items": unmatched_final,
            "unsupported_claims": sorted(set(unsupported_all)),
        }

    json.dump(summary, open(summary_path, "w"), indent=2)

    print(f"{'question':<28}{'adversarial':<13}{'direct recall':<16}{'delegate recall':<18}unsupported claims")
    for name in names:
        q = summary["questions"][name]
        d = f"{q['direct_recall_mean']:.0%}" if q["direct_recall_mean"] is not None else "n/a"
        f = f"{q['final_recall_mean']:.0%}" if q["final_recall_mean"] is not None else "n/a"
        u = ", ".join(q["unsupported_claims"]) if q["unsupported_claims"] else "-"
        print(f"{name:<28}{str(q['adversarial']):<13}{d:<16}{f:<18}{u}")
        if q["delegate_dropped_items"]:
            print(f"{'':<28}delegate path dropped: {', '.join(q['delegate_dropped_items'])}")
        if q["direct_dropped_items"]:
            print(f"{'':<28}direct path dropped:   {', '.join(q['direct_dropped_items'])}")

    print(f"\nSummary written to {summary_path}")


if __name__ == "__main__":
    main()
