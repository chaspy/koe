// test-sources: PasteTest.swift
// make test: Sources/Koe/PasteTest.swift の単体テスト（--paste-test の目印と、貼るかどうかの判定）
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

let te = PasteTest.textEdit
// 目印: 英数字とハイフンで 1〜32 字だけ
for m in ["a", "swap-check-01", String(repeating: "x", count: 32)] { check(PasteTest.validMarker(m), "valid: \(m)") }
for m in ["", String(repeating: "x", count: 33), "a b", "a;rm", "日本語", "a\n", "$(id)"] { check(!PasteTest.validMarker(m), "invalid: \(m)") }
// 判定の順: 目印 → 前面のアプリ → 許可
check(PasteTest.refusal(marker: "ok-1", frontmost: te, trusted: true) == nil, "paste")
check(PasteTest.refusal(marker: "bad marker", frontmost: te, trusted: true) == "bad_marker", "bad marker first")
check(PasteTest.refusal(marker: "ok-1", frontmost: "com.googlecode.iterm2", trusted: true) == "not_textedit", "not TextEdit")
check(PasteTest.refusal(marker: "ok-1", frontmost: nil, trusted: true) == "not_textedit", "no front app")
check(PasteTest.refusal(marker: "ok-1", frontmost: te, trusted: false) == "no_accessibility", "no permission")
check(PasteTest.refusal(marker: "x y", frontmost: "other", trusted: false) == "bad_marker", "marker is checked before anything else")
// 貼る文は固定で、目印だけが入る
check(PasteTest.text("swap-1") == "Koe paste test swap-1", "fixed text")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("pastetest: ok")
