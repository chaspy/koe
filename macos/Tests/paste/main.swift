// test-sources: PasteTarget.swift
// make test: Sources/Koe/PasteTarget.swift の単体テスト
import Foundation

var failures = 0
for (start, now, want) in [
    ("com.googlecode.iterm2", "com.googlecode.iterm2", false),  // 同じアプリ（別のタブ・ウィンドウでも）
    ("com.googlecode.iterm2", "COM.googlecode.iTerm2", false),
    ("com.googlecode.iterm2", "com.google.Chrome", true),
    ("com.tinyspeck.slackmacgap", "com.microsoft.teams2", true),
    ("", "com.google.Chrome", false),                          // 分からないときは止めない
    ("com.google.Chrome", "", false),
] as [(String, String, Bool)] {
    if PasteTarget.changed(start: start, now: now) != want { failures += 1; print("FAIL: \(start) -> \(now) want \(want)") }
}
if PasteTarget.changed(start: nil, now: "x") || PasteTarget.changed(start: "x", now: nil) { failures += 1; print("FAIL: nil") }
// 貼る瞬間の判断（BUG-FOCUS）
typealias D = PasteTarget.Decision
for (start, now, age, on, want) in [
    ("com.googlecode.iterm2", "com.googlecode.iterm2", 3.0, true, D.paste),     // 変わっていない
    ("com.googlecode.iterm2", "com.google.Chrome", 3.0, true, D.restore),       // 別のアプリが前に出た → 戻して貼る
    ("com.googlecode.iterm2", "com.apple.systempreferences", 20.0, true, D.restore),
    ("com.googlecode.iterm2", "com.google.Chrome", 20.5, true, D.block),        // 20 秒を超えたら戻さない
    ("com.googlecode.iterm2", "com.google.Chrome", 3.0, false, D.block),        // restoreFocus オフは今までどおり
    ("", "com.google.Chrome", 3.0, true, D.paste),                              // 分からないときは止めない
] as [(String, String, Double, Bool, D)] {
    let got = PasteTarget.decide(start: start, now: now, sincePress: age, restoreEnabled: on)
    if got != want { failures += 1; print("FAIL: decide \(start) -> \(now) age=\(age) on=\(on): \(got), want \(want)") }
}
if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("ok")
