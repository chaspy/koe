// make test: Sources/Koe/PermissionGuide.swift の単体テスト（許可の判定・文言・置き場所）
import AppKit
import AVFoundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) { if !ok { failures += 1; print("FAIL: \(msg())") } }

// 足りない許可と順番: アクセシビリティが先。マイクは「まだ聞いていない」なら案内しない（システムの確認が出る）
let c = PermissionCheck.self
check(c.missing(ax: true, mic: .authorized).isEmpty, "all granted")
check(c.missing(ax: false, mic: .authorized) == [.accessibility], "ax missing")
check(c.missing(ax: true, mic: .denied) == [.microphone], "mic denied")
check(c.missing(ax: true, mic: .restricted) == [.microphone], "mic restricted (MDM)")
check(c.missing(ax: true, mic: .notDetermined).isEmpty, "mic not asked yet: the system asks")
check(c.missing(ax: false, mic: .denied) == [.accessibility, .microphone], "accessibility first")

// 閉じてから 1 分は自動で出し直さない。メニューからはいつでも
let now = Date(timeIntervalSince1970: 1_800_000_000)
check(c.shouldShow(manual: false, lastClosed: nil, now: now), "never closed")
check(!c.shouldShow(manual: false, lastClosed: now.addingTimeInterval(-59), now: now), "closed 59 s ago")
check(c.shouldShow(manual: false, lastClosed: now.addingTimeInterval(-60), now: now), "closed 60 s ago")
check(c.shouldShow(manual: true, lastClosed: now.addingTimeInterval(-1), now: now), "menu always shows")

// 文言: 外れたとき（一度は許可されていた）は「−」で消して入れ直す手順。マイクは外に送らないと書く
let t = PermissionText.self
check(t.steps(.accessibility, stale: true).first?.contains("「−」で消す") == true, "stale: remove first")
check(t.steps(.accessibility, stale: true).last?.contains("ドラッグ") == true, "stale: drag back in")
check(t.steps(.accessibility, stale: false).first?.contains("スイッチをオン") == true, "fresh: turn on")
check(!t.steps(.accessibility, stale: false).joined().contains("−"), "fresh: no remove step")
check(t.title(.accessibility, stale: true).contains("外れています") && t.title(.accessibility, stale: false).contains("必要です"), "stale title")
check(t.reason(.accessibility, stale: true).contains("オンに見えていても"), "stale reason")
check(t.reason(.microphone, stale: false).contains("外に送りません"), "mic: says audio stays local")
check(!t.steps(.microphone, stale: false).joined().contains("ドラッグ"), "mic list does not take drops")
for p in [Permission.accessibility, .microphone] {
    check(p.settingsURL.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.preference.security?Privacy_"), "settings URL \(p)")
}

// 置き場所: 窓の右 → 左 → 窓の中の右下。窓が無ければ画面の右上
let pl = PermissionPlacement.self
let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
let panel = CGSize(width: 380, height: 300)
let o0 = pl.origin(panel: panel, beside: nil, visible: screen)
check(o0 == CGPoint(x: 1440 - 380 - 16, y: 875 - 300 - 16), "no window: top-right \(o0)")
let left = CGRect(x: 100, y: 200, width: 700, height: 600)
let o1 = pl.origin(panel: panel, beside: left, visible: screen)
check(o1 == CGPoint(x: 812, y: 500), "right of window, tops aligned \(o1)")
let right = CGRect(x: 700, y: 200, width: 700, height: 600)
let o2 = pl.origin(panel: panel, beside: right, visible: screen)
check(o2 == CGPoint(x: 700 - 12 - 380, y: 500), "left of window when no room on the right \(o2)")
let wide = CGRect(x: 100, y: 100, width: 1300, height: 700)
let o3 = pl.origin(panel: panel, beside: wide, visible: screen)
check(o3 == CGPoint(x: 1400 - 380 - 16, y: 116), "inside bottom-right when no room on either side \(o3)")
let low = CGRect(x: 100, y: 0, width: 700, height: 250)
let o4 = pl.origin(panel: panel, beside: low, visible: screen)
check(o4.y >= 16 && o4.y + panel.height <= 875 - 16, "stays on screen vertically \(o4)")
// 2 枚目の画面（主画面の右）でも同じ
let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
let o5 = pl.origin(panel: panel, beside: CGRect(x: 1500, y: 300, width: 700, height: 600), visible: second)
check(o5 == CGPoint(x: 2212, y: 600), "second screen \(o5)")

// CGWindowList（左上が原点・下向き）→ Cocoa（左下が原点）
let r = pl.cocoaRect(CGRect(x: 10, y: 50, width: 700, height: 600), primaryHeight: 900)
check(r == CGRect(x: 10, y: 250, width: 700, height: 600), "flip coordinates \(r)")

// 既定はオフ（permissionGuide を入れたときだけ新しい案内）
let savedFlag = UserDefaults.standard.object(forKey: "permissionGuide")
UserDefaults.standard.removeObject(forKey: "permissionGuide")
check(!PermissionGuide.enabled, "off by default")
UserDefaults.standard.set(true, forKey: "permissionGuide")
check(PermissionGuide.enabled, "on with permissionGuide = true")
if let savedFlag { UserDefaults.standard.set(savedFlag, forKey: "permissionGuide") } else { UserDefaults.standard.removeObject(forKey: "permissionGuide") }

// 窓を組み立てても落ちない（フォーカスを奪わない作り）
_ = NSApplication.shared
let g = PermissionGuide()
check(!g.isVisible, "hidden at start")
let p = GuidePanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
check(p.styleMask.contains(.nonactivatingPanel) && p.canBecomeKey && !p.canBecomeMain, "panel does not activate Koe")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("ok")
