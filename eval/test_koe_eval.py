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
        recs[0] = {"pasted": True, "visible": "visible", "visible_ms": 300}
        recs[1] = {"pasted": True, "visible": "visible_unknown", "visible_reason": "no_permission"}  # 測れなかった: 成功のまま
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


class MissFormsTest(unittest.TestCase):
    """koe_bench.miss_forms: 準正解の語と、出力に実際に出た形の組だけを返す"""

    def test_pairs(self):
        import koe_bench
        f = koe_bench.miss_forms
        self.assertEqual(f("プルリクをマージした", "プロリクをマジした"), [("プルリク", "プロリク"), ("マージ", "マジ")])
        self.assertEqual(f("Claude Code で直す", "クロードコードで直す"), [("ClaudeCode", "クロードコード")])
        self.assertEqual(f("インストールして", "インストールして"), [])
        # 漢字・かなだけの食い違いと、語の外まで広がった食い違いは拾わない
        self.assertEqual(f("今日は晴れ", "今日は春"), [])
        self.assertEqual(f("テストを書く", "それはまた別の話で長い"), [])


class DeliveredTest(unittest.TestCase):
    """貼る→届く（delivered_ms）: 貼った文とセッション記録のユーザー発話の照合"""

    T0 = datetime(2026, 10, 17, 1, 0, 0, tzinfo=timezone.utc)

    def at(self, sec):
        return self.T0 + timedelta(seconds=sec)

    def rec(self, text):
        return {"pasted": text, "paste_at": self.T0.strftime("%Y-%m-%dT%H:%M:%S.000Z")}

    def test_match_normalizes(self):
        m = koe_eval.delivered_match
        self.assertTrue(m("テストを回して。", "テストを回して"))                    # 句読点
        self.assertTrue(m("make test を回して", "make test を\n回して"))            # 改行・空白（折り返し）
        self.assertTrue(m("ＡＢＣを直して", "ABCを直して"))                         # 全角・半角（NFKC）
        self.assertTrue(m("二つ目の話", "一つ目の話\n二つ目の話\n三つ目"))           # キューでまとまった文に含まれる
        self.assertTrue(m("この関数のテストを足してください", "この関数のテストを足して下さい"))  # 手で少し直した
        self.assertFalse(m("この関数のテストを足して", "デプロイの手順を教えて"))
        self.assertFalse(m("", "何か"))
        self.assertFalse(m("。", "何か"))                                            # 正規化すると空

    def test_delivery_time_and_window(self):
        humans = [(self.at(-30), "前に送った文"), (self.at(0.4), "別の話"), (self.at(21), "それを直して"), (self.at(40), "それを直して")]
        self.assertEqual(koe_eval.delivery(self.rec("それを直して"), humans), (21000, None))  # いちばん早いもの
        self.assertEqual(koe_eval.delivery(self.rec("前に送った文"), humans)[1], "no_match")  # paste_at より前は数えない
        # 時計の丸めで少し前（1 秒以内）は 0 ms
        self.assertEqual(koe_eval.delivery(self.rec("ほぼ同時"), [(self.at(-0.3), "ほぼ同時")]), (0, None))
        # 5 分を過ぎたものは数えない
        self.assertEqual(koe_eval.delivery(self.rec("遅い"), [(self.at(301), "遅い")]), (None, "no_message"))

    def test_delivery_reasons(self):
        self.assertEqual(koe_eval.delivery(self.rec("何か"), []), (None, "no_message"))
        humans = [(self.at(5), "このファイルにはユニットテストも足しておいて")]
        self.assertEqual(koe_eval.delivery(self.rec("このファイルのテストを足しといて"), humans)[1], "edited")
        self.assertEqual(koe_eval.delivery(self.rec("デプロイの手順"), humans)[1], "no_match")

    def test_paste_time_falls_back_to_id(self):
        r = {"id": "2026-10-17T10-00-00-250"}
        self.assertEqual(koe_eval._paste_time(r), koe_eval._record_time(r))
        self.assertEqual(koe_eval._paste_time(self.rec("x")), self.T0)

    def test_human_events_include_queue(self):
        rows = [
            {"type": "queue-operation", "operation": "enqueue", "content": "一つ目\n二つ目", "timestamp": "2026-10-17T01:00:03.000Z"},
            {"type": "user", "message": {"content": "三つ目"}, "timestamp": "2026-10-17T01:00:01.500Z"},
            {"type": "user", "message": {"content": [{"type": "tool_result", "content": "二つ目"}]}, "timestamp": "2026-10-17T01:00:00.500Z"},
            {"type": "assistant", "message": {"content": "二つ目"}, "timestamp": "2026-10-17T01:00:00.600Z"},
        ]
        humans = koe_eval._human_events([(None, rows)])
        self.assertEqual([h[1] for h in humans], ["三つ目", "一つ目\n二つ目"])  # 時刻順、ツールの結果と返答は除く
        self.assertEqual(koe_eval.delivery(self.rec("二つ目"), humans), (3000, None))

    def test_not_visible_counts_as_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            orig = koe_eval.HISTORY
            koe_eval.HISTORY = Path(tmp) / "history"
            try:
                base = datetime.now().replace(microsecond=0) - timedelta(minutes=30)
                for i, r in enumerate([{"visible": "visible", "visible_ms": 400}, {"visible": "visible", "visible_ms": 1200},
                                       {"visible": "not_visible"}, {"visible": "visible_unknown", "visible_reason": "no_permission"}]):
                    rid = (base + timedelta(seconds=i)).strftime("%Y-%m-%dT%H-%M-%S-000")
                    d = koe_eval.HISTORY / rid[:10]
                    d.mkdir(parents=True, exist_ok=True)
                    (d / f"{rid}.json").write_text(json.dumps({"id": rid, "pasted": "文", "app": "com.example", **r}))
                day, fails = koe_eval._press_counts(base.astimezone() - timedelta(minutes=1), events=[])
                (v,) = day.values()
                self.assertEqual((v["ok"], v["fail"]), (3, 1))
                self.assertEqual(dict(next(iter(fails.values()))), {"not_visible": 1})
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    koe_eval.cmd_daily(argparse.Namespace(days=1))
                self.assertIn("| 0.80s / 1.20s | 1/3 |", out.getvalue())  # 出た 2 件の中央 0.8 秒、出ず 1 件 / 測れた 3 件
            finally:
                koe_eval.HISTORY = orig

    def test_daily_prints_numbers_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            orig = koe_eval.HISTORY, koe_eval.CLAUDE_PROJECTS
            koe_eval.HISTORY, koe_eval.CLAUDE_PROJECTS = root / "history", root / "projects"
            try:
                now = datetime.now().astimezone().replace(microsecond=0) - timedelta(minutes=30)
                texts = ["秘密の文その一です", "秘密の文その二です", "どこにも届かなかった文"]
                (root / "projects/p").mkdir(parents=True)
                rows = []
                for i, text in enumerate(texts):
                    t = now + timedelta(minutes=i * 10)
                    rid = t.strftime("%Y-%m-%dT%H-%M-%S-000")
                    d = koe_eval.HISTORY / rid[:10]
                    d.mkdir(parents=True, exist_ok=True)
                    utc = t.astimezone(timezone.utc)
                    (d / f"{rid}.json").write_text(json.dumps({"id": rid, "pasted": text, "app": "com.googlecode.iterm2",
                                                               "paste_at": utc.strftime("%Y-%m-%dT%H:%M:%S.000Z")}))
                    if i < 2:
                        ts = (utc + timedelta(seconds=[0.2, 31][i])).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
                        rows.append({"type": "user", "message": {"content": text}, "timestamp": ts})
                (root / "projects/p/s.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n")
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    koe_eval.cmd_daily(argparse.Namespace(days=1))
                daily = out.getvalue()
            finally:
                koe_eval.HISTORY, koe_eval.CLAUDE_PROJECTS = orig
        self.assertIn("| 15.60s / 31.00s | 1/3 |", daily)  # 0.2 秒と 31 秒の 2 件。届かず 1 件 / 対象 3 件
        self.assertIn("どのセッションにも発話が無い（送っていない・Claude Code 以外のペインに貼った） 1", daily)
        for text in texts:
            self.assertNotIn(text, daily)


if __name__ == "__main__":
    unittest.main()
