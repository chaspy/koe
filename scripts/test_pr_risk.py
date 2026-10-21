#!/usr/bin/env python3
"""Tests for scripts/pr_risk.py against this repository's .github/risk-rules.txt.

    python3 -m unittest discover -s scripts -p 'test_*.py'
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from pr_risk import classify, load_rules  # noqa: E402

RULES = os.path.join(HERE, "..", ".github", "risk-rules.txt")


def patch(path, *lines):
    return f"diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n@@ -1 +1 @@\n" + "\n".join(lines) + "\n"


class Risk(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(RULES, encoding="utf-8") as f:
            cls.rules = load_rules(f.read())

    def level(self, files, diff=""):
        return classify(self.rules, files, diff)[0]

    def test_docs_and_packs_are_low(self):
        self.assertEqual(self.level(["docs/usage-ja.md", "README.md"]), "low")
        self.assertEqual(self.level(["packs/developer.txt"], patch("packs/developer.txt", "+マージ\t~マジ")), "low")
        self.assertEqual(self.level(["macos/Tests/text/main.swift"], patch("macos/Tests/text/main.swift", "+check(\"a\")")), "low")
        self.assertEqual(self.level(["eval/test_koe_eval.py"], patch("eval/test_koe_eval.py", "+    self.assertTrue(x)")), "low")

    def test_doc_mentioning_risky_words_stays_low(self):
        self.assertEqual(self.level(["docs/notes/x.md"], patch("docs/notes/x.md", "+Redaction and AXIsProcessTrusted")), "low")

    def test_high_wins_over_low_path(self):
        self.assertEqual(self.level([".github/pull_request_template.md"]), "high")
        self.assertEqual(self.level(["REVIEW.md"]), "high")
        self.assertEqual(self.level(["macos/Tests/redaction/main.swift"]), "high")
        self.assertEqual(self.level(["windows/core/retention_test.go"]), "high")

    def test_feature_code_is_mid(self):
        self.assertEqual(self.level(["macos/Sources/Koe/main.swift"], patch("macos/Sources/Koe/main.swift", "+let x = 1")), "mid")
        self.assertEqual(self.level(["docs/a.md", "windows/tray_windows.go"]), "mid")

    def test_makefile_test_target_is_mid_but_install_lines_are_high(self):
        mk = "macos/Makefile"
        self.assertEqual(self.level([mk], patch(mk, "+\tswiftc -O -o build/x-test Sources/Koe/X.swift Tests/x/main.swift")), "mid")
        self.assertEqual(self.level([mk], patch(mk, "+\tcp Info.plist $(BUNDLE)/Contents/Info.plist")), "high")
        self.assertEqual(self.level([mk], patch(mk, "-APP_NAME   := Koe")), "high")

    def test_risky_lines_in_feature_code_are_high(self):
        f = "macos/Sources/Koe/main.swift"
        self.assertEqual(self.level([f], patch(f, "+        try? FileManager.default.removeItem(at: History.dir)")), "high")
        self.assertEqual(self.level([f], patch(f, "+        AVCaptureDevice.requestAccess(for: .audio) { _ in }")), "high")
        self.assertEqual(self.level(["macos/Info.plist"], patch("macos/Info.plist", "+\t<key>NSAppleEventsUsageDescription</key>")), "high")

    def test_version_bump_and_permission_reads_are_mid(self):
        self.assertEqual(self.level(["macos/Info.plist"], patch("macos/Info.plist", "-\t<string>0.6.0</string>", "+\t<string>0.7.0</string>")), "mid")
        f = "macos/Sources/Koe/main.swift"
        self.assertEqual(self.level([f], patch(f, "+        guard AXIsProcessTrusted() else { return }")), "mid")

    def test_reading_history_is_mid_writing_it_is_high(self):
        f = "macos/Sources/Koe/Retranscriber.swift"
        self.assertEqual(self.level([f], patch(f, "+        let url = History.dir.appendingPathComponent(item.day)", "+    // reads events.jsonl")), "mid")
        self.assertEqual(self.level([f], patch(f, "+            try? data.write(to: History.dir.appendingPathComponent(x))")), "high")

    def test_eval_reading_events_is_low(self):
        self.assertEqual(self.level(["eval/koe_eval.py"], patch("eval/koe_eval.py", "+EVENTS = HOME / 'events.jsonl'")), "low")

    def test_new_events_and_flag_comments_are_mid(self):
        f = "macos/Sources/Koe/main.swift"
        self.assertEqual(self.level([f], patch(f, "+        Events.log(\"hud_shown\", [\"ms\": ms])")), "mid")
        self.assertEqual(self.level(["windows/main_windows.go"], patch("windows/main_windows.go", "+\trec[\"outcome\"] = \"x\"")), "mid")
        self.assertEqual(self.level([f], patch(f, "+// defaults write io.github.chaspy.koe recordingHUD -bool true")), "mid")
        self.assertEqual(self.level([f], patch(f, "+    // see https://example.com/docs")), "mid")

    def test_low_eval_script_sending_text_is_high(self):
        f = "eval/koe_eval.py"
        self.assertEqual(self.level([f], patch(f, "+    urllib.request.urlopen(url, data=text)")), "high")
        self.assertEqual(self.level([f], patch(f, '+    ap.add_argument("--llm-endpoint", default="http://example.com/api")')), "high")
        self.assertEqual(self.level(["eval/koe_improve.py"], patch("eval/koe_improve.py", '+OLLAMA = os.environ.get("KOE_OLLAMA", "x")')), "high")

    def test_update_signature_check_is_high(self):
        # #177: the in-app update checks the signature before replacing Koe. Weakening it needs a human
        self.assertEqual(self.level(["macos/Sources/Koe/UpdateVerify.swift"]), "high")
        self.assertEqual(self.level(["macos/Tests/updateverify/main.swift"]), "high")
        f = "macos/Sources/Koe/main.swift"
        self.assertEqual(self.level([f], patch(f, "+            guard UpdateVerify.check(app) else { return }")), "high")
        self.assertEqual(self.level([f], patch(f, "-        let ok = SecStaticCodeCheckValidity(code, flags, req)")), "high")
        self.assertEqual(self.level([f], patch(f, "+                xattr -dr com.apple.quarantine \"$target\"")), "high")

    def test_workflows_and_signing_are_high(self):
        self.assertEqual(self.level([".github/workflows/macos-test.yml"]), "high")
        self.assertEqual(self.level(["macos/scripts/sign.sh"]), "high")
        self.assertEqual(self.level(["windows/core/update.go"]), "high")
        f = "macos/Sources/Koe/main.swift"
        self.assertEqual(self.level([f], patch(f, '+    let dmg = "https://github.com/\\(repo)/releases/download/v\\(v)/Koe.dmg"')), "high")


if __name__ == "__main__":
    unittest.main()
