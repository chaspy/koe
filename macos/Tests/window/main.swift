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

// 設定と長さ → 送る値
check(AudioWindow.ctx(setting: auto, seconds: 3) == 768, "auto 3s")
check(AudioWindow.ctx(setting: auto, seconds: 40) == 0, "auto 40s")
check(AudioWindow.ctx(setting: 0, seconds: 3) == 0, "whole 3s")
check(AudioWindow.ctx(setting: 512, seconds: 20) == 512, "fixed 512")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("window: ok")
