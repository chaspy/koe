"""Tests for notes.py.

    python3 -m unittest discover -s scripts/release -p 'test_*.py'
"""

import unittest

import notes

HEAD = "# Changelog\n\nIntro.\n\n"
OLD = "## 0.8.0 — 2026-10-17\n\n### macOS\n- old mac\n\n### Windows\n- old win\n"


class NotesTest(unittest.TestCase):
    def test_body_has_changes_and_install(self):
        text = HEAD + "## 0.9.0 — 2026-10-20\n\n### macOS\n- a\n\n### Windows\n- b\n\n" + OLD
        out = notes.notes(text, "0.9.0", "get Koe-{version}.dmg\n")
        self.assertEqual(out, "## Changes\n\n### macOS\n- a\n\n### Windows\n- b\n\n## Install\nget Koe-0.9.0.dmg\n")

    def test_expectations_precede_changes(self):
        out = notes.notes(HEAD + OLD, "0.8.0", "install", intro="Talk to an AI.")
        self.assertTrue(out.startswith("Talk to an AI.\n\n## Changes"))

    def test_notarization_note(self):
        text = HEAD + OLD
        self.assertIn("and notarized", notes.notes(text, "0.8.0", "Koe-{version}.dmg. {gatekeeper}"))
        out = notes.notes(text, "0.8.0", "Koe-{version}.dmg. {gatekeeper}", notarized=False)
        self.assertIn("Koe-0.8.0.dmg. The app is signed with Apple's Developer ID but **not notarized**", out)

    def test_mac_only_replaces_the_windows_paragraph(self):
        install = "macOS: Koe-{version}.dmg. {gatekeeper}\n\nWindows (preview): Koe-{version}-windows-x64.zip.\n"
        out = notes.notes(HEAD + OLD, "0.8.0", install, mac_only=True)
        self.assertIn("macOS: Koe-0.8.0.dmg.", out)
        self.assertNotIn("windows-x64.zip", out)
        self.assertTrue(out.endswith("\n\n" + notes.WINDOWS_HELD + "\n"))
        with self.assertRaises(notes.ChangelogError):
            notes.notes(HEAD + OLD, "0.8.0", "macOS only\n", mac_only=True)

    def test_older_version_and_missing(self):
        out = notes.notes(HEAD + OLD, "0.8.0", "")
        self.assertIn("- old win", out)
        with self.assertRaises(notes.ChangelogError):
            notes.notes(HEAD + OLD, "0.8", "")


if __name__ == "__main__":
    unittest.main()
