// test-sources: Stats.swift
// make test: Sources/Koe/Stats.swift の単体テスト（XCTest なしで動く）
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

let cal = Calendar.current
var comps = DateComponents(); comps.year = 2026; comps.month = 10; comps.day = 17; comps.hour = 15
let now = cal.date(from: comps)!
let idf: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"; return f }()
func id(_ ago: TimeInterval) -> String { idf.string(from: now.addingTimeInterval(-ago)) }

// 記録の読み方
let r1 = Stats.rec(["id": id(60), "pasted": "こんにちは世界", "hold_seconds": 2.5, "autocorrected": ["a→b", "c→d"], "release_to_paste_ms": 800, "visible_ms": 300])
check(r1?.chars == 7 && r1?.speakSeconds == 2.5 && r1?.fixes == 2 && r1?.releaseToPasteMs == 800 && r1?.visibleMs == 300, "記録を読む")
check(Stats.rec(["id": id(60), "pasted": NSNull(), "hold_seconds": 2]) == nil, "貼っていないものは数えない")
check(Stats.rec(["id": id(60), "pasted": "", "hold_seconds": 2]) == nil, "空は数えない")
check(Stats.rec(["id": id(60), "pasted": "メモ", "locked": true]) == nil, "ロック録音は数えない")
check(Stats.rec(["id": "broken", "pasted": "x"]) == nil, "壊れた id")
check(Stats.rec(["id": id(60), "pasted": "x", "audio_seconds": 1.5])?.speakSeconds == 1.5, "押した長さが無ければ録音の長さ")

// 集計
let recs = [
    Stats.Rec(time: now.addingTimeInterval(-60), chars: 120, speakSeconds: 20, fixes: 1, releaseToPasteMs: 700, visibleMs: nil),
    Stats.Rec(time: now.addingTimeInterval(-3600), chars: 60, speakSeconds: 10, fixes: 0, releaseToPasteMs: 900, visibleMs: 250),
    Stats.Rec(time: now.addingTimeInterval(-2 * 86400), chars: 600, speakSeconds: 60, fixes: 3, releaseToPasteMs: 1100, visibleMs: nil),
]
let today = Stats.summarize(recs, from: cal.startOfDay(for: now), now: now, learned: 2)
check(today.utterances == 2 && today.chars == 180 && today.fixes == 1 && today.learned == 2, "今日: \(today)")
// 180 文字をキーボードで打つと 3 分（180 秒）、話したのは 30 秒 → 150 秒の節約
check(today.savedSeconds == 150, "節約: \(today.savedSeconds)")
check(today.medianReleaseToPasteMs == 800 && today.medianVisibleMs == 250, "中央値")
let week = Stats.summarize(recs, from: now.addingTimeInterval(-7 * 86400), now: now)
check(week.utterances == 3 && week.chars == 780 && week.fixes == 4 && week.medianReleaseToPasteMs == 900, "7 日: \(week)")
check(Stats.Summary(chars: 10, speakSeconds: 60).savedSeconds == 0, "打つより話すほうが長ければ 0")
check(Stats.summarize([], from: now, now: now) == Stats.Summary(), "空")

// 覚えた語
let ev = """
{"outcome":"improve","summary":"10 件 辞書に追加: マージ、リベース","t":"2026-10-16T01:00:00Z"}
{"outcome":"improve","summary":"5 件 辞書に追加: マージ","t":"2026-10-17T01:00:00Z"}
{"outcome":"improve","summary":"辞書に追加: なし","t":"2026-10-17T02:00:00Z"}
{"outcome":"improve","summary":"辞書に追加: 古い語","t":"2026-09-01T00:00:00Z"}
{"outcome":"pasted","t":"2026-10-17T01:00:00Z"}
"""
check(Stats.learnedCount(events: ev, from: now.addingTimeInterval(-7 * 86400)) == 2, "覚えた語（重ねない・なし・古いのは除く）")

// 続けて使った日数
func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: cal.startOfDay(for: now))! }
check(Stats.streak([day(0): 3, day(1): 1, day(2): 5, day(4): 1], now: now) == 3, "今日から 3 日")
check(Stats.streak([day(1): 1, day(2): 5], now: now) == 2, "今日まだでも昨日まで続いていれば 2")
check(Stats.streak([day(2): 5], now: now) == 0, "昨日使っていなければ 0")
check(Stats.streak([:], now: now) == 0, "空")
let pd = Stats.perDay(recs)
check(pd[day(0)] == 2 && pd[day(2)] == 1, "日ごと: \(pd)")

// 見せ方
check(Stats.duration(40) == "40 秒" && Stats.duration(150) == "2 分" && Stats.duration(3900) == "1 時間 5 分", "時間の見せ方")
check(Stats.number(12345) == "12,345", Stats.number(12345))

if failures > 0 { print("stats: \(failures) failed"); exit(1) }
print("stats: ok")
