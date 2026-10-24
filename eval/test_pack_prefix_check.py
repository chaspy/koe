"""Fixture-only checks for pack_prefix_check.py (#196)."""
import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pack_prefix_check as ppc


class PackPrefixCheckTest(unittest.TestCase):
    def write(self, d, name, text):
        p = Path(d) / name
        p.write_text(text, encoding="utf-8")
        return p

    def test_finds_planted_collision_across_files(self):
        with tempfile.TemporaryDirectory() as d:
            a = self.write(d, "a.txt", "# comment\nHTML\tエイチティーエムエル\nCI/CD\n")
            b = self.write(d, "b.txt", "HTM\nCI\nPR\n")
            c = self.write(d, "c.txt", "Prometheus\n")
            self.assertEqual(ppc.collisions([a, b, c]), [("HTM", "b.txt", "HTML", "a.txt")])

    def test_same_file_only_with_all(self):
        with tempfile.TemporaryDirectory() as d:
            a = self.write(d, "a.txt", "Java\nJavaScript\nプルリク\nプルリクエスト\n")
            self.assertEqual(ppc.collisions([a]), [])
            self.assertEqual(ppc.collisions([a], same_file=True),
                             [("Java", "a.txt", "JavaScript", "a.txt"), ("プルリク", "a.txt", "プルリクエスト", "a.txt")])

    def test_main_exit_code_and_shipped_packs(self):
        with tempfile.TemporaryDirectory() as d:
            extra = self.write(d, "org.txt", "HTM\n")
            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(ppc.main([str(extra)]), 1)
            self.assertIn("HTM (org.txt) is a prefix of HTML (developer.txt)", out.getvalue())
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ppc.main([]), 0)


if __name__ == "__main__":
    unittest.main()
