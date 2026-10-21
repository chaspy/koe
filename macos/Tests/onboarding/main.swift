// test-sources: OnboardingFlow.swift
// make test: Sources/Koe/OnboardingFlow.swift の単体テスト（段・マイクテスト・キーの練習・残り時間・貼れたか）
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) { if !ok { failures += 1; print("FAIL: \(msg())") } }

// 段: 許可 → マイク → キー → 貼ってみる。最後の段だけ本物の録音に回す
check(OnboardingStep.allCases.map(\.short) == ["許可", "マイク", "キー", "貼ってみる", "賢くする"], "steps in order")

// 流れ: 既定はオフ。案を選んでいたころの値が残っていても、オンとして同じ流れ
let d = UserDefaults.standard
let savedFlow = d.object(forKey: OnboardingFlow.key)
d.removeObject(forKey: OnboardingFlow.key)
check(!OnboardingFlow.enabled, "default off")
d.set("short", forKey: OnboardingFlow.key)
check(OnboardingFlow.enabled, "an old choice (short) still turns it on")
d.set(false, forKey: OnboardingFlow.key)
check(!OnboardingFlow.enabled, "-bool false is off")
if let savedFlow { d.set(savedFlow, forKey: OnboardingFlow.key) } else { d.removeObject(forKey: OnboardingFlow.key) }
for v: Any in ["on", "steps", "auto", "short", "B", "true", "1", true, 1] {
    check(OnboardingFlow.isOn(v), "\(v) → on")
}
for v: Any? in [nil, "off", "OFF", " off ", "", "false", "no", "0", false, 0] {
    check(!OnboardingFlow.isOn(v), "\(String(describing: v)) → off")
}
let four: [OnboardingStep] = [.permissions, .mic, .key, .paste]
check(OnboardingFlow.steps == four, "all four steps")
// 使うほど賢くする（#168）: 決まっていないときだけ最後に足す。足さないときは前と同じ並び
check(OnboardingFlow.steps(improve: false) == four && OnboardingFlow.steps(improve: true) == four + [.improve], "improve is appended last")
check(OnboardingFlow.next(after: .paste, improve: true) == .improve && OnboardingFlow.next(after: .paste) == nil, "paste → improve only when shown")
check(OnboardingFlow.next(after: .improve, improve: true) == nil && OnboardingFlow.previous(before: .improve, improve: true) == .paste, "improve is the last step")
check(!OnboardingStep.improve.practisesKey, "the improve step does not take the key")
check(OnboardingFlow.next(after: .permissions) == .mic && OnboardingFlow.next(after: .key) == .paste
      && OnboardingFlow.next(after: .paste) == nil, "next")
check(OnboardingFlow.previous(before: .mic) == .permissions && OnboardingFlow.previous(before: .permissions) == nil, "previous")
check(OnboardingFlow.next(after: .improve) == nil, "a step not in the flow has no next")
check(OnboardingStep.allCases.filter(\.practisesKey) == [.permissions, .mic, .key], "only the last step records for real")
check(OnboardingText.keyName(54) == "右⌘" && OnboardingText.keyName(63) == "fn" && OnboardingText.keyName(99) == "keyCode 99", "key names")

// マイクテスト: しきい値を合わせて 0.4 秒超えたら合格。6 秒聞こえなければ直し方を出す
var m = MicTest()
for _ in 0..<30 { m.feed(level: 0.1, dt: 1.0 / 30) }
check(!m.passed && !m.showHint, "quiet for 1 s: waiting")
for _ in 0..<6 { m.feed(level: 0.6, dt: 1.0 / 30) }
check(!m.passed, "0.2 s of voice is not enough")
for _ in 0..<6 { m.feed(level: 0.1, dt: 1.0 / 30); m.feed(level: 0.6, dt: 1.0 / 30) }
check(m.passed, "voice adds up across pauses (0.4 s)")
var q = MicTest()
for _ in 0..<(6 * 30 + 1) { q.feed(level: 0.05, dt: 1.0 / 30) }
check(q.showHint && !q.passed, "hint after 6 s of silence")

// キーの練習
let P = PracticeResult.self
check(P.judge(held: 1.5, voiced: 0.8, otherKey: false) == .ok, "held and spoke")
check(P.judge(held: 0.3, voiced: 0.3, otherKey: false) == .tooShort, "too short")
check(P.judge(held: 2.0, voiced: 0.1, otherKey: false) == .noVoice, "no voice")
check(P.judge(held: 2.0, voiced: 1.0, otherKey: true) == .cancelled, "other key cancels like the real thing")
check(PracticeResult.tooShort.message(key: "右⌘").contains("右⌘ を押したまま"), "message names the key")
check(PracticeResult.noVoice.message(key: "右⌘").contains("マイク"), "no voice → check the mic")

// ダウンロードの残り時間（直近 10 秒の進み方）
var e = DownloadETA()
e.add(progress: 0.10, at: 0)
check(e.remaining() == nil, "one sample: unknown")
e.add(progress: 0.11, at: 1)
check(e.remaining() == nil, "under 2 s: unknown")
e.add(progress: 0.12, at: 2)
check(abs((e.remaining() ?? 0) - 88) < 0.5, "1%/s at 12% → 88 s (\(String(describing: e.remaining())))")
e.add(progress: 0.50, at: 30)
check(e.samples.count == 1, "old samples dropped")
check(DownloadETA.text(nil) == "" && DownloadETA.text(30) == "まもなく終わります" && DownloadETA.text(80) == "あと 1 分ほど" && DownloadETA.text(176) == "あと約 3 分", "eta text")
let line = DownloadETA.line(progress: 0.45, ready: false, eta: 176)
check(line.contains("45%") && line.contains("あと約 3 分") && line.contains("練習できます"), "download line: \(line)")
check(DownloadETA.line(progress: nil, ready: true, eta: nil) == "音声認識の準備ができました", "ready")
check(DownloadETA.line(progress: nil, ready: false, eta: nil).contains("読み込み中"), "loading")

// 貼れたか: 別のアプリに貼れたら合格。Koe の画面に向かって話したら、やり直しを促す
let koe = "io.github.chaspy.koe"
check(PasteCheck.judge(pasted: true, pasteApp: "com.apple.TextEdit", koe: koe) == .success, "pasted into TextEdit")
check(PasteCheck.judge(pasted: true, pasteApp: koe, koe: koe) == .intoKoe, "pasted into Koe's own window")
check(PasteCheck.judge(pasted: false, pasteApp: "com.apple.TextEdit", koe: koe) == .notPasted, "failed")

// 練習用の書類: 開くたびに空。閉じたときは消す（話した文を残さない）
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("koe-onboarding-test-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let practice = PracticeFile.url(in: dir)
check(practice.lastPathComponent == "Koe の練習.txt", "practice file name")
PracticeFile.remove(practice)
check(!FileManager.default.fileExists(atPath: practice.path), "remove with no file does nothing")
PracticeFile.prepare(practice)
check((try? Data(contentsOf: practice))?.isEmpty == true, "prepare creates an empty file")
try? Data("前に話した文".utf8).write(to: practice)
PracticeFile.prepare(practice)
check((try? Data(contentsOf: practice))?.isEmpty == true, "prepare empties what was pasted last time")
try? Data("練習で話した文".utf8).write(to: practice)
PracticeFile.remove(practice)
check(!FileManager.default.fileExists(atPath: practice.path), "removed when the guide closes")
try? FileManager.default.removeItem(at: dir)

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("onboarding: ok")
