import Foundation

// 改善ループが出した語の提案と、その行き先（足した・保留・落とした＋理由）。#252
// 行は改善ループのたびに improve_proposals.jsonl（Koe のデータフォルダ、この Mac の中だけ）に足す。events には数だけ
enum ImproveProposals {
    enum Fate: String { case added, pending, dropped }

    enum Reason: String {
        case shape           // 文・注記・長すぎる（「、」や括弧を含む等）
        case phrase          // 句・語尾を含む（TermRules）
        case commonWord      // 一般語の可能性（TermRules）
        case aliasChain      // 正しい表記が別の語の聞き間違いとして既にある
        case existingTerm    // 化けた形が既にある正しい表記
        case person          // 人の名前の守り（People.judge）を通らなかった
        case ordinaryAlias   // 化けた形がどれも普通の言葉に見えて、別名として残らなかった
    }

    // 同じ聞き間違いの組が「繰り返し出た」とみなす条件: 2 回以上の改善ループ、または 3 発話以上
    static let minRuns = 2
    static let minUtterances = 3
    static let window: TimeInterval = 7 * 86400

    static func entry(run: String, at: String, index: Int?, wrong: String, right: String, kind: String?,
                      confidence: String?, fate: Fate, reason: Reason?) -> [String: Any] {
        var e: [String: Any] = ["run": run, "t": at, "wrong": wrong, "right": right, "fate": fate.rawValue]
        if let index { e["i"] = index }
        if let kind { e["kind"] = kind }
        if let confidence { e["confidence"] = confidence }
        if let reason { e["reason"] = reason.rawValue }
        return e
    }

    // log: 過去の提案（この回の分を含めてよい）。同じ wrong→right が繰り返し出ていれば true
    static func repeated(_ log: [[String: Any]], wrong: String, right: String) -> Bool {
        var runs = Set<String>(), utterances = Set<String>()
        for e in log where e["wrong"] as? String == wrong && e["right"] as? String == right {
            let run = e["run"] as? String ?? ""
            runs.insert(run)
            utterances.insert(run + "#" + ((e["i"] as? Int).map(String.init) ?? "?"))
        }
        return runs.count >= minRuns || utterances.count >= minUtterances
    }

    // jsonl の行を読み、窓（既定 7 日）より新しいものだけ返す。壊れた行は飛ばす
    static func parse(_ text: String, now: Date, window: TimeInterval = window) -> [[String: Any]] {
        let f = ISO8601DateFormatter()
        return text.split(separator: "\n").compactMap { line in
            guard let e = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let t = (e["t"] as? String).flatMap(f.date(from:)), now.timeIntervalSince(t) <= window else { return nil }
            return e
        }
    }

    // TermRules の拒否理由をそのまま記録の理由にする（名前は同じ）
    static func reason(_ r: TermRules.Rejection) -> Reason { Reason(rawValue: r.rawValue) ?? .phrase }

    // ループの終わりに保留の行き先を決める: 辞書に書いた語は added、昇格したのに別名が残らなかった語は dropped
    static func settle(_ entries: [[String: Any]], written: Set<String>, emptied: Set<String>) -> [[String: Any]] {
        entries.map { e in
            guard e["fate"] as? String == Fate.pending.rawValue, let right = e["right"] as? String else { return e }
            var e = e
            if written.contains(right) { e["fate"] = Fate.added.rawValue }
            else if emptied.contains(right) { e["fate"] = Fate.dropped.rawValue; e["reason"] = Reason.ordinaryAlias.rawValue }
            return e
        }
    }

    static func serialize(_ entries: [[String: Any]]) -> String {
        entries.compactMap { (try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } }
            .map { $0 + "\n" }.joined()
    }

    // events に書く数（語は書かない）
    static func counts(_ entries: [[String: Any]]) -> [String: Int] {
        var c = ["proposed": entries.count, "added": 0, "pending": 0, "dropped": 0]
        for e in entries {
            let fate = e["fate"] as? String ?? ""
            c[fate, default: 0] += 1
            if fate == Fate.dropped.rawValue, let r = e["reason"] as? String { c["dropped_" + r, default: 0] += 1 }
        }
        return c
    }
}
