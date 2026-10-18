#!/usr/bin/env python3
"""Pre-publication check of what a release adds to the public repository.

Scans the lines added or changed between two git trees (the previous public
release and the tree about to be published) and the names of new files for:

- words in the denylist, a file kept outside the repository
  (default ~/.config/koe/release-denylist.txt: one case-insensitive regular
  expression per line; blank lines and lines starting with # are ignored);
- generic patterns: e-mail addresses (except noreply), links to chat / document
  services, private IP addresses, internal host names, tokens and private
  keys (also gitleaks when it is installed), and absolute paths under a
  user's home directory.

Hits are printed as "path:line: category" only; the matched text is never
printed. False positives of the generic patterns are allowed by listing
"path:hash" in scripts/release/scrub-allow.txt, where hash is the one printed
for the hit (a hash of the line's content, so it survives line moves).
Denylist hits cannot be allowed; refine the denylist instead.

Exit status: 0 clean, 1 hits, 2 setup error (no denylist, bad regex, git).

    python3 scripts/release/scrub.py <base-rev> <target-rev>
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DENYLIST = os.path.expanduser("~/.config/koe/release-denylist.txt")
DEFAULT_ALLOW = os.path.join(HERE, "scrub-allow.txt")

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
EMAIL_OK_DOMAINS = ("example.com", "example.org", "example.net", "github.com")

SERVICE_URL = re.compile(
    r"(?i)(?<![\w.-])(?:[a-z0-9-]+\.)*"
    r"(?:slack\.com|notion\.so|notion\.site|docs\.google\.com|drive\.google\.com|"
    r"sheets\.google\.com|slides\.google\.com|forms\.gle|atlassian\.net|"
    r"sharepoint\.com|miro\.com|figma\.com|zoom\.us|teams\.microsoft\.com|"
    r"larksuite\.com|quip\.com|box\.com)(?![\w-])")

PRIVATE_IP = re.compile(
    r"(?<![\w.])(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01])|"
    r"100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])|169\.254)\.\d{1,3}\.\d{1,3}(?![\w.])")

# lowercase only: Go's time.Local and similar identifiers are not hosts
INTERNAL_HOST = re.compile(
    r"(?<![\w./-])[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9-]+)*\.(?:internal|corp|local|intranet)(?![\w-])")

HOME_NAME = r"([^/\\\s\"'`<>$%{}()\[\]*]+)"
HOME_PATH = [
    re.compile(r"/Users/" + HOME_NAME + r"/"),
    re.compile(r"/home/" + HOME_NAME + r"/"),
    re.compile(r"[A-Za-z]:\\{1,2}Users\\{1,2}" + HOME_NAME + r"\\"),
]
# placeholders used in docs ("/Users/you/…") and shared or CI accounts
HOME_OK = {"shared", "public", "default", "you", "me", "user", "username", "name",
           "yourname", "your-name", "your_name", "someone", "runner", "runneradmin", "example", "..."}

SECRETS = [
    re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{40,}"),
    re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}"),
    re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{35}"),
    re.compile(r"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}"),
    re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}"),
    re.compile(r"\bnpm_[A-Za-z0-9]{36}\b"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
    re.compile(r"(?i)\b(?:api[_-]?key|secret|token|passw(?:or)?d)\w*[\"']?\s*[:=]\s*[\"'][A-Za-z0-9+/_=.-]{16,}[\"']"),
]


def line_hash(text):
    return hashlib.sha256(text.encode("utf-8", "surrogateescape")).hexdigest()[:16]


def generic_hits(text):
    """Categories of the generic patterns found in text (no matched text)."""
    found = []
    for m in EMAIL.finditer(text):
        addr = m.group(0).lower()
        domain = addr.rsplit("@", 1)[1]
        if "noreply" in addr or domain in EMAIL_OK_DOMAINS or domain.endswith(".example"):
            continue
        found.append("email address")
        break
    if SERVICE_URL.search(text):
        found.append("chat/document service link")
    if PRIVATE_IP.search(text):
        found.append("private IP address")
    if INTERNAL_HOST.search(text):
        found.append("internal host name")
    for rx in HOME_PATH:
        if any(m.group(1).lower() not in HOME_OK for m in rx.finditer(text)):
            found.append("home directory path")
            break
    if any(rx.search(text) for rx in SECRETS):
        found.append("token or private key")
    return found


def load_denylist(path):
    if not os.path.isfile(path):
        raise SetupError(f"denylist not found: {path}")
    rules = []
    with open(path, encoding="utf-8") as f:
        for n, raw in enumerate(f, 1):
            s = raw.strip()
            if not s or s.startswith("#"):
                continue
            try:
                rules.append((n, re.compile(s, re.IGNORECASE)))
            except re.error as e:
                # the pattern itself is not printed
                raise SetupError(f"denylist line {n}: invalid regular expression ({e.msg})")
    if not rules:
        raise SetupError(f"denylist has no patterns: {path}")
    return rules


def load_allow(path):
    allowed = set()
    if not os.path.isfile(path):
        return allowed
    with open(path, encoding="utf-8") as f:
        for raw in f:
            s = raw.split("#", 1)[0].strip()
            if s:
                allowed.add(s)
    return allowed


class SetupError(Exception):
    pass


def git(repo, *args, binary=False):
    p = subprocess.run(["git", "-C", repo, "-c", "core.quotepath=false", *args],
                       capture_output=True)
    if p.returncode != 0:
        raise SetupError(f"git {' '.join(args[:2])} failed: {p.stderr.decode(errors='replace').strip()}")
    return p.stdout if binary else p.stdout.decode("utf-8", "surrogateescape")


def changed_lines(repo, base, target):
    """{path: [(line number, text)]} of added lines, and the binary paths."""
    out = git(repo, "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames",
              "--unified=0", base, target)
    lines, binary = {}, []
    path, n = None, 0
    for raw in out.split("\n"):
        if raw.startswith("+++ "):
            # git ends the name with a tab when it contains a space
            path = raw[6:].rstrip("\t") if raw.startswith("+++ b/") else None
            continue
        if raw.startswith("Binary files "):
            m = re.match(r"Binary files (?:a/.+|/dev/null) and b/(.+) differ$", raw)
            if m:
                binary.append(m.group(1))
            continue
        if raw.startswith("@@"):
            m = re.match(r"@@ -\S+ \+(\d+)", raw)
            n = int(m.group(1)) if m else 0
            continue
        if path and raw.startswith("+"):
            lines.setdefault(path, []).append((n, raw[1:]))
            n += 1
    return lines, binary


def binary_strings(data, minlen=6):
    """Printable runs of a binary file (ASCII and UTF-8), like strings(1)."""
    text = data.decode("utf-8", "replace")
    return [m.group(0) for m in re.finditer(r"[^\x00-\x08\x0e-\x1f\x7f�]{%d,}" % minlen, text)]


def new_files(repo, base, target):
    out = git(repo, "diff", "--name-only", "--no-renames", "--diff-filter=A", "-z", base, target)
    return [p for p in out.split("\0") if p]


def gitleaks_hits(repo, target, lines):
    """(path, line) of gitleaks findings on the changed lines; None without gitleaks."""
    exe = shutil.which("gitleaks")
    if not exe:
        return None
    if not lines:
        return set()
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        for path in lines:
            dst = os.path.join(src, path)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, "wb") as f:
                f.write(git(repo, "show", f"{target}:{path}", binary=True))
        report = os.path.join(tmp, "report.json")
        p = subprocess.run([exe, "detect", "--no-git", "--no-banner", "--redact", "--exit-code", "0",
                            "--source", ".", "--report-format", "json", "--report-path", report],
                           cwd=src, capture_output=True)
        if p.returncode != 0 or not os.path.exists(report):
            raise SetupError("gitleaks failed")
        with open(report, encoding="utf-8") as f:
            findings = json.load(f) or []
        hits = set()
        for item in findings:
            f = item.get("File", "")
            path = os.path.relpath(f if os.path.isabs(f) else os.path.join(src, f), src)
            hits.add((path, int(item.get("StartLine", 0))))
    return hits


def scan(repo, base, target, denylist, allow):
    """List of (path, line, category, hash or None, allowed)."""
    lines, binary = changed_lines(repo, base, target)
    for path in binary:
        data = git(repo, "show", f"{target}:{path}", binary=True)
        lines.setdefault(path, []).extend((0, s) for s in binary_strings(data))
    names = new_files(repo, base, target)
    hits = []

    def check(path, n, text):
        for rule, rx in denylist:
            if rx.search(text):
                hits.append((path, n, f"denylist #{rule}", None, False))
        cats = generic_hits(text)
        if cats:
            h = line_hash(text)
            ok = f"{path}:{h}" in allow
            hits.extend((path, n, c, h, ok) for c in cats)

    for path in names:
        check(path, "name", path)
    for path, items in lines.items():
        for n, text in items:
            check(path, n, text)

    leaks = gitleaks_hits(repo, target, {p: v for p, v in lines.items() if p not in binary})
    if leaks:
        texts = {(p, n): t for p, items in lines.items() for n, t in items}
        changed = set(texts)
        for path, n in sorted(leaks & changed):
            h = line_hash(texts[(path, n)])
            hits.append((path, n, "token or private key (gitleaks)", h, f"{path}:{h}" in allow))
    return hits, (leaks is not None)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("base", help="previous public release (e.g. public/main)")
    ap.add_argument("target", help="tree to publish (e.g. the release commit)")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--denylist", default=os.environ.get("KOE_RELEASE_DENYLIST", DEFAULT_DENYLIST))
    ap.add_argument("--allow", default=DEFAULT_ALLOW)
    a = ap.parse_args(argv)
    try:
        denylist = load_denylist(a.denylist)
        hits, used_gitleaks = scan(a.repo, a.base, a.target, denylist, load_allow(a.allow))
    except SetupError as e:
        print(f"scrub: error: {e}", file=sys.stderr)
        return 2
    blocking = [h for h in hits if not h[4]]
    for path, n, cat, h, ok in hits:
        where = f"{path}:{n}" if n != 0 else f"{path}:(binary)"
        tail = f"  [allow: {path}:{h}]" if h else ""
        print(f"{'allowed' if ok else 'HIT'}  {where}: {cat}{tail}")
    print(f"scrub: {len(blocking)} hit(s), {len(hits) - len(blocking)} allowed, "
          f"{len(denylist)} denylist pattern(s), gitleaks {'used' if used_gitleaks else 'not installed (regex only)'}")
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main())
