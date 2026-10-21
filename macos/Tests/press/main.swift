// test-sources: PressGesture.swift
// make test: Sources/Koe/PressGesture.swift の単体テスト（XCTest なしで動く）
import AppKit

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

// 設定の読み方: 未設定・不明な値は今までどおり hold（新しい押し方は既定オフ）
check(PressGesture.mode(nil) == .hold, "nil")
check(PressGesture.mode("x") == .hold, "x")
check(PressGesture.mode("hold") == .hold && PressGesture.mode("toggle") == .toggle && PressGesture.mode("auto") == .auto, "既知の値")

// 1 回目に離したとき
typealias R = PressGesture.Release
let far = 10.0
for (mode, held, since, want) in [
    // auto: 0.3 秒未満は手を離して話せる、以上は今までどおり貼る
    (.auto, 0.05, far, R.handsFree), (.auto, 0.29, far, .handsFree), (.auto, 0.3, far, .paste), (.auto, 2.0, 0.1, .paste),
    // auto では 1 回目の短押しは前のタップに関係なく手を離して話す（2 回押しは 2 回目で見分ける）
    (.auto, 0.1, 0.2, .handsFree),
    // hold: 今までと同じ（短すぎれば捨てる、前のタップから 0.5 秒以内ならロック）
    (.hold, 0.1, far, .tooShort), (.hold, 0.1, 0.3, .lock), (.hold, 0.1, 0.5, .tooShort), (.hold, 0.2, far, .paste), (.hold, 1.0, 0.1, .paste),
    // toggle: 0.5 秒未満は開始、以上は貼る（ロックは無い）
    (.toggle, 0.4, far, .handsFree), (.toggle, 0.1, 0.1, .handsFree), (.toggle, 0.5, far, .paste),
] as [(PressGesture.Mode, Double, Double, R)] {
    let got = PressGesture.firstRelease(mode: mode, held: held, minHold: 0.2, sinceLastTap: since)
    check(got == want, "firstRelease(\(mode), held \(held), since \(since)) = \(got), want \(want)")
}

// 手を離して録っている途中に、もう一度押して離したとき
for (mode, held, gap, want) in [
    (.auto, 0.1, 0.2, R.lock),      // 素早い 2 回押し
    (.auto, 0.1, 0.5, .paste),      // 間が空いた: 終えて貼る
    (.auto, 0.4, 0.2, .paste),      // 2 回目が長押し: 終えて貼る
    (.auto, 0.1, 30, .paste),       // 話し終えて短く押した
    (.toggle, 0.1, 0.2, .paste),    // トグルにはロックが無い
    (.hold, 0.1, 0.2, .paste),
] as [(PressGesture.Mode, Double, Double, R)] {
    let got = PressGesture.secondRelease(mode: mode, held: held, gap: gap)
    check(got == want, "secondRelease(\(mode), held \(held), gap \(gap)) = \(got), want \(want)")
}

// 自分で止めるのは auto だけ（toggle・hold は今と同じ）
check(PressGesture.autoStops(.auto) && !PressGesture.autoStops(.toggle) && !PressGesture.autoStops(.hold), "autoStops")

// 止めどき
typealias W = PressGesture.Watch
for (elapsed, since, want) in [
    (1.0, nil, W.keep), (7.9, nil, .keep), (8.0, nil, .discard), (30, nil, .discard),
    (8.0, 7.0, .keep), (59, 58, .keep), (100, 60, .silence), (100, 10, .keep),
    (299, 1, .keep), (300, 1, .tooLong), (300, nil, .tooLong),
] as [(Double, Double?, W)] {
    let got = PressGesture.watch(elapsed: elapsed, sinceVoice: since)
    check(got == want, "watch(\(elapsed), \(String(describing: since))) = \(got), want \(want)")
}

// RMS
check(PressGesture.rms([]) == 0, "rms empty")
check(abs(PressGesture.rms([300, -300, 300, -300]) - 300) < 0.001, "rms 300")
check(PressGesture.rms([Int16](repeating: 0, count: 480)) == 0, "rms silence")

// 見張り: 声が来ないまま 8 秒で discard（時計を進められないので、押した時刻を過去にずらす）
let w = HandsFreeWatch()
var got: W?
w.start(pressedAt: Date().addingTimeInterval(-9), lastVoiceAt: { nil }, active: { true }, act: { got = $0 })
RunLoop.main.run(until: Date().addingTimeInterval(1.3))
check(got == .discard, "watch timer: \(String(describing: got))")
// メニューを開いている間（イベント追跡のモード）も見張る。イベント追跡のモードを .common に入れるのは AppKit なので、アプリと同じく NSApplication を作る
_ = NSApplication.shared
got = nil
w.start(pressedAt: Date().addingTimeInterval(-9), lastVoiceAt: { nil }, active: { true }, act: { got = $0 })
let until = Date().addingTimeInterval(1.5)
while got == nil, Date() < until { _ = RunLoop.main.run(mode: RunLoop.Mode("NSEventTrackingRunLoopMode"), before: until) }
check(got == .discard, "eventTracking: \(String(describing: got))")
// 録音が終わっていれば何もしない
got = nil
w.start(pressedAt: Date().addingTimeInterval(-9), lastVoiceAt: { nil }, active: { false }, act: { got = $0 })
RunLoop.main.run(until: Date().addingTimeInterval(1.3))
check(got == nil, "inactive watch: \(String(describing: got))")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("press: ok")
