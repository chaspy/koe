import Foundation

// 辞書を見せる画面（GlossaryWindow）と「覚えた語」のお知らせ（LearnedNotice）の判定。AppKit を使わない（make test で確かめる）。
// 語は画面に出すだけで、events・history・診断 zip には書かない（数だけ）
enum GlossaryCatalog {
    enum Origin { case learned, manual }

    // 改善ループが辞書に足した語と、最初に足した時刻。events.jsonl の improve の summary「…辞書に追加: A、B」から読む
    static func learnedDates(events text: String) -> [String: Date] {
        var out: [String: Date] = [:]
        let f = ISO8601DateFormatter()
        for line in text.split(separator: "\n") where line.contains("\"improve\"") && line.contains("辞書に追加") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  d["outcome"] as? String == "improve", let s = d["summary"] as? String,
                  let t = (d["t"] as? String).flatMap(f.date(from:)),
                  let r = s.range(of: "辞書に追加: ") else { continue }
            for w in s[r.upperBound...].split(separator: "、").map({ $0.trimmingCharacters(in: .whitespaces) }) where !w.isEmpty && w != "なし" {
                if out[w] == nil || t < out[w]! { out[w] = t }
            }
        }
        return out
    }

    // 自分の辞書の語が、改善ループが覚えたものか、自分で入れたものか。
    // 覚えた記録（events）か、改善ループの候補（glossary_candidates.json のキー）にあれば「自動で覚えた」
    static func origin(_ term: String, learned: [String: Date], candidates: Set<String>) -> Origin {
        learned[term] != nil || candidates.contains(term) ? .learned : .manual
    }

    // 別名の見せ方。sure: 見つけたら直す形、noteOnly: 直さず、受け取る AI へのメモにだけ使う形（先頭が ~）
    static func aliasLabels(_ aliases: [String]) -> (sure: [String], noteOnly: [String]) {
        func label(_ a: String) -> String {
            guard let i = a.firstIndex(of: ">") else { return a }
            let cond = a[a.index(after: i)...].trimmingCharacters(in: CharacterSet(charactersIn: "()（）"))
            let words = cond.split(separator: "|").joined(separator: "・")
            return words.isEmpty ? String(a[..<i]) : "\(a[..<i])（後ろが \(words) のとき）"
        }
        var sure: [String] = [], note: [String] = []
        for a in aliases {
            if a.hasPrefix("~") { note.append(label(String(a.dropFirst()))) } else { sure.append(label(a)) }
        }
        return (sure, note)
    }

    // 最近 days 日に覚えた語（新しい順）
    static func learnedSince(_ learned: [String: Date], now: Date, days: Double = 7) -> [String] {
        let from = now.addingTimeInterval(-days * 86400)
        return learned.filter { $0.value >= from && $0.value <= now }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    // whisper のヒントの枠に入りきらない語の数（辞書に入っている語のうち、ヒントに入らなかった数）
    static func notInHint(all: [String], included: [String]) -> Int {
        Set(all).subtracting(included).count
    }

    // 「覚えた語」のお知らせを出すか。うるさくしない:
    // - 1 週間（前に出してから 7 日）に 1 回まで。覚えた語が 0 なら出さない
    // - 使い終わって落ち着いたとき（録音・文字起こし中でなく、最後に使ってから 30 秒以上）に出す。
    //   ただし最後に使ってから 10 分を過ぎていたら出さない（席を外しているかもしれない。次に使ったあとに出す）
    static let noticeEvery: TimeInterval = 7 * 86400
    static func shouldNotify(now: Date, newCount: Int, lastShown: Date?, busy: Bool, lastUsed: Date?) -> Bool {
        guard newCount > 0, !busy, let lastUsed else { return false }
        let idle = now.timeIntervalSince(lastUsed)
        guard idle >= 30, idle <= 600 else { return false }
        if let lastShown, now.timeIntervalSince(lastShown) < noticeEvery { return false }
        return true
    }

    // お知らせの文。語は 3 つまで見せる（多いときは「ほか N 語」）
    static func noticeText(_ words: [String]) -> (title: String, detail: String) {
        let shown = words.prefix(3).joined(separator: "、")
        let rest = words.count > 3 ? " ほか \(words.count - 3) 語" : ""
        return ("この 1 週間で \(words.count) 語を覚えました", "\(shown)\(rest)。次からこの書き方で入ります")
    }

    // 組織の辞書をいつ取ったか（URL のとき）の一言。2 日を超えたら取り直せていない
    static func orgFetchedLabel(_ fetched: Date?, now: Date, url: Bool) -> String {
        guard let fetched else { return url ? "まだ取り込めていません（ネットにつながると取り込みます）" : "ファイルが見つかりません" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = Calendar.current.isDate(fetched, inSameDayAs: now) ? "今日 H:mm" : "M/d H:mm"
        let when = f.string(from: fetched)
        guard url else { return "ファイルの更新: \(when)" }
        let stale = now.timeIntervalSince(fetched) > 2 * 86400
        return "最終取得: \(when)" + (stale ? "（2 日以上取り直せていません。ネットや配布元を確かめてください）" : "（1 日 1 回取り直します）")
    }
}
