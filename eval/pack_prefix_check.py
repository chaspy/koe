"""List prefix collisions between dictionary terms (#196).

A term that another term starts with and continues as one word (HTM / HTML: the next
character is an ASCII letter/digit or katakana; same case) pulls the longer one down in
whisper's initial prompt. Terms that continue after a space or symbol (CI / CI/CD) are
separate words and are not listed. Koe now handles this at run time, but new pack
words should still be checked. Organisation and private dictionaries are not in this
repository, so pass them as extra arguments to check them locally:

    python3 eval/pack_prefix_check.py                    # the shipped packs
    python3 eval/pack_prefix_check.py ~/path/to/org.txt  # plus extra files
    python3 eval/pack_prefix_check.py --all              # also pairs inside one file

By default only pairs from different files are listed: inside one pack the author
already sees both words (Java / JavaScript).

Exits 1 when a collision is found. Only terms are printed (no aliases).
"""
import sys
import unicodedata
from pathlib import Path

PACKS = Path(__file__).resolve().parent.parent / "packs"


def continues(short, long):
    if len(long) <= len(short) or not long.startswith(short):
        return False
    c = long[len(short)]
    return (c.isascii() and c.isalnum()) or "\u30a0" <= c <= "\u30ff"


def terms(path):
    out = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        term = line.split("\t", 1)[0].strip()
        if term and not term.startswith("#"):
            out.append(term)
    return out


def collisions(files, same_file=False):
    entries = [(unicodedata.normalize("NFKC", term), str(f)) for f in files for term in terms(f)]
    found = set()
    for short, short_file in entries:
        for long, long_file in entries:
            if (same_file or short_file != long_file) and len(short) >= 2 and continues(short, long):
                found.add((short, Path(short_file).name, long, Path(long_file).name))
    return sorted(found)


def main(argv):
    same_file = "--all" in argv
    files = sorted(PACKS.glob("*.txt")) + [Path(a).expanduser() for a in argv if a != "--all"]
    found = collisions(files, same_file)
    for short, sf, long, lf in found:
        print(f"{short} ({sf}) is a prefix of {long} ({lf})")
    print(f"{len(found)} prefix collision(s) in {len(files)} file(s)")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
