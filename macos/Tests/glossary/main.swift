// test-sources: GlossaryCatalog.swift
// make test: Sources/Koe/GlossaryCatalog.swift の単体テスト（辞書の画面と「覚えた語」のお知らせの判定）
import Foundation

var failures = 0
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    if got != want { failures += 1; print("FAIL: \(name): got \(got) want \(want)") }
}
let f = ISO8601DateFormatter()
let now = f.date(from: "2026-10-17T03:00:00Z")!

// 覚えた語: improve の summary から。最初に足した時刻を取る。なし・他の記録は数えない
let events = """
{"outcome":"improve","summary":"5 件を処理（判定 5、伝わらなかった 0）。辞書に追加: STG、panko","t":"2026-10-15T01:00:00Z"}
{"outcome":"improve","summary":"3 件を処理（判定 3、伝わらなかった 0）。辞書に追加: なし","t":"2026-10-16T01:00:00Z"}
{"outcome":"improve","summary":"2 件を処理。辞書に追加: panko、BQ","t":"2026-10-16T02:00:00Z"}
{"outcome":"pasted","summary":"辞書に追加: 偽物","t":"2026-10-16T02:00:00Z"}
{"outcome":"improve","summary":"辞書に追加: 古い語","t":"2026-10-01T02:00:00Z"}
not json
"""
let learned = GlossaryCatalog.learnedDates(events: events)
check("learned keys", Set(learned.keys), ["STG", "panko", "BQ", "古い語"])
check("first time", learned["panko"], f.date(from: "2026-10-15T01:00:00Z"))
check("since 7 days (new first)", GlossaryCatalog.learnedSince(learned, now: now), ["BQ", "STG", "panko"])
check("since count", GlossaryCatalog.learnedSince(learned, now: now).count, 3)

// 出どころ
check("learned by event", GlossaryCatalog.origin("STG", learned: learned, candidates: []) == .learned, true)
check("learned by candidate", GlossaryCatalog.origin("Herdr", learned: [:], candidates: ["Herdr"]) == .learned, true)
check("manual", GlossaryCatalog.origin("GitHub", learned: learned, candidates: ["Herdr"]) == .manual, true)

// 別名の見せ方
let l = GlossaryCatalog.aliasLabels(["プロリク", "~マジ", "マジ>(され|し|する)", "パンコ>さん"])
check("sure", l.sure, ["プロリク", "マジ（後ろが され・し・する のとき）", "パンコ（後ろが さん のとき）"])
check("note only", l.noteOnly, ["マジ"])

// ヒントの枠に入りきらない数（重複は 1 つ）
check("not in hint", GlossaryCatalog.notInHint(all: ["a", "b", "c", "c"], included: ["a"]), 2)

// お知らせの頻度
let used = now.addingTimeInterval(-60)
check("notify", GlossaryCatalog.shouldNotify(now: now, newCount: 3, lastShown: nil, busy: false, lastUsed: used), true)
check("no words", GlossaryCatalog.shouldNotify(now: now, newCount: 0, lastShown: nil, busy: false, lastUsed: used), false)
check("busy", GlossaryCatalog.shouldNotify(now: now, newCount: 3, lastShown: nil, busy: true, lastUsed: used), false)
check("just used", GlossaryCatalog.shouldNotify(now: now, newCount: 3, lastShown: nil, busy: false, lastUsed: now.addingTimeInterval(-5)), false)
check("away", GlossaryCatalog.shouldNotify(now: now, newCount: 3, lastShown: nil, busy: false, lastUsed: now.addingTimeInterval(-3600)), false)
check("never used", GlossaryCatalog.shouldNotify(now: now, newCount: 3, lastShown: nil, busy: false, lastUsed: nil), false)
check("shown 6 days ago", GlossaryCatalog.shouldNotify(now: now, newCount: 3, lastShown: now.addingTimeInterval(-6 * 86400), busy: false, lastUsed: used), false)
check("shown 7 days ago", GlossaryCatalog.shouldNotify(now: now, newCount: 3, lastShown: now.addingTimeInterval(-7 * 86400), busy: false, lastUsed: used), true)

// お知らせの文
check("text few", GlossaryCatalog.noticeText(["STG", "panko"]).title, "この 1 週間で 2 語を覚えました")
check("text few detail", GlossaryCatalog.noticeText(["STG", "panko"]).detail, "STG、panko。次からこの書き方で入ります")
check("text many", GlossaryCatalog.noticeText(["a", "b", "c", "d", "e"]).detail, "a、b、c ほか 2 語。次からこの書き方で入ります")

// 組織の辞書の取得時刻
check("org none url", GlossaryCatalog.orgFetchedLabel(nil, now: now, url: true), "まだ取り込めていません（ネットにつながると取り込みます）")
check("org stale", GlossaryCatalog.orgFetchedLabel(now.addingTimeInterval(-3 * 86400), now: now, url: true).contains("2 日以上取り直せていません"), true)
check("org fresh", GlossaryCatalog.orgFetchedLabel(now.addingTimeInterval(-3600), now: now, url: true).contains("1 日 1 回取り直します"), true)
check("org file", GlossaryCatalog.orgFetchedLabel(now.addingTimeInterval(-3600), now: now, url: false).hasPrefix("ファイルの更新: "), true)

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("glossary: ok")
