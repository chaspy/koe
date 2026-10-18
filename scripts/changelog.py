#!/usr/bin/env python3
"""Release notes from changelog.d/ fragments.

Each PR adds its own file changelog.d/<PR number or short name>.md instead of
editing CHANGELOG.md, so parallel PRs never conflict:

    ### macOS
    - What changed for the user.

    ### Windows
    - ...

Sections: ### Repository, ### macOS, ### Windows (only the ones that apply).

  python3 scripts/changelog.py check              # validate the fragments
  python3 scripts/changelog.py preview            # print the section a release would add
  python3 scripts/changelog.py release 0.8.0      # fold the fragments (and any "## Unreleased")
                                                  # into "## 0.8.0 — <today>" and delete them
  python3 scripts/changelog.py release 0.8.1 --hold Windows
                                                  # a macOS-only release: "### Windows" says
                                                  # "- No changes." and the Windows parts stay
                                                  # in changelog.d/ for the next release

The apps read CHANGELOG.md at the release tag (the first item under
"### macOS" / "### Windows" of "## <version>"), so the folded format must stay:
an app section with no fragments is written as "- No changes." (the app then does
not ask to update), and the first item is the one the update prompt shows.
Fragments are folded in PR-number order, so before tagging, read the
"update prompt shows" lines that preview/release print and move the most
important item to the top of its section in CHANGELOG.md if needed.
"""
import argparse
import datetime
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SECTIONS = ["Repository", "macOS", "Windows"]


def fragments(root):
    """changelog.d/*.md, numbered ones (PR numbers) first in number order, then by name."""
    def key(p):
        n = p.stem.split("-")[0]
        return (0, int(n), p.name) if n.isdigit() else (1, 0, p.name)
    d = root / "changelog.d"
    return sorted(d.glob("*.md"), key=key) if d.is_dir() else []


def parse(text, name):
    """{section: [lines]} from '### X' headings. Raises ValueError on bad input."""
    out, cur = {}, None
    for i, line in enumerate(text.splitlines(), 1):
        if line.startswith("### "):
            cur = line[4:].strip()
            if cur not in SECTIONS:
                raise ValueError(f"{name}:{i}: unknown section '### {cur}' (use {', '.join('### ' + s for s in SECTIONS)})")
            out.setdefault(cur, [])
        elif line.startswith("#"):
            raise ValueError(f"{name}:{i}: only '### <section>' headings are allowed")
        elif line.strip():
            if cur is None:
                raise ValueError(f"{name}:{i}: text before the first '### <section>' heading")
            out[cur].append(line)
    if not any(out.values()):
        raise ValueError(f"{name}: no entries")
    for s, lines in out.items():
        if lines and not lines[0].startswith("- "):
            raise ValueError(f"{name}: '### {s}' must start with a '- ' item")
    return out


def split_unreleased(changelog):
    """(changelog without the '## Unreleased' section, its body)."""
    m = re.search(r"(?m)^## Unreleased[^\n]*\n(.*?)(?=^## |\Z)", changelog, re.S)
    if not m:
        return changelog, ""
    return changelog[:m.start()] + changelog[m.end():], m.group(1)


def collect(root, hold=()):
    """(CHANGELOG.md without "## Unreleased", {section: lines} to release, {fragment: its held sections})."""
    merged = {s: [] for s in SECTIONS}
    changelog = (root / "CHANGELOG.md").read_text(encoding="utf-8")
    rest, unreleased = split_unreleased(changelog)
    sources = []
    if unreleased.strip():
        sources.append((None, "CHANGELOG.md (## Unreleased)", unreleased))
    sources += [(p, f"changelog.d/{p.name}", p.read_text(encoding="utf-8")) for p in fragments(root)]
    held = {}
    for path, name, text in sources:
        for s, lines in parse(text, name).items():
            if s not in hold:
                merged[s] += lines
            elif path is None:
                raise ValueError(f"{name} has '### {s}', which is held; move it to a file in changelog.d/ first")
            elif lines:
                held.setdefault(path, {})[s] = lines
    return rest, merged, held


def held_fragment(sections):
    return "\n".join(line for s in SECTIONS if s in sections for line in [f"### {s}", *sections[s], ""]).rstrip("\n") + "\n"


# The apps skip the update prompt when their section says "No changes.", so both app sections are always written
APP_SECTIONS = ["macOS", "Windows"]


def render(version, date, merged):
    out = [f"## {version} — {date}", ""]
    for s in SECTIONS:
        if merged[s]:
            out += [f"### {s}", *merged[s], ""]
        elif s in APP_SECTIONS:
            out += [f"### {s}", "- No changes.", ""]
    return "\n".join(out)


def headlines(merged):
    """What each app's update prompt will show: the first item of its section."""
    return [f"{s}: {merged[s][0][2:] if merged[s] else '(No changes. — no prompt)'}" for s in APP_SECTIONS]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["check", "preview", "release"])
    ap.add_argument("version", nargs="?")
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--root", type=pathlib.Path, default=ROOT)
    ap.add_argument("--hold", action="append", default=[], choices=APP_SECTIONS,
                    help="leave this app out of the release (repeatable): its section says "
                         "'- No changes.' and its entries stay in changelog.d/")
    a = ap.parse_args()
    try:
        rest, merged, held = collect(a.root, a.hold)
    except ValueError as e:
        sys.exit(f"changelog: {e}")
    if a.cmd == "check":
        print(f"ok: {len(fragments(a.root))} fragment(s)")
        return
    section = render(a.version or "<version>", a.date, merged)
    if a.cmd == "preview":
        print(section)
        print("update prompt shows:", *headlines(merged), sep="\n  ")
        return
    if not a.version:
        sys.exit("changelog: release needs a version")
    if not any(merged.values()):
        sys.exit("changelog: nothing to release (no fragments in changelog.d/)")
    if re.search(rf"(?m)^## {re.escape(a.version)}( |$)", rest):
        sys.exit(f"changelog: CHANGELOG.md already has '## {a.version}'")
    m = re.search(r"(?m)^## ", rest)
    at = m.start() if m else len(rest)
    (a.root / "CHANGELOG.md").write_text(rest[:at] + section + "\n" + rest[at:], encoding="utf-8")
    for p in fragments(a.root):
        if p in held:
            p.write_text(held_fragment(held[p]), encoding="utf-8")
        else:
            p.unlink()
    print(f"CHANGELOG.md: added '## {a.version} — {a.date}'; removed the fragments"
          + (f"; kept {', '.join(a.hold)} entries in {len(held)} fragment(s)" if a.hold else ""))
    print("update prompt shows (move a more important item to the top if needed):", *headlines(merged), sep="\n  ")


if __name__ == "__main__":
    main()
