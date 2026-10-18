// test-sources: ImproveSuggest.swift ImproveStep.swift
// make test: Sources/Koe/ImproveSuggest.swift の単体テスト（XCTest なしで動く）
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
let day: TimeInterval = 86400
func ready(_ s: ImproveSuggest.State, at now: Date, undecided: Bool = true, busy: Bool = false, idle: TimeInterval = 10) -> Bool {
    ImproveSuggest.shouldSuggest(s, now: now, undecided: undecided, busy: busy, lastUsed: now.addingTimeInterval(-idle))
}

// 30 回貼るまでは出さない
var s = ImproveSuggest.State()
for _ in 0..<29 { s = ImproveSuggest.pasted(s) }
check(!ready(s, at: t0), "29 pastes: not yet")
s = ImproveSuggest.pasted(s)
check(ready(s, at: t0), "30 pastes: suggest")
check(ImproveSuggest.text(s).title.contains("30 回"), "text shows the count: \(ImproveSuggest.text(s).title)")

// 出す場面: 録音中・文字起こし中、話した直後、しばらく使っていないときは出さない
check(!ready(s, at: t0, busy: true), "busy: no")
check(!ready(s, at: t0, idle: 2), "right after speaking: no")
check(!ready(s, at: t0, idle: 3600), "long idle: no")
check(!ImproveSuggest.shouldSuggest(s, now: t0, undecided: true, busy: false, lastUsed: nil), "never used: no")
// 決まっている（本人が切り替えた・設定ファイルや MDM で決まった）ときは出さない
check(!ready(s, at: t0, undecided: false), "decided: no")
// もう出さない
var never = s; never.neverAgain = true
check(!ready(never, at: t0), "never again: no")

// 1 回目を出す → 今はしない。14 日たつまでと、そこから 30 回貼るまでは出さない
s = ImproveSuggest.didShow(s, now: t0)
check(s.shown == 1 && s.pastedSinceShown == 0 && s.pastedTotal == 30, "after first show: \(s)")
for _ in 0..<30 { s = ImproveSuggest.pasted(s) }
check(!ready(s, at: t0.addingTimeInterval(13 * day)), "snoozed for 14 days")
check(ready(s, at: t0.addingTimeInterval(14 * day)), "after 14 days: second suggestion")
var few = ImproveSuggest.didShow(ImproveSuggest.pasted(ImproveSuggest.State()), now: t0)
for _ in 0..<29 { few = ImproveSuggest.pasted(few) }
check(!ready(few, at: t0.addingTimeInterval(20 * day)), "after snooze still needs 30 new pastes")
check(ImproveSuggest.text(s).title.contains("60 回"), "second text counts all pastes: \(ImproveSuggest.text(s).title)")

// 2 回出したら、もう出さない（メニューの項目だけ）
s = ImproveSuggest.didShow(s, now: t0.addingTimeInterval(14 * day))
for _ in 0..<100 { s = ImproveSuggest.pasted(s) }
check(!ready(s, at: t0.addingTimeInterval(400 * day)), "at most 2 suggestions ever")

// 保存と読み込み、未決定の判定
let d = UserDefaults(suiteName: "koe-improvesuggest-test-\(getpid())")!
ImproveSuggest.save(s, d)
check(ImproveSuggest.load(d) == s, "round trip: \(ImproveSuggest.load(d))")
check(ImproveSuggest.load(UserDefaults(suiteName: "koe-improvesuggest-empty-\(getpid())")!) == ImproveSuggest.State(), "empty state")
check(ImproveSuggest.undecided(d), "unset improveEnabled is undecided")
d.set(false, forKey: "improveEnabled")
check(!ImproveSuggest.undecided(d), "an explicit off is decided")
d.removePersistentDomain(forName: "koe-improvesuggest-test-\(getpid())")

// 初回の案内の「使うほど賢くする」の段（#168 の 1）
check(ImproveStepText.shows(undecided: true, enabled: false), "undecided: show the step")
check(!ImproveStepText.shows(undecided: false, enabled: false), "decided off (user / config file / MDM): skip")
check(!ImproveStepText.shows(undecided: true, enabled: true), "already on: skip")
let has: (String) -> Bool = { $0 == "claude" }
let none: (String) -> Bool = { _ in false }
check(ImproveReadiness.evaluate(provider: "command", command: "claude -p --model sonnet", endpoint: "", target: "T", found: has) == .ready(target: "T"), "claude found")
check(ImproveReadiness.evaluate(provider: "command", command: "claude -p", endpoint: "", target: "T", found: none) == .missingCommand("claude"), "claude missing")
check(ImproveReadiness.evaluate(provider: "command", command: "FOO=1 claude -p", endpoint: "", target: "T", found: has).canEnable, "env prefix is skipped")
check(ImproveReadiness.evaluate(provider: "command", command: "  ", endpoint: "", target: "T", found: has) == .missingCommand(""), "empty command")
check(ImproveReadiness.program(of: "'/Applications/My Tools/claude' -p") == "/Applications/My Tools/claude", "single-quoted path with a space")
check(ImproveReadiness.program(of: "\"/opt/a b/llm\" --x") == "/opt/a b/llm", "double-quoted path with a space")
check(ImproveReadiness.program(of: "A=1  B=2 claude -p") == "claude", "several env prefixes")
check(ImproveReadiness.evaluate(provider: "api", command: "claude -p", endpoint: "", target: "T", found: has) == .missingEndpoint, "api without endpoint")
check(ImproveReadiness.evaluate(provider: "api", command: "", endpoint: "https://x", target: "T", found: none) == .ready(target: "T"), "api with endpoint")
check(!ImproveReadiness.missingCommand("claude").canEnable && ImproveReadiness.missingCommand("claude").message.contains("「claude」"), "missing: only later, says what is missing")
check(ImproveStepText.sent.contains("音声は Mac から出ません") && ImproveStepText.sent.contains("claude -p"), "says what is sent and where")

// メニューの表記
check(ImproveSuggest.menuOff == "改善ループ: オフ（有効にすると使うほど賢くなります）", "menu off text")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("improvesuggest: ok")
