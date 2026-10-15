// make test: Sources/Koe/Repeats.swift の単体テスト（XCTest なしで動く）
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

// whisper が実際に出した形（small、audio_ctx=384、温度のフォールバックなし）
let kinyou = "来週のリリースに向けて、残っている課題を洗い出して、半島と起源を決めてから、" + String(repeating: "金曜日間、", count: 31)
let loops: [(String, String)] = [
    (String(repeating: "ドラフ、", count: 60) + "ドラフ", "ドラフ"),
    ("えっと、" + String(repeating: "ドラフ、", count: 8) + "ドラフ。", "えっと、ドラフ。"),
    (kinyou, "来週のリリースに向けて、残っている課題を洗い出して、半島と起源を決めてから、金曜日間、"),
    ("それは" + String(repeating: "ミティ", count: 12) + "です", "それはミティです"),
    (String(repeating: "ドラフ ", count: 5), "ドラフ"),
    ("了解しました。了解しました。了解しました。", "了解しました。"),
]
for (input, want) in loops {
    check(isRepetitive(input), "not detected: \(input)")
    let got = collapseRepeats(input)
    check(got == want, "collapseRepeats(\(input)) = \(got), want \(want)")
}
for ok in [
    "はい、はい、わかりました。",
    "テスト、テスト、マイクのテストです。",
    "ミーティング、ミーティング、ミーティングの予定を入れてください。",
    "はい、はい、はい、はい、了解です。",
    "了解しました。了解しました。",
    "ははは、それは面白いですね。",
    "予算は1000000000000円です。",
    "ドラフト、ドラフト版のレビュー、それからマージ",
    "",
] {
    check(!isRepetitive(ok), "false positive: \(ok)")
    check(collapseRepeats(ok) == ok, "collapseRepeats changed \(ok) to \(collapseRepeats(ok))")
}
if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("ok")
