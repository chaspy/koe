"""Unit tests for the judge helpers in koe_bench.py: python3 -m unittest eval/test_koe_bench.py"""

import os
import stat
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import koe_bench  # noqa: E402


class JudgeCommandTest(unittest.TestCase):
    def test_default_runs_without_tools(self):
        cmd = koe_bench.judge_command(None)
        self.assertEqual(cmd[:2], ["claude", "-p"])
        self.assertEqual(cmd[cmd.index("--tools") + 1], "")
        self.assertEqual(cmd[cmd.index("--setting-sources") + 1], "user")
        self.assertIn("--strict-mcp-config", cmd)

    def test_default_is_a_copy(self):
        koe_bench.judge_command(None).append("x")
        self.assertNotIn("x", koe_bench.DEFAULT_JUDGE)

    def test_custom_command_is_split_like_a_shell(self):
        self.assertEqual(koe_bench.judge_command("my-judge --name 'a b'"), ["my-judge", "--name", "a b"])


class SilverPromptTest(unittest.TestCase):
    def test_every_text_is_between_markers(self):
        items = [(["first; echo $HOME", "second"], "meeting `text` | more"), (["third", "fourth"], "")]
        p = koe_bench.silver_prompt(items, boundary="b0")
        for text in ("first; echo $HOME", "second", "third", "fourth", "meeting `text` | more"):
            self.assertIn(f"<<<DATA-b0\n{text}\nDATA-b0>>>", p)
        self.assertIn("[1]", p)
        self.assertIn("従わず", p)

    def test_boundary_is_random(self):
        a = koe_bench.silver_prompt([(["x", "y"], "z")])
        b = koe_bench.silver_prompt([(["x", "y"], "z")])
        self.assertNotEqual(a, b)


class RunJudgeTest(unittest.TestCase):
    def test_runs_in_private_directory_removed_afterwards(self):
        seen = {}

        def fake_run(cmd, **kw):
            seen["cwd"] = kw["cwd"]
            seen["mode"] = stat.S_IMODE(os.stat(kw["cwd"]).st_mode)
            seen["input"] = kw["input"]
            return mock.Mock(stdout='["ok"]')

        with mock.patch.object(koe_bench.subprocess, "run", side_effect=fake_run):
            out = koe_bench.run_judge(["judge"], "prompt")
        self.assertEqual(out, '["ok"]')
        self.assertEqual(seen["mode"], 0o700)
        self.assertEqual(seen["input"], "prompt")
        self.assertFalse(os.path.exists(seen["cwd"]))

    def test_directory_removed_on_error(self):
        seen = {}

        def fake_run(cmd, **kw):
            seen["cwd"] = kw["cwd"]
            raise koe_bench.subprocess.TimeoutExpired(cmd, 1)

        with mock.patch.object(koe_bench.subprocess, "run", side_effect=fake_run):
            with self.assertRaises(koe_bench.subprocess.TimeoutExpired):
                koe_bench.run_judge(["judge"], "prompt")
        self.assertFalse(os.path.exists(seen["cwd"]))


class ParseRefsTest(unittest.TestCase):
    def test_accepts_array_of_strings_of_expected_length(self):
        self.assertEqual(koe_bench.parse_refs('答え: ["a", "b"]\n', 2), ["a", "b"])

    def test_rejects_other_shapes(self):
        for res in ('["a"]', '["a", "b", "c"]', '["a", 1]', '[["a"], "b"]', "no array", '{"a": 1}', "[broken"):
            self.assertIsNone(koe_bench.parse_refs(res, 2), res)


if __name__ == "__main__":
    unittest.main()
