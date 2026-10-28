// test-sources: RetryList.swift
// make test: Sources/Koe/RetryList.swift の単体テスト（XCTest なしで動く）
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

var comps = DateComponents(); comps.year = 2026; comps.month = 10; comps.day = 17; comps.hour = 15
let now = Calendar.current.date(from: comps)!
let idf: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"; return f }()
func id(_ ago: TimeInterval) -> String { idf.string(from: now.addingTimeInterval(-ago)) }
func rec(_ ago: TimeInterval, _ outcome: String, _ extra: [String: Any] = [:]) -> [String: Any] {
    let i = id(ago)
    var r: [String: Any] = ["id": i, "outcome": outcome, "audio": "\(i).wav", "audio_seconds": 12.3]
    for (k, v) in extra { r[k] = v }
    return r
}

// 取り消した録音を残すか
check(RetryList.keepCancelled(enabled: true, held: 1.0, reason: "key 12", saveHistory: true), "1 秒話して取り消したら残す")
check(!RetryList.keepCancelled(enabled: true, held: 0.9, reason: "key 12", saveHistory: true), "1 秒未満は押し間違い")
check(RetryList.keepCancelled(enabled: true, held: 3, reason: "mouse", saveHistory: true), "2 秒超のマウス取り消しも残す")
check(!RetryList.keepCancelled(enabled: true, held: 3, reason: "key 12", saveHistory: false), "2 秒超でも履歴保存オフなら残さない")
check(RetryList.keepCancelled(enabled: false, held: 3, reason: "key 12", saveHistory: true), "2 秒超は機能設定に関係なく残す")

// 一覧
let gone = id(60)
let records: [[String: Any]] = [
    rec(30, "cancelled"),
    rec(60, "hallucination"),                          // 録音が消えている
    rec(90, "error"),
    rec(120, "no_voice"),                               // 声が無い（ほぼ押し間違い）
    rec(130, "cancelled", ["audio_seconds": 0.8]),       // 短すぎる
    rec(150, "mic_silent"),                             // 音が来ていない（やり直しても無駄）
    ["id": id(180), "outcome": "target_changed", "audio": "x.wav"],  // 文はクリップボードと「最近」にある
    rec(200, "cancelled", ["retranscribed_at": "2026-10-17T05:00:00Z"]),  // やり直して入った
    rec(210, "hallucination", ["locked": true]),
    rec(220, "error", ["audio": NSNull()]),
    rec(8 * 86400, "cancelled"),                        // 1 週間より前
    ["id": "broken", "outcome": "cancelled", "audio": "a.wav"],
    ["outcome": "pasted"],
]
let items = RetryList.items(records, now: now) { day, audio in !audio.hasPrefix(gone) && day == String(audio.prefix(10)) || audio.hasPrefix(id(8 * 86400)) }
check(items.map(\.outcome) == ["cancelled", "error", "no_voice", "mic_silent", "hallucination"], "選ぶ結果: \(items.map(\.outcome))")
check(items.first?.id == id(30) && items.first?.day == String(id(30).prefix(10)), "新しい順・日のフォルダ")
check(items.first?.seconds == 12.3, "長さ")
// 多いときは limit 件まで
let many = (1...20).map { rec(Double($0) * 60, "cancelled") }
let top = RetryList.items(many, now: now) { _, _ in true }
check(top.count == RetryList.limit && top.first?.id == id(60), "最大 \(RetryList.limit) 件、新しい順: \(top.count)")
// 未来の id（時計がずれた）は出さない
check(RetryList.items([rec(-3600, "cancelled")], now: now) { _, _ in true }.isEmpty, "未来は出さない")

// 見せ方
let today = RetryList.Item(id: id(3600), outcome: "cancelled", seconds: 12.4, time: now.addingTimeInterval(-3600))
check(RetryList.title(today, now: now) == "今日 14:00  取り消した録音（12 秒）", RetryList.title(today, now: now))
let y = RetryList.Item(id: "x", outcome: "error", seconds: 75, time: now.addingTimeInterval(-86400))
check(RetryList.title(y, now: now) == "昨日 15:00  文字起こしに失敗した録音（1 分 15 秒）", RetryList.title(y, now: now))
let old = RetryList.Item(id: "x", outcome: "hallucination", seconds: 1.2, time: now.addingTimeInterval(-3 * 86400))
check(RetryList.title(old, now: now) == "10/14 15:00  聞き取れなかった録音（1 秒）", RetryList.title(old, now: now))

// やり直した結果
check(RetryList.usable("こんにちは", hallucinations: ["ご視聴ありがとうございました"]), "普通の文は使える")
check(!RetryList.usable("  ", hallucinations: []), "空は使えない")
check(!RetryList.usable("ご視聴ありがとうございました\n", hallucinations: ["ご視聴ありがとうございました"]), "決まり文句だけは使えない")

// 覚えておく欄（文は持たない）。小さくしても選び方は同じ
let full = rec(30, "cancelled", ["raw": "本文", "pasted": NSNull(), "whisper_prompt": "x"])
let slim = RetryList.slim(full)
check(slim["raw"] == nil && slim["whisper_prompt"] == nil && slim["outcome"] as? String == "cancelled", "slim: \(slim.keys.sorted())")
check(RetryList.items([slim], now: now) { _, _ in true }.map(\.id) == RetryList.items([full], now: now) { _, _ in true }.map(\.id), "slim でも同じ一覧")
// 見る日のフォルダ
let dirs = RetryList.dayDirs(now: now)
check(dirs.count == 8 && dirs.first == "2026-10-17" && dirs.last == "2026-10-10", "日のフォルダ: \(dirs)")

if failures > 0 { print("retry: \(failures) failed"); exit(1) }
print("retry: ok")
