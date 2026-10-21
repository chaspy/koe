// test-sources: RecordingHUD.swift
// make test: Sources/Koe/RecordingHUD.swift の単体テスト（声の大きさ・状態・文言・置き場所）
import AppKit

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) { if !ok { failures += 1; print("FAIL: \(msg())") } }

// 声の大きさ: 無音は 0、-55 dBFS 以下は 0、-15 dBFS 以上は 1
let L = AudioLevel.self
check(L.rms([]) == 0 && L.rms([0, 0, 0]) == 0, "silence rms 0")
check(abs(L.rms([1000, -1000, 1000, -1000]) - 1000) < 0.01, "rms of a square wave")
check(L.normalized(rms: 0) == 0, "0 → 0")
check(L.normalized(rms: 32768 * pow(10, -60 / 20)) == 0, "-60 dB → 0")
check(L.normalized(rms: 32768 * pow(10, -10 / 20)) == 1, "-10 dB → 1")
let mid = L.normalized(rms: 32768 * pow(10, -35 / 20))
check(abs(mid - 0.5) < 0.01, "-35 dB → 0.5 (\(mid))")
check(L.normalized(rms: 330) > 0.2, "Koe's voice threshold (330 ≈ -40 dB) moves the bars")
check(L.smooth(0, 1) > 0.5 && L.smooth(1, 0) > 0.8, "fast attack, slow release")

// 状態: 録音中が最優先。文字起こし・整形中は「文字起こし中」
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
check(HUDState.from(recordingSince: nil, locked: false, app: nil, busy: 0) == .idle, "idle")
check(HUDState.from(recordingSince: nil, locked: false, app: nil, busy: 2) == .transcribing, "transcribing")
check(HUDState.from(recordingSince: t0, locked: false, app: "Slack", busy: 1) == .recording(since: t0, locked: false, app: "Slack"), "recording wins")
check(HUDState.appName(bundleID: nil) == nil && HUDState.appName(bundleID: "") == nil, "no app")

// 文言
let H = HUDLayout.self
check(H.text(.recording(since: t0, locked: false, app: "Slack"), now: t0) == "録音中 → Slack", "recording text")
check(H.text(.recording(since: t0, locked: false, app: nil), now: t0) == "録音中", "recording without app")
check(H.text(.recording(since: t0, locked: true, app: "Slack"), now: t0.addingTimeInterval(65)) == "ロック録音中 1:05", "locked shows elapsed")
check(H.text(.transcribing, now: t0) == "文字起こし中…", "transcribing text")
check(H.text(.failed("声を検出できませんでした"), now: t0) == "声を検出できませんでした", "failure text")
check(H.elapsed(-3) == "0:00" && H.elapsed(3599) == "59:59" && H.elapsed(3600) == "60:00", "elapsed format")
check(H.showDelay >= 0.2 && H.showDelay <= 0.5, "short presses (shortcuts) do not flash the indicator")

// バー: 録音中は声で揺れ、無音でも最低の高さ。文字起こし中は流れる波。失敗・待機は出さない
let quiet = H.barHeights(.recording(since: t0, locked: false, app: nil), level: 0, t: 1)
let loud = H.barHeights(.recording(since: t0, locked: false, app: nil), level: 1, t: 1)
check(quiet.count == H.bars && quiet.allSatisfy { $0 >= 0.22 && $0 < 0.23 }, "quiet bars stay low \(quiet)")
check(loud[2] >= 0.7 && loud[2] > loud[0] && loud[2] > loud[4], "loud: the middle bar is highest \(loud)")
let w1 = H.barHeights(.transcribing, level: 0, t: 1), w2 = H.barHeights(.transcribing, level: 0, t: 1.2)
check(w1.count == H.bars && w1 != w2 && w1.allSatisfy { $0 >= 0.25 && $0 <= 0.75 }, "transcribing wave moves \(w1)")
check(H.barHeights(.failed("x"), level: 1, t: 0).isEmpty && H.barHeights(.idle, level: 1, t: 0).isEmpty, "no bars when failed / idle")

// 置き場所: 文字カーソルの下（入らなければ上）、分からなければ画面の上の真ん中
let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
let size = CGSize(width: 180, height: 32)
check(H.origin(size: size, caret: nil, visible: screen) == CGPoint(x: 630, y: 875 - 32 - 8), "top center")
check(H.origin(size: size, caret: CGRect(x: 300, y: 500, width: 1, height: 18), visible: screen) == CGPoint(x: 300, y: 500 - 8 - 32), "below the caret")
check(H.origin(size: size, caret: CGRect(x: 300, y: 20, width: 1, height: 18), visible: screen) == CGPoint(x: 300, y: 46), "above the caret near the bottom")
check(H.origin(size: size, caret: CGRect(x: 1400, y: 500, width: 1, height: 18), visible: screen).x == 1440 - 180 - 8, "kept inside on the right")
check(H.origin(size: size, caret: CGRect(x: 3000, y: 500, width: 1, height: 18), visible: screen) == CGPoint(x: 630, y: 835), "caret on another screen → top center of this one")

check(H.origin(size: size, caret: nil, visible: screen, bottom: true) == CGPoint(x: 630, y: 24), "bottom center")
check(H.origin(size: size, caret: CGRect(x: 300, y: 500, width: 1, height: 18), visible: screen, bottom: true).y == 24, "bottom ignores the caret")

// 文字カーソルの座標: AX（左上が原点）→ Cocoa（左下が原点）。おかしな高さは捨てる
check(CaretLocator.cocoa(CGRect(x: 358, y: 100, width: 0, height: 14), primaryHeight: 1440) == CGRect(x: 358, y: 1326, width: 1, height: 14), "caret flipped")
check(CaretLocator.cocoa(CGRect(x: 0, y: 0, width: 10, height: 0), primaryHeight: 1440) == nil
      && CaretLocator.cocoa(CGRect(x: 0, y: 0, width: 10, height: 500), primaryHeight: 1440) == nil, "odd caret ignored")

// 設定: 既定はオフ（新しい機能は既定オフ）。案は帯・点・波、位置は案ごとの既定
let d = UserDefaults.standard
let keys = [IndicatorStyle.key, IndicatorPosition.key]
let saved = keys.map { d.object(forKey: $0) }
keys.forEach { d.removeObject(forKey: $0) }
check(IndicatorStyle.current == .off, "default off")
check(!IndicatorStyle.menuVisible, "menu hidden while the key is unset")
d.set("bogus", forKey: IndicatorStyle.key)
check(IndicatorStyle.current == .off, "unknown value → off")
d.set("top", forKey: IndicatorStyle.key)
check(IndicatorStyle.current == .pill, "old value top → pill")
d.set("caret", forKey: IndicatorStyle.key)
check(IndicatorStyle.current == .pill, "old value caret → pill")
IndicatorStyle.current = .dot
check(IndicatorStyle.current == .dot, "dot")
check(IndicatorStyle.menuVisible, "menu shown once the key is set")
IndicatorStyle.current = .off
check(IndicatorStyle.menuVisible, "choosing off from the menu keeps the menu")
IndicatorStyle.current = .dot
check(IndicatorPosition.current(for: .pill) == .top && IndicatorPosition.current(for: .dot) == .caret
      && IndicatorPosition.current(for: .wave) == .bottom, "position follows the style when not chosen")
IndicatorPosition.set(.bottom)
check(IndicatorPosition.current(for: .pill) == .bottom && IndicatorPosition.current(for: .dot) == .bottom, "chosen position wins")
for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
check(IndicatorStyle.allCases.map(\.rawValue) == ["off", "pill", "dot", "wave"], "style choices")
check(IndicatorPosition.allCases.map(\.rawValue) == ["top", "caret", "bottom"], "position choices")

// 窓: マウスを素通しし、キーを取らない
_ = NSApplication.shared
let p = HUDPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
check(!p.canBecomeKey && !p.canBecomeMain, "never takes the focus")
let hud = RecordingHUD()
hud.update(.idle)

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("hud: ok")
