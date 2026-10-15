#!/usr/bin/env python3
"""Checks bench-out/accept.jsonl (from `go run ./bench/accept`) against the
pass conditions and prints a markdown report.

Pass when all hold:
  - repetition: 0 utterances where any whisper pass looped (core.IsRepetitive),
    even if Koe's retry fixed it
  - match: mean difflib ratio of the pasted text vs the expected sentence
    (spaces / punctuation removed) >= --min-match
  - speed: median time per utterance (all passes) <= --max-median-ms
    (6 s on the 2-core runner; a 12-thread PC is about 3x faster)
  judged on Koe's prompt ("koe"); "short" (default sentence only) is shown for comparison

    python3 bench/accept/summary.py bench-out/accept.jsonl [--cpu NAME] [--minutes N]
"""
import argparse
import difflib
import json
import math
import os
import statistics
import sys

PUNCT = set(" 　、。，,.！？!?「」『』・\n\t")


def norm(s):
    return "".join(c for c in s if c not in PUNCT)


def ratio(a, b):
    return difflib.SequenceMatcher(None, norm(a), norm(b)).ratio()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    ap.add_argument("--cpu", default="")
    ap.add_argument("--logical-cpus", default="")
    ap.add_argument("--minutes", type=float, default=None)
    ap.add_argument("--usd-per-minute", type=float, default=0.010)
    ap.add_argument("--min-match", type=float, default=0.9)
    ap.add_argument("--max-median-ms", type=float, default=6000)
    a = ap.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")  # the Windows console defaults to cp1252

    rs = []
    if os.path.exists(a.results):
        with open(a.results, encoding="utf-8") as f:
            rs = [json.loads(l) for l in f if l.strip()]
    for r in rs:
        r.setdefault("prompt", "koe")

    out = ["## Koe acceptance check (Windows, Koe's transcription path)", ""]
    if a.cpu:
        out.append(f"- runner CPU: {a.cpu}" + (f" ({a.logical_cpus} logical processors)" if a.logical_cpus else ""))
    if a.minutes is not None:
        billed = math.ceil(a.minutes)
        out.append(f"- job time: {a.minutes:.1f} min (billed {billed} min) → estimated cost ${billed * a.usd_per_minute:.3f} (at ${a.usd_per_minute:.3f}/min)")
    if not rs:
        out += ["", "**FAIL** — no results."]
        print("\n".join(out))
        return 1
    modes = list(dict.fromkeys(r["prompt"] for r in rs))
    judged = "koe" if "koe" in modes else modes[0]
    model, threads = rs[0]["model"], rs[0]["threads"]
    out.append(f"- {model}, {threads} threads, audioCtx auto, no temperature fallback; prompts: "
               + ", ".join(f"`{m}`" for m in modes) + f" (pass / fail on `{judged}`: Koe's prompt with the default packs)")

    def stats(g):
        return {
            "n": len(g),
            "looped": sum(1 for r in g if any(p["repetitive"] for p in r["passes"])),
            "stock": sum(1 for r in g if any(p.get("stock") for p in r["passes"])),
            "retried": sum(1 for r in g if len(r["passes"]) > 1),
            "failed": sum(1 for r in g if r.get("error") or r["outcome"] in ("error", "hallucination")),
            "match": statistics.mean(ratio(r["text"], r["expected"]) for r in g),
            "median": statistics.median(r["ms"] for r in g),
        }

    by_mode = {m: [r for r in rs if r["prompt"] == m] for m in modes}
    st = {m: stats(g) for m, g in by_mode.items()}
    j = st[judged]
    checks = [
        ("repetition", j["looped"] == 0, f"{j['looped']} utterances looped (want 0)"),
        ("match", j["match"] >= a.min_match, f"mean {j['match']:.3f} (want ≥ {a.min_match})"),
        ("speed", j["median"] <= a.max_median_ms, f"median {j['median'] / 1000:.2f} s per utterance (want ≤ {a.max_median_ms / 1000:.1f} s on this runner)"),
    ]
    if j["failed"]:
        checks.append(("errors", False, f"{j['failed']} utterances failed or produced nothing"))
    passed = all(ok for _, ok, _ in checks)
    out += ["", f"### {'PASS' if passed else 'FAIL'}", ""]
    for name, ok, detail in checks:
        out.append(f"- {'✅' if ok else '❌'} {name}: {detail}")

    out += ["", "### Prompts", "", "| prompt | utterances | median s | mean match | looped | stock phrase | retried | failed |",
            "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for m in modes:
        x = st[m]
        out.append(f"| {m} | {x['n']} | {x['median'] / 1000:.2f} | {x['match']:.3f} | {x['looped']} | {x['stock']} | {x['retried']} | {x['failed']} |")
    if len(modes) > 1 and "short" in st and "koe" in st:
        d = st["koe"]["median"] - st["short"]["median"]
        out.append("")
        out.append(f"Koe's prompt vs short: {d / 1000:+.2f} s median per utterance ({d / st['short']['median'] * 100:+.0f}%).")

    cols = "".join(f" {m} ms |" for m in modes) + "".join(f" {m} match |" for m in modes)
    out += ["", f"| id | audio s |{cols} retried ({judged}) | output ({judged}, first run) |",
            "|---|---:|" + "---:|" * (2 * len(modes)) + "---:|---|"]
    ids = list(dict.fromkeys(r["id"] for r in rs))
    for id_ in ids:
        g = {m: [r for r in by_mode[m] if r["id"] == id_] for m in modes}
        any_g = next(v for v in g.values() if v)
        sec = any_g[0]["seconds"]
        meds = "".join(f" {statistics.median(r['ms'] for r in g[m]):.0f} |" if g[m] else " – |" for m in modes)
        mats = "".join(f" {statistics.mean(ratio(r['text'], r['expected']) for r in g[m]):.2f} |" if g[m] else " – |" for m in modes)
        gj = g.get(judged) or any_g
        retried = sum(1 for r in gj if len(r["passes"]) > 1)
        text = gj[0]["text"].replace("|", "\\|")
        if len(text) > 50:
            text = text[:49] + "…"
        out.append(f"| {id_} | {sec:.1f} |{meds}{mats} {retried}/{len(gj)} | {text} |")

    odd = [r for r in rs if any(p["repetitive"] or p.get("stock") for p in r["passes"])]
    if odd:
        out += ["", "Looped or stock-phrase outputs (before Koe's retry → what Koe pastes):", ""]
        for r in odd[:8]:
            t = next(p["text"] for p in r["passes"] if p["repetitive"] or p.get("stock"))
            out.append(f"- {r['id']} {r['prompt']} run {r['run']}: {t[:100]} → {r['text'][:80]}")
    print("\n".join(out))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
