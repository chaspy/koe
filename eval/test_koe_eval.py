"""koe_eval.py の集計の単体テスト（外部ライブラリ不要）: python3 -m unittest eval/test_koe_eval.py"""

import argparse
import contextlib
import io
import json
import re
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import koe_eval  # noqa: E402


class PressRateTest(unittest.TestCase):
    """misses の貼り付け成功率と daily の①入力された が同じ定義・同じ値になること"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.orig = koe_eval.HISTORY
        koe_eval.HISTORY = root / "history"
        base = (datetime.now() - timedelta(hours=1)).replace(microsecond=0)

        def at(sec):
            return base + timedelta(seconds=sec)

        # 履歴: 貼れた 8、ロック録音 1、貼れなかった 1（no_voice などで履歴だけ残ったもの）
        recs = [{"pasted": True}] * 8 + [{"locked": True}, {}]
        for i, r in enumerate(recs):
            t = at(i * 10)
            d = koe_eval.HISTORY / t.strftime("%Y-%m-%d")
            d.mkdir(parents=True, exist_ok=True)
            rid = t.strftime("%Y-%m-%dT%H-%M-%S-000")
            (d / f"{rid}.json").write_text(json.dumps({"id": rid, **r}))

        def ev(sec, outcome, **kw):
            t = at(sec).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            return json.dumps({"t": t, "outcome": outcome, **kw})

        lines = []
        for i in range(8):
            lines += [ev(i * 10, "tracks"), ev(i * 10, "pasted"), ev(i * 10, "enter_scheduled")]
        lines += [ev(1, "mic_restarted"), ev(2, "mic_switched"), ev(3, "usage_refreshed"), ev(4, "too_short"),
                  ev(5, "cancelled", reason="key 9", hold_seconds=0.2),    # すぐ取り消した押し間違い: 数えない
                  ev(6, "cancelled", reason="mouse", hold_seconds=3.0),    # マウス操作: 数えない
                  ev(7, "cancelled", reason="key 9", hold_seconds=1.5),    # 失敗
                  ev(8, "no_voice", est_lost_chars=10),                    # 失敗
                  ev(9, "no_accessibility", chars=20),                     # 失敗（0.5.0〜）
                  ev(11, "target_changed", chars=5),                       # 失敗（0.5.0〜）
                  "not json"]
        (root / "events.jsonl").write_text("\n".join(lines) + "\n")

    def tearDown(self):
        koe_eval.HISTORY = self.orig
        self.tmp.cleanup()

    def run_cmd(self, func, **kw):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            func(argparse.Namespace(**kw))
        return out.getvalue()

    def test_counts(self):
        since = (datetime.now() - timedelta(days=1)).astimezone()
        day, fails = koe_eval._press_counts(since)
        (v,) = day.values()
        self.assertEqual((v["ok"], v["fail"]), (9, 4))
        (f,) = fails.values()
        self.assertEqual(dict(f), {"cancelled": 1, "no_voice": 1, "no_accessibility": 1, "target_changed": 1})

    def test_misses_matches_daily(self):
        misses = self.run_cmd(koe_eval.cmd_misses, days=2)
        daily = self.run_cmd(koe_eval.cmd_daily, days=2)
        self.assertIn("貼り付け成功率 69.2%（9/13", misses)
        self.assertNotIn("tracks", misses)
        row = re.search(r"^\| \d\d/\d\d \| (\d+) \| ([\d.]+%) \|", daily, re.M)
        self.assertEqual(row.groups(), ("13", "69.2%"))


class PerfStagesTest(unittest.TestCase):
    """perf の段階別（録り足し・プロンプト・文字起こし・その他）と条件別の区分"""

    def test_stages(self):
        r = {"release_to_paste_ms": 1000, "stop_ms": 300, "prompt_ms": 20, "transcribe_ms": 600}
        self.assertEqual(koe_eval._perf_stages(r), {"e2e": 1000, "stop": 300, "prompt": 20, "transcribe": 600, "other": 80})
        # プロンプトを記録する前の版: プロンプトは記録なし（None）で、その他に含まれる
        old = {"release_to_paste_ms": 1000, "stop_ms": 300, "transcribe_ms": 600}
        self.assertEqual(koe_eval._perf_stages(old)["prompt"], None)
        self.assertEqual(koe_eval._perf_stages(old)["other"], 100)
        # 録り足しが無い記録はその他を出さない
        self.assertIsNone(koe_eval._perf_stages({"release_to_paste_ms": 1000, "transcribe_ms": 600})["other"])

    def test_groups(self):
        recs = [
            {"id": "2026-10-16T09-00-00-000", "load1": 3},                         # 最初の発話: 間隔なし
            {"id": "2026-10-16T09-00-30-000", "load1": 10, "audio_seconds": 31},
            {"id": "2026-10-16T09-20-00-000", "load1": 20, "improve_running": True},  # 前から 19 分
            {"id": "2026-10-16T09-20-05-000", "load1": None, "server_restarted": True},
        ]
        g = {k: [r["id"][11:19] for r in rs] for k, rs in koe_eval._perf_groups(recs, recs)}
        self.assertEqual(len(g["全体"]), 4)
        self.assertEqual(g["Mac の負荷 < 8"], ["09-00-00", "09-20-05"])  # 負荷の記録なしは 0 扱い
        self.assertEqual(g["Mac の負荷 8〜16"], ["09-00-30"])
        self.assertEqual(g["Mac の負荷 >= 16"], ["09-20-00"])
        self.assertEqual(g["前の発話から 10 分以上"], ["09-20-00"])
        self.assertEqual(g["音声 30 秒以上"], ["09-00-30"])
        self.assertEqual(g["改善ループが裏で動いていた"], ["09-20-00"])
        self.assertEqual(g["whisper を起こし直した"], ["09-20-05"])


if __name__ == "__main__":
    unittest.main()
