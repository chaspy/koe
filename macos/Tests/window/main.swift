// test-sources: AudioWindow.swift
// make test: Sources/Koe/AudioWindow.swift の単体テスト（XCTest なしで動く）
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

// 発話の長さ → audio_ctx（windows/core の AutoAudioCtx と同じ値）
for (sec, want) in [
    (0.0, 768), (1.2, 768), (5.0, 768), (12.8, 768), (12.85, 771), (13.0, 779),
    (20.0, 1164), (25.0, 1439), (26.11, 1500), (29.9, 1500), (30.0, 0), (45.0, 0),
] as [(Double, Int)] {
    let got = AudioWindow.autoCtx(seconds: sec)
    check(got == want, "autoCtx(\(sec)) = \(got), want \(want)")
}

// 設定の読み方
let auto = AudioWindow.auto
for (v, want) in [
    (nil, auto), ("auto" as Any?, auto), ("", auto), ("x", auto), (-1, auto), (NSNumber(value: -5), auto),
    (0, 0), ("0", 0), (NSNumber(value: 512), 512), ("640", 640), (1500, 0), (2000, 0), (NSNumber(value: 800.7), 800),
] as [(Any?, Int)] {
    let got = AudioWindow.setting(v)
    check(got == want, "setting(\(String(describing: v))) = \(got), want \(want)")
}

// 設定と長さ → 送る値。Mac の auto は既定で縮めない（#165）
check(AudioWindow.shrinkBelowSeconds == 0, "auto does not shrink by default")
for sec in [0.0, 3, 7.4, 12.8, 14, 19.7, 25, 29.9, 40] {
    check(AudioWindow.ctx(setting: auto, seconds: sec) == 0, "auto \(sec)s uses the whole window")
}
// 縮める長さを決めたときは、その長さ未満だけ式どおり、以上は全体
check(AudioWindow.ctx(setting: auto, seconds: 3, shrinkBelow: 7.5) == 768, "shrinkBelow 7.5: 3s")
check(AudioWindow.ctx(setting: auto, seconds: 7.5, shrinkBelow: 7.5) == 0, "shrinkBelow 7.5: 7.5s")
check(AudioWindow.ctx(setting: auto, seconds: 14, shrinkBelow: 7.5) == 0, "shrinkBelow 7.5: 14s (the garbled range)")
check(AudioWindow.ctx(setting: 0, seconds: 3) == 0, "whole 3s")
check(AudioWindow.ctx(setting: 512, seconds: 20) == 512, "fixed 512")

// 崩れた出力の見分け（#165）。日本語・ラテン文字・数字・記号は崩れていない
for t in ["", "プルリクをマージして", "GitHub の PR を 3 件レビューする。", "café と naïve", "ｶﾀｶﾅ と ＡＢＣ", "①②、「」…—", "々〆ヶ", "𠮷野家"] {
    check(AudioWindow.garbledReason(t) == nil, "not garbled: \(t)")
}
for (t, want) in [("今日は회의があります", "foreign_script"), ("これはПриветです", "foreign_script"), ("ทดสอบ", "foreign_script"),
                  ("途中で\u{FFFD}切れた", "invalid_utf8"), ("\u{FFFD}회", "invalid_utf8")] {
    check(AudioWindow.garbledReason(t) == want, "garbled(\(t)) = \(String(describing: AudioWindow.garbledReason(t))), want \(want)")
}
check(AudioWindow.dropInvalid("あ\u{FFFD}い\u{FFFD}") == "あい", "dropInvalid removes U+FFFD")
check(AudioWindow.dropInvalid("そのまま") == "そのまま", "dropInvalid keeps clean text")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("window: ok")
