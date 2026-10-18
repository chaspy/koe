"""Tests for scrub.py on synthetic git repositories.

    python3 -m unittest discover -s scripts/release -p 'test_*.py'

The sample secrets, addresses and paths are assembled at run time so this
file itself passes the scrub.
"""

import contextlib
import io
import os
import subprocess
import tempfile
import unittest
from unittest import mock

import scrub

AT = "@"
WORD = "zorblax"  # stands in for a denylisted name


def ip(*parts):
    return ".".join(str(p) for p in parts)


class Repo:
    def __init__(self, tmp):
        self.path = os.path.join(tmp, "repo")
        os.makedirs(self.path)
        self.git("init", "-q")
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t" + AT + "users.noreply.github.com")

    def git(self, *args):
        return subprocess.run(["git", "-C", self.path, *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, rel, content):
        p = os.path.join(self.path, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb" if isinstance(content, bytes) else "w") as f:
            f.write(content)

    def remove(self, rel):
        os.remove(os.path.join(self.path, rel))

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", "c")
        return self.git("rev-parse", "HEAD")


class ScrubTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(self.tmp.name)
        self.denylist = os.path.join(self.tmp.name, "deny.txt")
        with open(self.denylist, "w") as f:
            f.write("# comment\n\n" + WORD + "(corp)?\n")
        self.allow = os.path.join(self.tmp.name, "allow.txt")
        open(self.allow, "w").close()
        patcher = mock.patch.object(scrub.shutil, "which", return_value=None)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)

    def run_scrub(self, base, target, denylist=None):
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = scrub.main([base, target, "--repo", self.repo.path,
                               "--denylist", denylist or self.denylist, "--allow", self.allow])
        return code, out.getvalue(), err.getvalue()

    def base_and_target(self, files, base_files=None):
        for rel, content in (base_files or {"README.md": "hello\n"}).items():
            self.repo.write(rel, content)
        base = self.repo.commit()
        for rel, content in files.items():
            self.repo.write(rel, content)
        return base, self.repo.commit()

    # denylist

    def test_clean_change_passes(self):
        base, target = self.base_and_target({"README.md": "hello\nworld\n"})
        code, out, _ = self.run_scrub(base, target)
        self.assertEqual(code, 0, out)
        self.assertIn("scrub: 0 hit(s)", out)

    def test_denylist_hit_is_reported_masked(self):
        base, target = self.base_and_target({"README.md": "hello\nThanks to " + WORD.upper() + "Corp\n"})
        code, out, _ = self.run_scrub(base, target)
        self.assertEqual(code, 1)
        self.assertIn("HIT  README.md:2: denylist #3", out)
        self.assertNotIn(WORD, out.lower())

    def test_removed_and_unchanged_lines_are_not_checked(self):
        base, target = self.base_and_target(
            {"README.md": "keep " + WORD + "\n", "b.txt": "x\n"},
            base_files={"README.md": "keep " + WORD + "\n", "b.txt": "old " + WORD + "\n"})
        code, out, _ = self.run_scrub(base, target)
        self.assertEqual(code, 0, out)

    def test_new_file_name_is_checked(self):
        base, target = self.base_and_target({"docs/" + WORD + "-notes.md": "plain\n"})
        code, out, _ = self.run_scrub(base, target)
        self.assertEqual(code, 1)
        self.assertIn(":name: denylist #3", out)

    def test_binary_file_is_checked(self):
        base, target = self.base_and_target({"icon.png": b"\x89PNG\x00\x01author=" + WORD.encode() + b"\x00\x02"})
        code, out, _ = self.run_scrub(base, target)
        self.assertEqual(code, 1)
        self.assertIn("icon.png:(binary): denylist #3", out)

    def test_line_numbers_follow_the_new_file(self):
        base, target = self.base_and_target(
            {"a.txt": "1\n2\n3\nnew " + WORD + "\n4\n"}, base_files={"a.txt": "1\n2\n3\n4\n"})
        _, out, _ = self.run_scrub(base, target)
        self.assertIn("a.txt:4: denylist", out)

    def test_missing_denylist_fails(self):
        base, target = self.base_and_target({"README.md": "x\n"})
        code, _, err = self.run_scrub(base, target, denylist=os.path.join(self.tmp.name, "nope.txt"))
        self.assertEqual(code, 2)
        self.assertIn("denylist not found", err)

    def test_invalid_denylist_regex_fails_without_printing_it(self):
        bad = os.path.join(self.tmp.name, "bad.txt")
        with open(bad, "w") as f:
            f.write(WORD + "(\n")
        base, target = self.base_and_target({"README.md": "x\n"})
        code, out, err = self.run_scrub(base, target, denylist=bad)
        self.assertEqual(code, 2)
        self.assertIn("denylist line 1", err)
        self.assertNotIn(WORD, out + err)

    # generic patterns

    def test_generic_patterns_are_detected(self):
        cases = {
            "email address": "mail me: alice.k" + AT + "mail-host.test",
            "chat/document service link": "see https://team." + "slack" + ".com/archives/C1/p2",
            "private IP address": "server at " + ip(192, 168, 1, 20) + ":8080",
            "internal host name": "push to build01." + "corp" + ":5000",
            "home directory path": "log in /Us" + "ers/alice/Library/Logs",
            "token or private key": "token gh" + "p_" + "a1B2" * 9,
        }
        files = {f"{i}.txt": line + "\n" for i, line in enumerate(cases.values())}
        base, target = self.base_and_target(files)
        code, out, _ = self.run_scrub(base, target)
        self.assertEqual(code, 1, out)
        for i, cat in enumerate(cases):
            with self.subTest(cat):
                self.assertIn(f"HIT  {i}.txt:1: {cat}", out)
        self.assertNotIn("alice", out)
        self.assertIn(f"scrub: {len(cases)} hit(s)", out)

    def test_more_secret_shapes(self):
        lines = [
            "-----BEGIN " + "OPENSSH PRIVATE KEY-----",
            "AK" + "IA" + "ABCDEFGHIJKLMNOP",
            "xo" + "xb-" + "1234567890-abcdef",
            'api_key = "' + "Zx9" * 8 + '"',
            "C:" + "\\\\Users\\\\alice\\\\AppData",
            "/ho" + "me/alice/.config",
            "intranet: " + ip(10, 2, 3, 4),
        ]
        for line in lines:
            with self.subTest(line[:12]):
                self.assertTrue(scrub.generic_hits(line), line)

    def test_generic_patterns_skip_known_fine_text(self):
        fine = [
            "Co-Authored-By: Claude <no" + "reply" + AT + "anthropic.com>",
            "1234+someone" + AT + "users.no" + "reply.github.com",
            "contact " + "bob" + AT + "example.com",
            "git" + AT + "github.com:owner/repo.git",
            "http://" + ip(127, 0, 0, 1) + ":8178/inference",
            "macOS " + ip(10, 15, 7) + " and 1." + ip(10, 2, 3, 4) + ".5",
            "cd ~/.local/src/whisper.cpp",
            "/Us" + "ers/you/Library/Application Support/Koe",
            "/Us" + "ers/Shared/models",
            "$HOME/Library and %USERPROFILE%\\AppData",
            "loc := time.Local; s.localizedDescription",
            "talk on Slack or Notion",
        ]
        for line in fine:
            with self.subTest(line[:20]):
                self.assertEqual(scrub.generic_hits(line), [], line)

    def test_allowlist_suppresses_generic_hits_only(self):
        line = "server " + ip(192, 168, 0, 9)
        base, target = self.base_and_target({"f.txt": line + "\n" + WORD + " " + line + "\n"})
        code, out, _ = self.run_scrub(base, target)
        self.assertEqual(code, 1)
        h1 = scrub.line_hash(line)
        h2 = scrub.line_hash(WORD + " " + line)
        self.assertIn(f"[allow: f.txt:{h1}]", out)
        with open(self.allow, "w") as f:
            f.write(f"f.txt:{h1}  # documentation example\nf.txt:{h2}\n")
        code, out, _ = self.run_scrub(base, target)
        self.assertEqual(code, 1)
        self.assertIn("allowed  f.txt:1: private IP address", out)
        self.assertIn("HIT  f.txt:2: denylist #3", out)
        self.assertIn("allowed  f.txt:2: private IP address", out)
        self.assertIn("scrub: 1 hit(s), 2 allowed", out)

    def test_allow_entry_is_tied_to_the_path(self):
        line = "server " + ip(192, 168, 0, 9)
        base, target = self.base_and_target({"g.txt": line + "\n"})
        with open(self.allow, "w") as f:
            f.write(f"f.txt:{scrub.line_hash(line)}\n")
        code, _, _ = self.run_scrub(base, target)
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
