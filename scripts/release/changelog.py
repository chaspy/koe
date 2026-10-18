#!/usr/bin/env python3
"""CHANGELOG.md steps of a release.

    changelog.py cut 0.9.0 2026-10-20 [--file CHANGELOG.md]
        "## Unreleased" becomes "## 0.9.0 — 2026-10-20". A missing "### macOS"
        or "### Windows" subsection is added with "- No changes." (the
        in-app update prompt skips a platform whose section says so).
    changelog.py notes 0.9.0 [--file CHANGELOG.md] [--install install-notes.md] [--not-notarized]
        Prints the GitHub Release body: "## Changes" with the version's
        subsections, then "## Install" from install-notes.md ({version} is
        replaced, {gatekeeper} says whether the dmg is notarized).
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PLATFORMS = ("macOS", "Windows")
GATEKEEPER = {
    True: "The app is signed with Apple's Developer ID and notarized, so it opens without a warning.",
    False: "The app is signed with Apple's Developer ID but **not notarized** in this release "
           "(notarization was skipped): when macOS blocks it, open System Settings → "
           "Privacy & Security and click \"Open Anyway\".",
}


class ChangelogError(Exception):
    pass


def find_section(lines, match):
    """(start, end) line indexes of the "## " section whose title satisfies match."""
    start = None
    for i, line in enumerate(lines):
        if line.startswith("## "):
            if start is not None:
                return start, i
            if match(line[3:].strip()):
                start = i
    if start is None:
        raise ChangelogError("section not found")
    return start, len(lines)


def is_version(title, version):
    return title == version or title.startswith(version + " ")


def cut(text, version, date):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ChangelogError(f"not a version: {version}")
    lines = text.split("\n")
    if any(l.startswith("## ") and is_version(l[3:].strip(), version) for l in lines):
        raise ChangelogError(f"CHANGELOG.md already has a section for {version}")
    try:
        start, end = find_section(lines, lambda t: t == "Unreleased")
    except ChangelogError:
        raise ChangelogError('CHANGELOG.md has no "## Unreleased" section')
    body = lines[start + 1:end]
    if not any(l.startswith("- ") for l in body):
        raise ChangelogError('"## Unreleased" has no entries')
    # split into a preamble and "### " subsections
    pre, subs = [], []
    for l in body:
        if l.startswith("### "):
            subs.append([l[4:].strip(), []])
        elif subs:
            subs[-1][1].append(l)
        else:
            pre.append(l)
    names = [s[0] for s in subs]
    for p in PLATFORMS:
        if p in names:
            continue
        new = [p, ["- No changes.", ""]]
        if p == "macOS" and "Windows" in names:
            subs.insert(names.index("Windows"), new)
        else:
            if subs and subs[-1][1] and subs[-1][1][-1] != "":
                subs[-1][1].append("")
            subs.append(new)
        names = [s[0] for s in subs]
    out = [f"## {version} — {date}"] + pre
    for name, sub in subs:
        out += [f"### {name}"] + sub
    return "\n".join(lines[:start] + out + lines[end:])


def notes(text, version, install, notarized=True):
    lines = text.split("\n")
    try:
        start, end = find_section(lines, lambda t: is_version(t, version))
    except ChangelogError:
        raise ChangelogError(f"CHANGELOG.md has no section for {version}")
    body = "\n".join(lines[start + 1:end]).strip()
    if not body:
        raise ChangelogError(f"the {version} section is empty")
    return f"## Changes\n\n{body}\n\n## Install\n{install.replace('{version}', version).replace('{gatekeeper}', GATEKEEPER[notarized]).strip()}\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("cut")
    c.add_argument("version")
    c.add_argument("date")
    c.add_argument("--file", default="CHANGELOG.md")
    n = sub.add_parser("notes")
    n.add_argument("version")
    n.add_argument("--file", default="CHANGELOG.md")
    n.add_argument("--install", default=os.path.join(HERE, "install-notes.md"))
    n.add_argument("--not-notarized", action="store_true")
    a = ap.parse_args(argv)
    try:
        with open(a.file, encoding="utf-8") as f:
            text = f.read()
        if a.cmd == "cut":
            with open(a.file, "w", encoding="utf-8") as f:
                f.write(cut(text, a.version, a.date))
        else:
            with open(a.install, encoding="utf-8") as f:
                sys.stdout.write(notes(text, a.version, f.read(), notarized=not a.not_notarized))
    except (ChangelogError, OSError) as e:
        print(f"changelog: error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
