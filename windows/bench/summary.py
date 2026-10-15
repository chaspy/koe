#!/usr/bin/env python3
"""Turns bench-out/results.jsonl (from `go run ./bench`) into a markdown table.

    python3 bench/summary.py bench-out/results.jsonl [--cpu NAME] [--minutes N] [--usd-per-minute 0.010]

match = difflib.SequenceMatcher ratio of the output and the expected sentence
(sentences.tsv), after removing spaces and punctuation.
"""
import argparse
import difflib
import json
import os
import statistics
import sys

PUNCT = set(" 　、。，,.！？!?「」『』・\n\t")


def norm(s):
    return "".join(c for c in s if c not in PUNCT)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    ap.add_argument("--sentences", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "sentences.tsv"))
    ap.add_argument("--cpu", default="")
    ap.add_argument("--logical-cpus", default="")
    ap.add_argument("--minutes", type=float, default=None, help="job minutes so far (billed rounded up)")
    ap.add_argument("--usd-per-minute", type=float, default=0.010)
    a = ap.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")  # the Windows console defaults to cp1252

    expected = {}
    with open(a.sentences, encoding="utf-8") as f:
        for line in f:
            if "\t" in line:
                k, v = line.rstrip("\n").split("\t", 1)
                expected[k] = v

    rows = {}
    order = []
    if os.path.exists(a.results):
        with open(a.results, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                r = json.loads(line)
                key = (r["model"], r["threads"], r["audio"], r["ctx_mode"])
                if key not in rows:
                    rows[key] = []
                    order.append(key)
                rows[key].append(r)

    out = ["## Windows whisper-server bench", ""]
    if a.cpu:
        out.append(f"- runner CPU: {a.cpu}" + (f" ({a.logical_cpus} logical processors)" if a.logical_cpus else ""))
    if a.minutes is not None:
        import math
        billed = math.ceil(a.minutes)
        out.append(f"- job time: {a.minutes:.1f} min (billed {billed} min) → estimated cost ${billed * a.usd_per_minute:.3f} (at ${a.usd_per_minute:.3f}/min)")
    out.append("- requests as Koe sends them: greedy, no temperature fallback, Koe's default prompt; the first request after each server start is not measured")
    out.append("")
    if not order:
        out.append("No results.")
        print("\n".join(out))
        return
    out.append("| model | threads | audio | audio s | audio_ctx | runs | median ms | ms / audio s | match | repetition | output (first run) |")
    out.append("|---|---:|---|---:|---|---:|---:|---:|---:|---|---|")
    for key in order:
        rs = rows[key]
        ok = [r for r in rs if not r.get("error")]
        model, threads, audio, mode = key
        sec = rs[0]["seconds"]
        ctx = "0 (whole)" if mode == "0" else f"auto ({rs[0]['audio_ctx']})"
        if ok:
            med = statistics.median(r["ms"] for r in ok)
            per = med / sec if sec else 0
            match = statistics.median(difflib.SequenceMatcher(None, norm(r["text"]), norm(expected.get(audio, ""))).ratio() for r in ok)
            reps = sum(1 for r in ok if r["repetitive"])
            text = ok[0]["text"].replace("|", "\\|")
            if len(text) > 60:
                text = text[:59] + "…"
            out.append(f"| {model} | {threads} | {audio} | {sec:.1f} | {ctx} | {len(ok)} | {med:.0f} | {per:.0f} | {match:.2f} | {'**yes** ' + str(reps) + '/' + str(len(ok)) if reps else 'no'} | {text} |")
        else:
            out.append(f"| {model} | {threads} | {audio} | {sec:.1f} | {ctx} | 0 | – | – | – | – | error: {rs[0]['error'][:60]} |")
    print("\n".join(out))


if __name__ == "__main__":
    sys.exit(main())
