#!/usr/bin/env python3
"""GitHub Release body of a version, from its section of CHANGELOG.md.

    notes.py 0.9.0 [--file CHANGELOG.md] [--install install-notes.md] [--not-notarized] [--mac-only]
        Prints "## Changes" with the version's subsections, then "## Install"
        from install-notes.md ({version} is replaced, {gatekeeper} says whether
        the dmg is notarized; with --mac-only the Windows paragraph says that
        this release has no Windows build).

The version section itself is written at release time by
scripts/changelog.py release <version> (it folds changelog.d/).
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GATEKEEPER = {
    True: "The app is signed with Apple's Developer ID and notarized, so it opens without a warning.",
    False: "The app is signed with Apple's Developer ID but **not notarized** in this release "
           "(notarization was skipped): when macOS blocks it, open System Settings → "
           "Privacy & Security and click \"Open Anyway\".",
}


# replaces the "Windows …" paragraph of install-notes.md in a macOS-only release
WINDOWS_HELD = ("Windows: no new build in this release; keep using the Windows build of an earlier "
                "release. The Windows app does not offer this version as an update.")


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


def notes(text, version, install, notarized=True, mac_only=False):
    lines = text.split("\n")
    try:
        start, end = find_section(lines, lambda t: is_version(t, version))
    except ChangelogError:
        raise ChangelogError(f"CHANGELOG.md has no section for {version}")
    body = "\n".join(lines[start + 1:end]).strip()
    if not body:
        raise ChangelogError(f"the {version} section is empty")
    install = install.replace("{version}", version).replace("{gatekeeper}", GATEKEEPER[notarized]).strip()
    if mac_only:
        paragraphs = install.split("\n\n")
        if not any(p.startswith("Windows") for p in paragraphs):
            raise ChangelogError("install notes have no Windows paragraph to replace")
        install = "\n\n".join(WINDOWS_HELD if p.startswith("Windows") else p for p in paragraphs)
    return f"## Changes\n\n{body}\n\n## Install\n{install}\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("version")
    ap.add_argument("--file", default="CHANGELOG.md")
    ap.add_argument("--install", default=os.path.join(HERE, "install-notes.md"))
    ap.add_argument("--not-notarized", action="store_true")
    ap.add_argument("--mac-only", action="store_true")
    a = ap.parse_args(argv)
    try:
        with open(a.file, encoding="utf-8") as f:
            text = f.read()
        with open(a.install, encoding="utf-8") as f:
            sys.stdout.write(notes(text, a.version, f.read(), notarized=not a.not_notarized, mac_only=a.mac_only))
    except (ChangelogError, OSError) as e:
        print(f"notes: error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
