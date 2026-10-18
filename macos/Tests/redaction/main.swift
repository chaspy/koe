// test-sources: Redaction.swift
// make test: Sources/Koe/Redaction.swift の単体テスト（診断情報の設定欄・動作の記録で伏せるもの）
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

// 社員名簿の取り込み元は伏せる（文字数だけ）
let people = Redaction.redactSetting("peopleSources", ["gh:example-org/handbook/voice/people.tsv"])
check(!people.contains("example-org") && !people.contains("people.tsv") && people.hasSuffix("文字・伏せた）"), "peopleSources: \(people)")
let prompt = Redaction.redactSetting("prompt", "社外秘の案件名")
check(!prompt.contains("社外秘") && prompt == "（7 文字・伏せた）", "prompt: \(prompt)")
check(Redaction.redactSetting("improveAPIKey", "sk-xxx") == "***", "secret")
check(Redaction.redactSetting("language", "ja") == "ja", "plain")

// 名簿を取り込んだ記録は件数だけで、そのまま残してよい
check(Redaction.redactEvent(#"{"outcome":"people_synced","people":369,"t":"2026-10-16T00:00:00Z"}"#) == #"{"outcome":"people_synced","people":369,"t":"2026-10-16T00:00:00Z"}"#, "people_synced")
let improve = Redaction.redactEvent(#"{"outcome":"improve","summary":"辞書に追加: pankoさん"}"#) ?? ""
check(!improve.contains("panko"), "improve summary: \(improve)")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("redaction: ok")
