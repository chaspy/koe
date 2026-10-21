#!/usr/bin/env python3
"""Risk level of a change (low / mid / high) from .github/risk-rules.txt.

    python3 scripts/pr_risk.py                          # origin/main...HEAD
    python3 scripts/pr_risk.py --base origin/main --head pr-123
    python3 scripts/pr_risk.py --files files.txt --patch change.patch   # without git

Prints the level on the first line and the reasons below it. Exit code is 0.

The rules are read from the *base* side (git show <base>:.github/risk-rules.txt),
so a pull request cannot lower its own risk by editing the rules. --rules
overrides that (for trying out a rules change).

Rule format (one per line, '#' starts a comment):

    <level> path <glob>       a changed file matching the glob ('*' also matches '/')
    high    diff <regex>      a changed line (+/-) in a file that is not low
    high    diff-all <regex>  a changed line in any file, low ones too

A file matching a high path is high; otherwise a low path is low; anything else
is mid. Then any changed line matching a high diff rule makes the change high.
Lines of docs (docs/*, *.md) are never scanned. The highest level wins.
"""
import argparse
import fnmatch
import re
import subprocess
import sys

ORDER = ["low", "mid", "high"]
RULES_PATH = ".github/risk-rules.txt"


def load_rules(text):
    return [line.split(None, 2) for line in text.splitlines() if line.strip() and not line.startswith("#")]


def path_match(rules, level, f):
    return next((p.strip() for lv, kind, p in rules
                 if lv == level and kind == "path" and fnmatch.fnmatchcase(f, p.strip())), None)


def is_doc(f):
    return f.startswith("docs/") or f.endswith(".md")


def classify(rules, files, patch):
    """(level, reasons) for the changed files and their unified diff."""
    level, reasons, low_files = "low", [], set()

    def raise_to(lv):
        return ORDER[max(ORDER.index(level), ORDER.index(lv))]

    for f in files:
        if (p := path_match(rules, "high", f)):
            level = "high"
            reasons.append(f"high: {f} (path {p})")
        elif path_match(rules, "low", f):
            low_files.add(f)
        else:
            level = raise_to("mid")
            reasons.append(f"mid: {f}")
    cur, in_hunk, seen = None, False, set()
    for line in patch.splitlines():
        if line.startswith("diff --git "):
            cur, in_hunk = line.split(" b/", 1)[-1], False
            continue
        if line.startswith("@@"):
            in_hunk = True
            continue
        if not in_hunk or cur is None or is_doc(cur) or line[:1] not in "+-":
            continue
        kinds = ("diff-all",) if cur in low_files else ("diff", "diff-all")
        for lv, kind, p in rules:
            if lv == "high" and kind in kinds and (cur, p) not in seen and re.search(p.strip(), line[1:]):
                seen.add((cur, p))
                level = "high"
                reasons.append(f"high: {cur} changes /{p.strip()}/")
    if not files:
        reasons.append("no changed files")
    if level == "low":
        reasons.append("all files are low: " + ", ".join(sorted(low_files)))
    return level, reasons


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="origin/main")
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--rules", help=f"rules file (default: {RULES_PATH} at --base)")
    ap.add_argument("--files", help="list of changed files (one per line) instead of git")
    ap.add_argument("--patch", help="unified diff instead of git (with --files)")
    a = ap.parse_args()

    if a.rules:
        rules_text = open(a.rules, encoding="utf-8").read()
    else:
        try:
            rules_text = git("show", f"{a.base}:{RULES_PATH}")
        except subprocess.CalledProcessError:
            sys.exit(f"pr_risk: no {RULES_PATH} at {a.base} (use --rules)")
    rules = load_rules(rules_text)
    if not rules:
        sys.exit("pr_risk: the rules are empty")

    if a.files:
        files = [line.strip() for line in open(a.files, encoding="utf-8") if line.strip()]
        patch = open(a.patch, encoding="utf-8", errors="replace").read() if a.patch else ""
    else:
        rng = f"{a.base}...{a.head}"
        files = [name for name in git("diff", "--name-only", rng).splitlines() if name]
        patch = git("diff", "-U0", rng)
    level, reasons = classify(rules, files, patch)
    print(level)
    print("\n".join(reasons))


if __name__ == "__main__":
    main()
