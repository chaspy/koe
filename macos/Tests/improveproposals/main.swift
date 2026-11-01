// test-sources: ImproveProposals.swift TermRules.swift AliasLearning.swift AliasReplace.swift ../../Tests/TestSupport.swift
import Foundation

let f = ISO8601DateFormatter()
let now = f.date(from: "2026-11-01T12:00:00Z")!
func at(_ daysAgo: Double) -> String { f.string(from: now.addingTimeInterval(-daysAgo * 86400)) }
func e(_ run: String, _ i: Int, _ wrong: String, _ right: String, fate: ImproveProposals.Fate = .dropped,
       reason: ImproveProposals.Reason? = .commonWord, days: Double = 1) -> [String: Any] {
    ImproveProposals.entry(run: run, at: at(days), index: i, wrong: wrong, right: right, kind: "term",
                           confidence: "medium", fate: fate, reason: fate == .dropped ? reason : nil)
}

// 繰り返しの判定: 2 回のループ、または 3 発話
check(!ImproveProposals.repeated([e("r1", 0, "ワード", "Word")], wrong: "ワード", right: "Word"), "once is not repeated")
check(ImproveProposals.repeated([e("r1", 0, "ワード", "Word"), e("r2", 4, "ワード", "Word")], wrong: "ワード", right: "Word"), "two runs")
check(!ImproveProposals.repeated([e("r1", 0, "ワード", "Word"), e("r1", 1, "ワード", "Word")], wrong: "ワード", right: "Word"), "two utterances, one run")
check(ImproveProposals.repeated((0..<3).map { e("r1", $0, "ワード", "Word") }, wrong: "ワード", right: "Word"), "three utterances")
check(!ImproveProposals.repeated([e("r1", 0, "ワード", "Word"), e("r2", 0, "ワード", "Ward")], wrong: "ワード", right: "Word"), "other pair")

// jsonl: 窓より古い行・壊れた行は読まない
let text = ImproveProposals.serialize([e("r1", 0, "a", "b", days: 8), e("r2", 0, "a", "b", days: 2)])
let parsed = ImproveProposals.parse(text + "{broken\n", now: now)
check(parsed.count == 1 && parsed[0]["run"] as? String == "r2", "window: \(parsed)")

// 行き先: 書いた語は added、別名が残らなかった語は dropped、ほかは保留のまま
let settled = ImproveProposals.settle([e("r", 0, "x", "A", fate: .pending), e("r", 1, "y", "B", fate: .pending),
                                       e("r", 2, "z", "C", fate: .pending), e("r", 3, "w", "A")], written: ["A"], emptied: ["B"])
check(settled.map { $0["fate"] as? String ?? "" } == ["added", "dropped", "pending", "dropped"], "settle \(settled)")
check(settled[1]["reason"] as? String == "ordinaryAlias" && settled[3]["reason"] as? String == "commonWord", "settle reasons")
check(ImproveProposals.reason(.aliasChain) == .aliasChain && ImproveProposals.reason(.commonWord) == .commonWord, "reason mapping")

// events は数だけ
let c = ImproveProposals.counts([e("r", 0, "a", "b"), e("r", 1, "a", "b", fate: .added), e("r", 2, "c", "d", reason: .phrase)])
check(c == ["proposed": 3, "added": 1, "pending": 0, "dropped": 2, "dropped_commonWord": 1, "dropped_phrase": 1], "counts \(c)")

// 7 日分の提案を再生する（#252 の確認）: Issue・起票・Cloudflare・CDN 型の組は、繰り返せば辞書に入る
let log = [
    e("r1", 3, "異臭", "Issue", reason: .ordinaryAlias), e("r2", 1, "異臭", "Issue", reason: .ordinaryAlias, days: 2),
    e("r3", 7, "異臭", "Issue", reason: .ordinaryAlias, days: 3),
    e("r1", 5, "気表", "起票", days: 1), e("r4", 2, "気表", "起票", days: 4),
    e("r2", 0, "クラウドフレア", "Cloudflare", fate: .pending, days: 2), e("r5", 9, "クラウドフレア", "Cloudflare", fate: .pending, days: 5),
    e("r3", 4, "CTN", "CDN", reason: .ordinaryAlias, days: 3), e("r6", 1, "CTN", "CDN", reason: .ordinaryAlias, days: 6),
]
let english: Set<String> = ["issue", "the", "ctn_not_a_word"]
func replay(_ wrong: String, _ right: String) -> [String]? {
    let rep = ImproveProposals.repeated(log, wrong: wrong, right: right)
    guard TermRules.rejection(right, repeated: rep) == nil else { return nil }
    let stored = AliasLearning.stored([wrong], sure: false, anchored: false, person: false, ordinaryWordNotes: false,
                                      englishWords: english, repeated: rep)
    return stored.isEmpty ? nil : stored
}
check(replay("異臭", "Issue") == ["~異臭"], "Issue: kanji form as a note \(String(describing: replay("異臭", "Issue")))")
check(replay("気表", "起票") == ["~気表"], "起票 is added \(String(describing: replay("気表", "起票")))")
check(replay("クラウドフレア", "Cloudflare") == ["クラウドフレア"], "Cloudflare form is replaced")
check(replay("CTN", "CDN") == ["CTN"], "CTN is replaced")

// 繰り返していなければ今までどおり（漢字だけの語・短い形は足さない）
check(TermRules.rejection("起票") == .commonWord, "single kanji term still rejected")
check(AliasLearning.stored(["気表"], sure: false, anchored: false, person: false, ordinaryWordNotes: false).isEmpty, "single short alias dropped")
// 一般語の一覧にある語は、繰り返しても足さない
check(TermRules.rejection("確認", repeated: true) == .commonWord, "listed common word")
check(AliasLearning.stored(["the"], sure: false, anchored: false, person: false, ordinaryWordNotes: false,
                           englishWords: english, repeated: true).isEmpty, "listed english word")

if failures > 0 { exit(1) }
print("improveproposals: ok")
