"""Tests for changelog.py.

    python3 -m unittest discover -s scripts/release -p 'test_*.py'
"""

import unittest

import changelog

HEAD = "# Changelog\n\nIntro.\n\n"
OLD = "## 0.8.0 — 2026-10-17\n\n### macOS\n- old mac\n\n### Windows\n- old win\n"


class CutTest(unittest.TestCase):
    def test_renames_unreleased(self):
        text = HEAD + "## Unreleased\n\n### macOS\n- a\n\n### Windows\n- b\n\n" + OLD
        out = changelog.cut(text, "0.9.0", "2026-10-20")
        self.assertEqual(out, HEAD + "## 0.9.0 — 2026-10-20\n\n### macOS\n- a\n\n### Windows\n- b\n\n" + OLD)

    def test_adds_missing_platforms(self):
        text = HEAD + "## Unreleased\n\n### Windows\n- b\n\n" + OLD
        out = changelog.cut(text, "0.9.0", "2026-10-20")
        self.assertIn("## 0.9.0 — 2026-10-20\n\n### macOS\n- No changes.\n\n### Windows\n- b\n\n## 0.8.0", out)
        text = HEAD + "## Unreleased\n\n### Repository\n- r\n\n### macOS\n- a\n\n" + OLD
        out = changelog.cut(text, "0.9.0", "2026-10-20")
        self.assertIn("### Repository\n- r\n\n### macOS\n- a\n\n### Windows\n- No changes.\n\n## 0.8.0", out)

    def test_refuses_bad_input(self):
        with self.assertRaisesRegex(changelog.ChangelogError, "no \"## Unreleased\""):
            changelog.cut(HEAD + OLD, "0.9.0", "d")
        with self.assertRaisesRegex(changelog.ChangelogError, "no entries"):
            changelog.cut(HEAD + "## Unreleased\n\n" + OLD, "0.9.0", "d")
        with self.assertRaisesRegex(changelog.ChangelogError, "already has"):
            changelog.cut(HEAD + "## Unreleased\n- x\n\n" + OLD, "0.8.0", "d")
        with self.assertRaisesRegex(changelog.ChangelogError, "not a version"):
            changelog.cut(HEAD + "## Unreleased\n- x\n", "v0.9", "d")


class NotesTest(unittest.TestCase):
    def test_body_has_changes_and_install(self):
        text = HEAD + "## 0.9.0 — 2026-10-20\n\n### macOS\n- a\n\n### Windows\n- b\n\n" + OLD
        out = changelog.notes(text, "0.9.0", "get Koe-{version}.dmg\n")
        self.assertEqual(out, "## Changes\n\n### macOS\n- a\n\n### Windows\n- b\n\n## Install\nget Koe-0.9.0.dmg\n")

    def test_notarization_note(self):
        text = HEAD + OLD
        self.assertIn("and notarized", changelog.notes(text, "0.8.0", "Koe-{version}.dmg. {gatekeeper}"))
        out = changelog.notes(text, "0.8.0", "Koe-{version}.dmg. {gatekeeper}", notarized=False)
        self.assertIn("Koe-0.8.0.dmg. The app is signed with Apple's Developer ID but **not notarized**", out)

    def test_older_version_and_missing(self):
        out = changelog.notes(HEAD + OLD, "0.8.0", "")
        self.assertIn("- old win", out)
        with self.assertRaises(changelog.ChangelogError):
            changelog.notes(HEAD + OLD, "0.8", "")


if __name__ == "__main__":
    unittest.main()
