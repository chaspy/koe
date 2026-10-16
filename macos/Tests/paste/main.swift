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
if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("ok")
