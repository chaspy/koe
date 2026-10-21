import Foundation

// 入らなかった録音（取り消した・聞き取れなかった・文字起こしに失敗した）を、履歴から選んでもう一度文字起こしする（Retranscriber）。
// ここは一覧の選び方と見せ方だけ。AppKit を使わない（make test で確かめる）。
// 録音は履歴（history/YYYY-MM-DD/<id>.wav）にあるものだけ使う。残す期間は履歴の決まり（Retention）どおりで、ここでは延ばさない
enum RetryList {
    // 一覧に出す結果と、その見せ方。「声を検出できなかった」（no_voice）は出さない:
    // 手元の履歴ではほぼ全部が音の小さい 1 秒前後の押し間違いで、やり直しても文にならない（一覧が埋まって本当に要るものが埋もれる）
    static let labels: [String: String] = [
        "cancelled": "取り消した録音",
        "hallucination": "聞き取れなかった録音",
        "error": "文字起こしに失敗した録音",
    ]
    static let days: Double = 7
    static let minSeconds = 1.0
    static let limit = 8

    struct Item: Equatable {
        let id: String       // 履歴の id（yyyy-MM-dd'T'HH-mm-ss-SSS）
        let outcome: String
        let seconds: Double  // 録音の長さ
        let time: Date
        var day: String { String(id.prefix(10)) }
    }

    private static let idFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"
        return f
    }()

    // 取り消した録音を履歴に残すか。この機能がオン（設定 retranscribe。既定オフ）で、履歴を残す設定で、
    // 1 秒以上話していて（それより短いのは押し間違い）、マウスでの取り消し（クリックしながら押した）でないときだけ
    static func keepCancelled(enabled: Bool, held: Double, reason: String, saveHistory: Bool) -> Bool {
        enabled && saveHistory && held >= 1.0 && reason != "mouse"
    }

    // 履歴の記録から、もう一度文字起こしできるものを新しい順に。録音が消えたもの・1 秒未満・やり直して入ったもの・ロック録音は出さない
    static func items(_ records: [[String: Any]], now: Date, audioExists: (String, String) -> Bool) -> [Item] {
        let from = now.addingTimeInterval(-days * 86400)
        var out: [Item] = []
        for r in records {
            guard let id = r["id"] as? String, let t = idFormat.date(from: id), t >= from, t <= now,
                  let o = r["outcome"] as? String, labels[o] != nil,
                  r["retranscribed_at"] == nil, r["locked"] as? Bool != true,
                  let seconds = r["audio_seconds"] as? Double, seconds >= minSeconds,
                  let audio = r["audio"] as? String, audioExists(String(id.prefix(10)), audio) else { continue }
            out.append(Item(id: id, outcome: o, seconds: seconds, time: t))
        }
        return Array(out.sorted { $0.id > $1.id }.prefix(limit))
    }

    // items が見る欄だけ残す（一覧を作るために覚えておく分を小さくする。文は持たない）
    static let keys = ["id", "outcome", "audio", "audio_seconds", "locked", "retranscribed_at"]
    static func slim(_ r: [String: Any]) -> [String: Any] { r.filter { keys.contains($0.key) } }

    // 履歴の日のフォルダ名（id の先頭 10 文字と同じ形）
    static func dayString(_ d: Date) -> String { String(idFormat.string(from: d).prefix(10)) }

    // 見る日のフォルダ（今日から days 日前まで）
    static func dayDirs(now: Date) -> [String] {
        (0...Int(days)).map { dayString(now.addingTimeInterval(-Double($0) * 86400)) }
    }

    // メニューの 1 行: 「今日 14:05  取り消した録音（12 秒）」
    static func title(_ item: Item, now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        let cal = Calendar.current
        f.dateFormat = cal.isDate(item.time, inSameDayAs: now) ? "今日 H:mm"
            : cal.isDate(item.time, inSameDayAs: now.addingTimeInterval(-86400)) ? "昨日 H:mm" : "M/d H:mm"
        let s = item.seconds
        let len = s >= 60 ? "\(Int(s) / 60) 分 \(Int(s) % 60) 秒" : "\(max(1, Int(s.rounded()))) 秒"
        return "\(f.string(from: item.time))  \(labels[item.outcome] ?? item.outcome)（\(len)）"
    }

    // やり直した結果が使えるか。空・決まり文句だけなら使えない（もう一度聞き取れなかった）
    static func usable(_ text: String, hallucinations: [String]) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !hallucinations.contains(t)
    }
}
