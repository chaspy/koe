#!/usr/bin/env python3
"""python3 -m unittest discover -s scripts -p 'test_*.py'"""
import pathlib
import subprocess
import sys
import tempfile
import unittest

TOOL = pathlib.Path(__file__).resolve().parent / "changelog.py"
HEAD = "# Changelog\n\nIntro.\n\n"
OLD = "## 0.7.0 — 2026-10-17\n\n### macOS\n- Old item.\n"


def run(root, *args):
    return subprocess.run([sys.executable, str(TOOL), *args, "--root", str(root)], capture_output=True, text=True)


class Changelog(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        (self.root / "changelog.d").mkdir()
        (self.root / "changelog.d" / "README.txt").write_text("not a fragment")
        (self.root / "CHANGELOG.md").write_text(HEAD + OLD)

    def tearDown(self):
        self.tmp.cleanup()

    def frag(self, name, text):
        (self.root / "changelog.d" / name).write_text(text)

    def test_release_folds_fragments_in_pr_order_and_section_order(self):
        self.frag("131-b.md", "### Windows\n- W from 131.\n\n### macOS\n- M from 131.\n")
        self.frag("27-a.md", "### macOS\n- M from 27.\n  continued line.\n")
        self.frag("docs-c.md", "### Repository\n- R from docs.\n")
        r = run(self.root, "release", "0.8.0", "--date", "2026-10-18")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.root / "CHANGELOG.md").read_text(), HEAD +
                         "## 0.8.0 — 2026-10-18\n\n"
                         "### Repository\n- R from docs.\n\n"
                         "### macOS\n- M from 27.\n  continued line.\n- M from 131.\n\n"
                         "### Windows\n- W from 131.\n\n" + OLD)
        self.assertEqual(sorted(p.name for p in (self.root / "changelog.d").iterdir()), ["README.txt"])

    def test_app_without_fragments_says_no_changes(self):
        self.frag("5-a.md", "### macOS\n- Mac only.\n")
        r = run(self.root, "release", "0.8.0", "--date", "2026-10-18")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("### macOS\n- Mac only.\n\n### Windows\n- No changes.\n\n", (self.root / "CHANGELOG.md").read_text())
        self.assertNotIn("### Repository", (self.root / "CHANGELOG.md").read_text())
        self.assertIn("macOS: Mac only.", r.stdout)
        self.assertIn("Windows: (No changes.", r.stdout)

    def test_unreleased_section_is_folded_too(self):
        (self.root / "CHANGELOG.md").write_text(HEAD + "## Unreleased\n\n### macOS\n- From unreleased.\n\n" + OLD)
        self.frag("1-a.md", "### macOS\n- From fragment.\n")
        self.assertEqual(run(self.root, "release", "0.8.0", "--date", "2026-10-18").returncode, 0)
        text = (self.root / "CHANGELOG.md").read_text()
        self.assertNotIn("Unreleased", text)
        self.assertIn("### macOS\n- From unreleased.\n- From fragment.\n", text)

    def test_hold_windows_keeps_its_entries_for_the_next_release(self):
        self.frag("10-a.md", "### Windows\n- W only.\n")
        self.frag("11-b.md", "### Repository\n- R.\n\n### macOS\n- M.\n\n### Windows\n- W too.\n  more.\n")
        self.frag("12-c.md", "### macOS\n- M2.\n")
        r = run(self.root, "release", "0.8.1", "--date", "2026-10-19", "--hold", "Windows")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.root / "CHANGELOG.md").read_text(), HEAD +
                         "## 0.8.1 — 2026-10-19\n\n"
                         "### Repository\n- R.\n\n"
                         "### macOS\n- M.\n- M2.\n\n"
                         "### Windows\n- No changes.\n\n" + OLD)
        self.assertIn("Windows: (No changes.", r.stdout)
        d = self.root / "changelog.d"
        self.assertEqual(sorted(p.name for p in d.iterdir()), ["10-a.md", "11-b.md", "README.txt"])
        self.assertEqual((d / "10-a.md").read_text(), "### Windows\n- W only.\n")
        self.assertEqual((d / "11-b.md").read_text(), "### Windows\n- W too.\n  more.\n")
        # the next release takes them
        r = run(self.root, "release", "0.9.0", "--date", "2026-10-20")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("## 0.9.0 — 2026-10-20\n\n### macOS\n- No changes.\n\n### Windows\n- W only.\n- W too.\n  more.\n\n## 0.8.1",
                      (self.root / "CHANGELOG.md").read_text())

    def test_hold_refuses_held_entries_in_unreleased(self):
        (self.root / "CHANGELOG.md").write_text(HEAD + "## Unreleased\n\n### Windows\n- W.\n\n" + OLD)
        self.frag("1-a.md", "### macOS\n- M.\n")
        r = run(self.root, "release", "0.8.1", "--hold", "Windows")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("held", r.stderr)
        self.assertTrue((self.root / "changelog.d" / "1-a.md").exists())

    def test_hold_with_only_held_entries_is_nothing_to_release(self):
        self.frag("1-a.md", "### Windows\n- W.\n")
        r = run(self.root, "release", "0.8.1", "--hold", "Windows")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("nothing to release", r.stderr)

    def test_bad_fragments_fail_check(self):
        for body in ["### Mac\n- x\n", "- no heading\n", "## 0.8.0\n", "### macOS\n", "### macOS\nnot an item\n"]:
            self.frag("1-bad.md", body)
            r = run(self.root, "check")
            self.assertNotEqual(r.returncode, 0, body)
            self.assertIn("1-bad.md", r.stderr)

    def test_release_refuses_existing_version_and_empty(self):
        self.assertNotEqual(run(self.root, "release", "0.8.0").returncode, 0)  # nothing to release
        self.frag("1-a.md", "### macOS\n- x\n")
        self.assertNotEqual(run(self.root, "release", "0.7.0").returncode, 0)
        self.assertTrue((self.root / "changelog.d" / "1-a.md").exists())


if __name__ == "__main__":
    unittest.main()
