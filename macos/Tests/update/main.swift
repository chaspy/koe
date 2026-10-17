// make test: Sources/Koe/UpdatePrompt.swift の単体テスト
import AppKit

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) { if !ok { failures += 1; print("FAIL: \(msg())") } }

let now = Date(timeIntervalSince1970: 1_800_000_000)
let s = UpdatePrompt.self
check(s.shouldPrompt(now: now, available: "0.5.0", busy: false, lastUsed: nil, snoozedUntil: nil, noChanges: false), "idle, never used: prompt")
check(!s.shouldPrompt(now: now, available: nil, busy: false, lastUsed: nil, snoozedUntil: nil, noChanges: false), "no update")
check(!s.shouldPrompt(now: now, available: "0.5.0", busy: true, lastUsed: nil, snoozedUntil: nil, noChanges: false), "recording / transcribing")
check(!s.shouldPrompt(now: now, available: "0.5.0", busy: false, lastUsed: now.addingTimeInterval(-29), snoozedUntil: nil, noChanges: false), "used 29 s ago")
check(s.shouldPrompt(now: now, available: "0.5.0", busy: false, lastUsed: now.addingTimeInterval(-31), snoozedUntil: nil, noChanges: false), "used 31 s ago")
check(!s.shouldPrompt(now: now, available: "0.5.0", busy: false, lastUsed: nil, snoozedUntil: now.addingTimeInterval(60), noChanges: false), "snoozed")
check(s.shouldPrompt(now: now, available: "0.5.0", busy: false, lastUsed: nil, snoozedUntil: now.addingTimeInterval(-1), noChanges: false), "snooze over")
check(!s.shouldPrompt(now: now, available: "0.5.0", busy: false, lastUsed: nil, snoozedUntil: nil, noChanges: true), "no changes for this OS")

let md = """
# Changelog

## Unreleased

### macOS
- Not this one.

## 0.5.0 — 2026-10-20

### macOS
- Fixed: after every update macOS silently dropped Koe's **Accessibility** permission (`AXIsProcessTrusted`), so pasting failed without any sign and this sentence is long enough to be cut somewhere.
- Second item.

### Windows
- No changes.

## 0.4.2 — 2026-10-16

### macOS
- Older.
"""
let mac = s.summary(changelog: md, version: "0.5.0", platform: "macOS")
check(mac.line?.hasPrefix("Fixed: after every update macOS silently dropped Koe's Accessibility permission (AXIsProcess") == true && !mac.line!.contains("**") && !mac.line!.contains("`") && mac.line!.hasSuffix("…") && mac.line!.count == 100 && !mac.noChanges, "macOS summary: \(mac)")
let win = s.summary(changelog: md, version: "0.5.0", platform: "Windows")
check(win.line == nil && win.noChanges, "Windows: no changes \(win)")
check(s.summary(changelog: md, version: "0.4.2", platform: "macOS").line == "Older.", "older section")
let none = s.summary(changelog: md, version: "0.9.9", platform: "macOS")
check(none.line == nil && !none.noChanges, "missing section")

// 確認の画面: Enter / Esc で「今すぐ更新」が押されない（既定は「あとで」）
final class Recorder: NSObject {
    var pressed: [String] = []
    @objc func now() { pressed.append("now") }
    @objc func later() { pressed.append("later") }
}
_ = NSApplication.shared
let rec = Recorder()
let alert = UpdatePrompt.makeAlert(version: "0.5.0", line: "Fixed something.", target: rec, now: #selector(Recorder.now), later: #selector(Recorder.later))
alert.layout()
let buttons = alert.buttons
check(buttons.first?.title == "あとで" && buttons.first?.keyEquivalent == "\r", "default (Return) button is あとで: \(buttons.map { ($0.title, $0.keyEquivalent) })")
let nowButton = buttons.first { $0.title == "今すぐ更新" }
check(nowButton != nil && nowButton!.keyEquivalent.isEmpty, "今すぐ更新 has no key equivalent")
check(!buttons.contains { $0.keyEquivalent == "\u{1b}" }, "no button answers Esc")
check(alert.informativeText.hasPrefix("Fixed something."), "summary line shown first")
func key(_ chars: String, _ code: UInt16) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: alert.window.windowNumber,
                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
}
for (name, ev) in [("Return", key("\r", 36)), ("Enter (keypad)", key("\u{3}", 76)), ("Esc", key("\u{1b}", 53))] {
    rec.pressed = []
    for b in buttons { _ = b.performKeyEquivalent(with: ev) }
    check(!rec.pressed.contains("now"), "\(name) must not start the update: \(rec.pressed)")
}
rec.pressed = []
for b in buttons { _ = b.performKeyEquivalent(with: key("\r", 36)) }
check(rec.pressed == ["later"], "Return answers あとで: \(rec.pressed)")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("ok")
