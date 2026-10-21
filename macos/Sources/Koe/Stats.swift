import Foundation

// 自分の記録（StatsWindow）の集計。履歴（history/<日付>/<id>.json）と events.jsonl を手元で数えるだけで、どこにも送らない。
// 数えるのは数だけ（貼った文は文字数を数えるのに使い、画面にも記録にも出さない）。AppKit を使わない（make test で確かめる）
enum Stats {
    // 打つ速さの前提（画面に書いて見せる）。日本語をキーボードで打つ（かな漢字変換込み）のは 1 分に 60 文字くらいとする
    static let typingPerMinute = 60.0

    struct Rec {
        let time: Date
        let chars: Int          // 貼った文字数
        let speakSeconds: Double // 押していた長さ
        let fixes: Int          // 辞書で置き換えた数
        let releaseToPasteMs: Int?
        let visibleMs: Int?     // 貼ってから画面に出るまで（測る設定のときだけ）
    }

    private static let idFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"
        return f
    }()

    // 履歴の記録から、貼った発話だけ。ロック録音（貼らずにファイルに書く。相手の声も入る）は数えない
    static func rec(_ r: [String: Any]) -> Rec? {
        guard let id = r["id"] as? String, let t = idFormat.date(from: id),
              let pasted = r["pasted"] as? String, !pasted.isEmpty, r["locked"] as? Bool != true else { return nil }
        return Rec(time: t, chars: pasted.count, speakSeconds: r["hold_seconds"] as? Double ?? r["audio_seconds"] as? Double ?? 0,
                   fixes: (r["autocorrected"] as? [Any])?.count ?? 0,
                   releaseToPasteMs: r["release_to_paste_ms"] as? Int, visibleMs: r["visible_ms"] as? Int)
    }

    struct Summary: Equatable {
        var utterances = 0
        var chars = 0
        var speakSeconds = 0.0
        var fixes = 0
        var learned = 0
        var medianReleaseToPasteMs: Int?
        var medianVisibleMs: Int?
        // キーボードで打ったらかかる時間 − 話した時間（負なら 0）
        var savedSeconds: Double { max(0, Double(chars) / typingPerMinute * 60 - speakSeconds) }
    }

    static func median(_ xs: [Int]) -> Int? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    // from から now までの集計。learned は改善ループが辞書に足した語の数（events から）
    static func summarize(_ recs: [Rec], from: Date, now: Date, learned: Int = 0) -> Summary {
        var s = Summary()
        let rs = recs.filter { $0.time >= from && $0.time <= now }
        s.utterances = rs.count
        s.chars = rs.reduce(0) { $0 + $1.chars }
        s.speakSeconds = rs.reduce(0) { $0 + $1.speakSeconds }
        s.fixes = rs.reduce(0) { $0 + $1.fixes }
        s.learned = learned
        s.medianReleaseToPasteMs = median(rs.compactMap(\.releaseToPasteMs))
        s.medianVisibleMs = median(rs.compactMap(\.visibleMs))
        return s
    }

    // 改善ループが辞書に足した語の数（events の improve の summary「…辞書に追加: A、B」）。from 以降
    static func learnedCount(events text: String, from: Date) -> Int {
        let f = ISO8601DateFormatter()
        var words = Set<String>()
        for line in text.split(separator: "\n") where line.contains("辞書に追加") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  d["outcome"] as? String == "improve", let s = d["summary"] as? String,
                  let t = (d["t"] as? String).flatMap(f.date(from:)), t >= from,
                  let r = s.range(of: "辞書に追加: ") else { continue }
            for w in s[r.upperBound...].split(separator: "、").map({ $0.trimmingCharacters(in: .whitespaces) }) where !w.isEmpty && w != "なし" {
                words.insert(w)
            }
        }
        return words.count
    }

    // 日ごとの貼った回数（ヒートマップ用）。キーはその日の 0 時
    static func perDay(_ recs: [Rec], cal: Calendar = .current) -> [Date: Int] {
        var out: [Date: Int] = [:]
        for r in recs { out[cal.startOfDay(for: r.time), default: 0] += 1 }
        return out
    }

    // 続けて使った日数。今日まだ使っていなくても、昨日まで続いていれば途切れていない（今日のうちに使えば続く）
    static func streak(_ days: [Date: Int], now: Date, cal: Calendar = .current) -> Int {
        var d = cal.startOfDay(for: now)
        if (days[d] ?? 0) == 0 { d = cal.date(byAdding: .day, value: -1, to: d)! }
        var n = 0
        while (days[d] ?? 0) > 0 {
            n += 1
            d = cal.date(byAdding: .day, value: -1, to: d)!
        }
        return n
    }

    // 「1 時間 5 分」「12 分」「40 秒」
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return "\(s / 3600) 時間 \(s % 3600 / 60) 分" }
        if s >= 60 { return "\(s / 60) 分" }
        return "\(s) 秒"
    }

    // 「12,345」
    static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "ja_JP")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
