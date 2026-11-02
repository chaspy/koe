// test-sources: AutoUpdate.swift
// make test: Sources/Koe/AutoUpdate.swift の単体テスト（いつ自動で入れてよいか）
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) { if !ok { failures += 1; print("FAIL: \(msg())") } }

let now = Date(timeIntervalSince1970: 1_800_000_000)
func d(enabled: Bool = true, available: String? = "0.9.8", summaryKnown: Bool = true, regrant: Bool = false, noChanges: Bool = false,
       busy: Bool = false, lastUsed: Date? = nil, failed: String? = nil, retryAt: Date? = nil) -> AutoUpdate.Decision {
    AutoUpdate.decide(now: now, enabled: enabled, available: available, summaryKnown: summaryKnown, requiresRegrant: regrant,
                      noChanges: noChanges, busy: busy, lastUsed: lastUsed, failedVersion: failed, retryAt: retryAt)
}

check(d() == .install, "idle, never used: install")
check(d(enabled: false) == .off, "default off: nothing happens")
check(d(available: nil) == .none, "no new version")
// 録音中・文字起こし中・貼り付け中は入れない
check(d(busy: true) == .wait("busy"), "busy: wait")
check(d(busy: true, lastUsed: now.addingTimeInterval(-3600)) == .wait("busy"), "busy wins over long idle")
// 最後に使ってから 10 分
check(d(lastUsed: now.addingTimeInterval(-599)) == .wait("recent"), "used 9m59s ago: wait")
check(d(lastUsed: now.addingTimeInterval(-600)) == .install, "used 10m ago: install")
// 署名が変わる版・内容が読めない版は自動では入れず、今の案内へ
check(d(regrant: true) == .manual("regrant"), "Re-grant: manual")
check(d(regrant: true, busy: true) == .manual("regrant"), "Re-grant stays manual even when busy")
check(d(summaryKnown: false) == .manual("summary"), "unknown changelog: manual")
check(d(noChanges: true) == .skip("no_changes"), "no macOS changes: skip")
// 署名を確かめられなかった版は次の版まで試さない
check(d(failed: "0.9.8") == .skip("verify_failed"), "failed version: skip")
check(d(available: "0.9.9", failed: "0.9.8") == .install, "next version is tried")
check(d(retryAt: now.addingTimeInterval(60)) == .wait("retry"), "download failed: wait for retry")
check(d(retryAt: now.addingTimeInterval(-1)) == .install, "retry time passed")

// 入れ替える直前
let started = now.addingTimeInterval(-30)
check(AutoUpdate.canReplace(busy: false, lastUsed: now.addingTimeInterval(-3600), startedAt: started), "still idle: replace")
check(AutoUpdate.canReplace(busy: false, lastUsed: nil, startedAt: started), "never used: replace")
check(!AutoUpdate.canReplace(busy: true, lastUsed: nil, startedAt: started), "recording now: do not replace")
check(!AutoUpdate.canReplace(busy: false, lastUsed: now.addingTimeInterval(-5), startedAt: started), "pressed during download: do not replace")

// 起動し直したあとの知らせ
check(AutoUpdate.notice(installed: "0.9.8", current: "0.9.8") == "Koe を v0.9.8 に自動で更新しました", "notice after relaunch")
check(AutoUpdate.notice(installed: "0.9.8", current: "0.9.7") == nil, "replacement did not happen: no notice")
check(AutoUpdate.notice(installed: nil, current: "0.9.8") == nil, "manual update: no notice")
check(AutoUpdate.verifyFailedNotice("0.9.8").contains("入れませんでした"), "verify failure notice")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("autoupdate: ok")
