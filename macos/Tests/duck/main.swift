// test-sources: MediaDuck.swift
// make test: Sources/Koe/MediaDuck.swift の判定の単体テスト（XCTest なしで動く）
import Foundation

// MediaDuck.swift が使う main.swift の部品の代わり
enum Settings {
    // Concurrent test processes must not remove each other's saved restore state.
    static let suiteName = "koe-duck-test-\(UUID().uuidString)"
    static let defaults = UserDefaults(suiteName: suiteName)!
    static var duckMedia = true
}
enum Events { static func log(_ type: String, _ extra: [String: Any] = [:]) {} }

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

// 下げるか
for (apps, want) in [
    ([], MediaDuck.Decision.skip("silent")),
    (["com.apple.systemsoundserverd"], .skip("silent")),          // 通知音などのシステムの音
    (["com.spotify.client"], .duck),
    (["com.apple.Music"], .duck),
    (["com.apple.WebKit.GPU"], .duck),                             // Safari の動画
    (["com.google.Chrome.helper"], .duck),
    ([""], .duck),                                                 // 分からないアプリ（afplay など）
    (["us.zoom.xos"], .skip("meeting")),
    (["com.spotify.client", "com.microsoft.teams2"], .skip("meeting")),  // 会議中は音楽が鳴っていても下げない
    (["com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"], .skip("meeting")),  // Chrome のアプリ（Meet など）
] as [([String], MediaDuck.Decision)] {
    let got = MediaDuck.decide(outputting: apps)
    check(got == want, "decide(\(apps)) = \(got), want \(want)")
}

// 戻すか（録音中に本人が音量を変えたら戻さない）
check(MediaDuck.restoreValue(original: 0.6, ducked: 0.15, now: 0.15) == 0.6, "restore unchanged")
check(MediaDuck.restoreValue(original: 0.6, ducked: 0.15, now: 0.16) == 0.6, "restore within tolerance")
check(MediaDuck.restoreValue(original: 0.6, ducked: 0.15, now: 0.2) == 0.6, "device rounded to the next step")
check(MediaDuck.restoreValue(original: 0.6, ducked: 0.15, now: 0.25) == nil, "user raised volume")
check(MediaDuck.restoreValue(original: 0.6, ducked: 0.15, now: 0.0) == nil, "user muted")
check(MediaDuck.restoreValue(original: 0.6, ducked: 0.15, now: 0.4, settled: false) == 0.6, "still ducking: always restore")

// 録音の始まり・終わり・終了を、偽物の機器で通して確かめる（音量の動きは Koe の時間どおりに待つ）
var vol: Float32 = 0.6
MediaDuck.hw = MediaDuck.Hardware(
    defaultOutput: { 1 }, outputtingApps: { ["com.spotify.client"] },
    volume: { _ in vol }, isSettable: { _ in true }, setVolume: { _, v in vol = v },
    uid: { _ in "fake" }, device: { _ in 1 })
func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
// 音量が動き始めるまで待つ（重い Mac でも「途中」をつかまえる。時間で待つと、まだ動いていないことがある）
func waitUntil(_ cond: () -> Bool) {
    let end = Date().addingTimeInterval(3)
    while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}
var pendingLeft: Bool { Settings.defaults.dictionary(forKey: MediaDuck.pendingKey) != nil }
func near(_ a: Float32, _ b: Float32) -> Bool { abs(a - b) < 0.001 }
Settings.defaults.removeObject(forKey: MediaDuck.pendingKey)

// ふつう: 下げきってから終わる → 元に戻り、残した音量も消える
vol = 0.6
MediaDuck.recordingStarted(); wait(0.6)
check(near(vol, 0.15), "ducked to 1/4: \(vol)")
check(pendingLeft, "original kept while ducked")
MediaDuck.recordingEnded(); wait(0.4)
check(near(vol, 0.6) && !pendingLeft, "restored: \(vol)")

// 下げている途中で終わる（押して 0.3 秒で離す）→ 下げるのを止めて元に戻す（1/4 のまま残さない）
vol = 0.6
MediaDuck.recordingStarted(); waitUntil { vol < 0.6 }
check(vol < 0.6 && vol > 0.15, "mid-duck: \(vol)")
MediaDuck.recordingEnded(); wait(0.5)
check(near(vol, 0.6) && !pendingLeft, "released while ducking → restored: \(vol)")

// 録音中に本人が音量を変えた → 戻さない
vol = 0.6
MediaDuck.recordingStarted(); wait(0.6)
vol = 0.4
MediaDuck.recordingEnded(); wait(0.4)
check(near(vol, 0.4) && !pendingLeft, "changed by the user → left alone: \(vol)")

// 戻している途中で次の録音 → 途中の音量ではなく、本当の元の音量に戻る
vol = 0.6
MediaDuck.recordingStarted(); wait(0.6)
MediaDuck.recordingEnded(); waitUntil { vol > 0.15 }
check(vol > 0.15 && vol < 0.6, "mid-restore: \(vol)")
MediaDuck.recordingStarted(); wait(0.6)
check(near(vol, 0.15), "ducked again from the real original: \(vol)")
MediaDuck.recordingEnded(); wait(0.4)
check(near(vol, 0.6), "back to the real original: \(vol)")

// 終了: 下げている途中・下げきった後・戻している途中、どれもその場で戻し、残した音量も消す
for label in ["while ducking", "ducked", "while restoring"] {
    vol = 0.6
    MediaDuck.recordingStarted()
    if label == "while ducking" { waitUntil { vol < 0.6 } } else { wait(0.6) }
    if label == "while restoring" { MediaDuck.recordingEnded(); waitUntil { vol > 0.15 } }
    MediaDuck.restoreNow()
    check(near(vol, 0.6) && !pendingLeft, "quit \(label): restored at once: \(vol)")
    wait(0.4)
    check(near(vol, 0.6), "quit \(label): nothing moves it afterwards: \(vol)")
}
Settings.defaults.removeObject(forKey: MediaDuck.pendingKey)

// 次の起動（restoreLeftover）: 残した音量に「下げきったか」があり、途中で落ちていたら必ず戻す
var settledSaved: Bool?
vol = 0.6
MediaDuck.recordingStarted(); waitUntil { vol < 0.6 }
settledSaved = Settings.defaults.dictionary(forKey: MediaDuck.pendingKey)?["settled"] as? Bool
check(settledSaved == false, "while ducking: saved as not settled")
wait(0.6)
settledSaved = Settings.defaults.dictionary(forKey: MediaDuck.pendingKey)?["settled"] as? Bool
check(settledSaved == true, "after ducking: saved as settled")
MediaDuck.restoreNow()
func leftover(now: Float32, settled: Bool?) -> Float32 {
    var p: [String: Any] = ["device": "fake", "original": 0.6, "ducked": 0.15]
    if let settled { p["settled"] = settled }
    Settings.defaults.set(p, forKey: MediaDuck.pendingKey)
    vol = now
    MediaDuck.restoreLeftover()
    check(!pendingLeft, "leftover cleared")
    return vol
}
check(near(leftover(now: 0.4, settled: false), 0.6), "crashed while ducking (volume mid-way) → restored at next launch")
check(near(leftover(now: 0.15, settled: true), 0.6), "crashed while ducked → restored at next launch")
check(near(leftover(now: 0.4, settled: true), 0.4), "changed by the user after ducking → left alone")
check(near(leftover(now: 0.15, settled: nil), 0.6), "older record without settled → as before")

Settings.defaults.removePersistentDomain(forName: Settings.suiteName)

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("duck: ok")
