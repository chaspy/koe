"""Fixture-only judgement reports; no user history or session data."""
import argparse
import contextlib
import io
import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import koe_eval


class MisheardRatesTest(unittest.TestCase):
    def records(self, now, terms=True):
        return [{"id": (now - timedelta(minutes=i + 1)).strftime("%Y-%m-%dT%H-%M-%S-000"),
                 "communication": "corrected" if i == 0 else "understood", "asr_error": i < 2,
                 "communication_note": "FIXTURE_REASON_PRIVATE",
                 "prompt_terms": ["FixtureRight"] if terms else [],
                 "mishearings": [{"wrong": "FixtureWrong", "right": "FixtureRight"}]} for i in range(3)]

    def test_repeated_classification_and_window(self):
        now = datetime(2026, 10, 23, 12)
        records = self.records(now)
        self.assertEqual(koe_eval.repeated_mishearings(records, now)[0]["kind"], "engine_limit")
        records[0]["prompt_terms"] = []
        self.assertEqual(koe_eval.repeated_mishearings(records, now)[0]["kind"], "dictionary")
        del records[0]["prompt_terms"]
        self.assertEqual(koe_eval.repeated_mishearings(records, now)[0]["kind"], "unknown")
        records[0]["mishearings"] *= 3
        self.assertEqual(koe_eval.repeated_mishearings(records + records, now)[0]["count"], 3)
        records[0]["id"] = (now - timedelta(days=7, seconds=1)).strftime("%Y-%m-%dT%H-%M-%S-000")
        self.assertEqual(koe_eval.repeated_mishearings(records, now), [])
        records[0]["id"] = (now - timedelta(days=7)).strftime("%Y-%m-%dT%H-%M-%S-000")
        self.assertEqual(len(koe_eval.repeated_mishearings(records, now)), 1)
        records[0]["id"] = (now + timedelta(seconds=1)).strftime("%Y-%m-%dT%H-%M-%S-000")
        self.assertEqual(koe_eval.repeated_mishearings(records, now), [])

    def report(self, legacy=False):
        now = datetime(2026, 10, 23, 12)
        class FixtureDateTime(datetime):
            @classmethod
            def now(cls, tz=None):
                return now if tz is None else now.astimezone(tz)
        records = self.records(now)
        if legacy:
            del records[0]["asr_error"]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "events.jsonl").write_text(json.dumps({
                "t": now.astimezone().isoformat(), "outcome": "improve_judged", "terms_added": 2}) + "\n")
            with patch.object(koe_eval, "datetime", FixtureDateTime), \
                 patch.object(koe_eval, "HISTORY", root / "history"), \
                 patch.object(koe_eval, "load_records", return_value=records), \
                 patch.object(koe_eval, "_press_counts", return_value=({}, {})):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    koe_eval.cmd_daily(argparse.Namespace(days=1))
                local = next((root / "reports").glob("*.md")).read_text()
                return out.getvalue(), local

    def test_rates_and_local_only_pairs(self):
        stdout, local = self.report()
        self.assertIn("聞き間違い", stdout)
        self.assertIn("伝わらなかった", stdout)
        self.assertIn("2/3 (66.7%) | 1/3 (33.3%)", stdout)
        for value in ["FixtureWrong", "FixtureRight", "FIXTURE_REASON_PRIVATE"]:
            self.assertNotIn(value, stdout)
        self.assertIn("FixtureWrong", local)
        self.assertIn("FixtureRight", local)
        self.assertIn("エンジン限界", local)

    def test_old_records_are_not_assumed_correct(self):
        stdout, _ = self.report(legacy=True)
        self.assertIn("| - | 1/3 (33.3%)", stdout)
        self.assertNotIn("2/3 (66.7%)", stdout)

    def test_cells_cannot_inject_markdown_or_html(self):
        value = koe_eval._local_report_cell("<x>|[x](url)\n`x`")
        self.assertNotIn("<", value)
        self.assertNotIn("|", value)
        self.assertNotIn("[", value)
        self.assertNotIn("\n", value)


if __name__ == "__main__":
    unittest.main()
