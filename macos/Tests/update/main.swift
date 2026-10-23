// test-sources: UpdatePrompt.swift AppIcon.swift
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

// 先頭以外の Re-grant も省略せず拾う。対象版・macOS 節の外には波及させない。
let marked = md.replacingOccurrences(of: "- Second item.", with: "- Second item.\n- Re-grant: Signing identity changes.")
let markedSummary = s.summary(changelog: marked, version: "0.5.0", platform: "macOS", maxLength: 20)
check(markedSummary.requiresRegrant && markedSummary.line?.count == 20, "marker separate from truncated summary")
check(!s.summary(changelog: marked, version: "0.4.2", platform: "macOS").requiresRegrant, "no marker in older version")
check(!s.summary(changelog: marked, version: "0.5.0", platform: "Windows").requiresRegrant, "macOS marker does not affect Windows")
check(!mac.requiresRegrant && !none.requiresRegrant, "unmarked and missing releases unchanged")
let markerOnly = "## 1.0.0\n### macOS\n- Re-grant: Required.\n### Windows\n- No changes."
let only = s.summary(changelog: markerOnly, version: "1.0.0", platform: "macOS")
check(only.requiresRegrant && only.line == nil && !only.noChanges, "marker-only release prompts")
let firstMarker = markerOnly.replacingOccurrences(of: "### Windows", with: "- Fixed: Other change.\n### Windows")
check(s.summary(changelog: firstMarker, version: "1.0.0", platform: "macOS").line == "Fixed: Other change.", "marker before normal summary")
let winMarker = "## 1.0.0\n### macOS\n- Fixed: Other change.\n### Windows\n- Re-grant: Required."
check(!s.summary(changelog: winMarker, version: "1.0.0", platform: "macOS").requiresRegrant, "ignore Windows marker")
let contradictory = markerOnly.replacingOccurrences(of: "- Re-grant:", with: "- No changes.\n- Re-grant:")
check(!s.summary(changelog: contradictory, version: "1.0.0", platform: "macOS").noChanges, "regrant overrides no changes")

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
let warning = UpdatePrompt.makeAlert(version: "1.0.0", line: markedSummary.line,
                                     requiresRegrant: true, target: rec, now: #selector(Recorder.now), later: #selector(Recorder.later))
check(warning.informativeText.hasPrefix(UpdatePrompt.regrantNotice + "\n\n"), "complete warning shown before summary")
check(warning.informativeText.contains("「−」") && warning.informativeText.contains("「+」"), "warning includes repair steps")
check(!alert.informativeText.contains(UpdatePrompt.regrantNotice), "unmarked alert unchanged")
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

// #157: orderFrontRegardless() だけで出すと nib の素の部品（"<Do not show this message again>"、空の 3 つ目のボタン）が見えていた。
// present() で出すと、見えるボタンは「あとで」「今すぐ更新」の 2 つだけ
let raw = UpdatePrompt.makeAlert(version: "0.8.0", line: "Fixed something.", target: rec, now: #selector(Recorder.now), later: #selector(Recorder.later))
let before = UpdatePrompt.visibleButtonTitles(raw)
check(before.contains("") || before.contains { $0.hasPrefix("<") }, "before layout the nib placeholders are visible (the bug): \(before)")
UpdatePrompt.present(raw)
let after = UpdatePrompt.visibleButtonTitles(raw)
check(Set(after) == ["あとで", "今すぐ更新"] && after.count == 2, "after present(): exactly あとで / 今すぐ更新: \(after)")
check(!after.contains { $0.hasPrefix("<") }, "no raw suppression label is visible")
check(raw.window.isVisible, "present() shows the window")
raw.window.orderOut(nil)

// アイコン: 渡したものがそのまま使われる（渡さなければ NSAlert の既定のまま）
let icon = AppIcon.make(size: 64)
check(icon.size == NSSize(width: 64, height: 64) && !icon.isTemplate, "AppIcon.make draws a 64 pt non-template image")
let withIcon = UpdatePrompt.makeAlert(version: "0.8.0", line: nil, icon: icon, target: rec, now: #selector(Recorder.now), later: #selector(Recorder.later))
check(withIcon.icon === icon, "alert uses the Koe icon")
check(!withIcon.informativeText.isEmpty && !withIcon.informativeText.hasPrefix("\n"), "no summary line: no leading blank line")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("update: ok")
