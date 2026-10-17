import Foundation

// 社員名簿（設定 peopleSources で取り込む「<ID><TAB><本名>」の表。# はコメント）を改善ループで使うための判定と書き出し。
// 名簿の中身はログ・標準出力・診断情報に出さない（件数だけ）。whisper の初期プロンプトにも入れない。
// 人の名前の化けは、次の条件をすべて満たすときだけ個人の辞書に足す（普通の語を人名に取り違えないため）:
//   - LLM が確度 high と答えた（本人が正しい表記を示した explicit なら不問）
//   - 化けた形が文字起こしに実際にあり、直後に「さん」などの敬称が付いている（explicit なら敬称なしでもよい）
//   - 発話か前後（送った文・返答・次の発話）に、人とのやりとりの文脈（Slack・レビュー等）がある（explicit なら不問）
//   - 正しい表記が名簿の本名（の一部）のときは、化けた形が漢字を含み（同じ読みの別の字。「山舌さん」→「山下」）、
//     その人の既知の呼び方でもないときだけ。ひらがな・カタカナ・英字だけの形はわざと言ったあだ名かもしれないので、
//     本人が示したとき以外は足さない（わざと言ったあだ名を本名に書き換えない）
//   - 化けた形がすでに名簿の ID・本名そのものなら足さない（化けていない）
// 足す別名は「化けた形>敬称」（敬称が続くときだけ置き換わる。「パン粉を買う」は置き換わらない）
// 出現が少ない名前は化けた形の一部しか集まらないので、足すと決めたとき（確度 high・敬称つき）は、LLM が出した
// 「同じ人が化けそうな近い読みの形」（variants、最大 5 つ）も同じ守りを通して「形>敬称」の別名に足す（variantAliases）
enum People {
    struct Person: Equatable { let id: String; let name: String }

    static func parse(_ text: String) -> [Person] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
            let cols = s.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count == 2, !cols[0].isEmpty, !cols[1].isEmpty else { return nil }
            return Person(id: cols[0], name: cols[1])
        }
    }

    static let honorifics = ["さん", "さま", "くん", "ちゃん", "様", "氏", "君"]

    // 人とのやりとりの文脈を示す語（前後のどこかにあれば、人の名前として扱ってよい）
    static let cues = ["Slack", "slack", "スラック", "レビュー", "PR", "プルリク", "メンション", "DM", "スレッド", "チャンネル",
                       "1on1", "MTG", "ミーティング", "会議", "定例", "issue", "Issue", "チケット", "GitHub", "リポジトリ",
                       "コミット", "マージ", "アサイン", "担当", "返信", "連絡", "メール", "チーム", "部長", "マネージャー"]

    // 末尾の敬称を分ける（「パン粉さん」→「パン粉」「さん」）
    static func splitHonorific(_ s: String) -> (core: String, honorific: String?) {
        for h in honorifics where s.hasSuffix(h) && s.count > h.count {
            return (String(s.dropLast(h.count)), h)
        }
        return (s, nil)
    }

    // 文中で core の直後に続く敬称（最初に見つかったもの）
    static func honorific(after core: String, in text: String) -> String? {
        var from = text.startIndex
        while let r = text.range(of: core, range: from..<text.endIndex) {
            let rest = text[r.upperBound...]
            if let h = honorifics.first(where: { rest.hasPrefix($0) }) { return h }
            from = r.upperBound
        }
        return nil
    }

    static func nameParts(_ people: [Person]) -> Set<String> {
        var out = Set<String>()
        for p in people {
            out.insert(p.name.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: ""))
            for part in p.name.split(whereSeparator: { $0 == " " || $0 == "　" }) where part.count >= 2 { out.insert(String(part)) }
        }
        return out
    }

    static func isID(_ w: String, _ people: [Person]) -> Bool {
        people.contains { $0.id.lowercased() == w.lowercased() }
    }

    // 名簿の ID か本名（の一部）か。kind: "term" で返ってきた人名も、人の名前として判定に回すため
    static func isPersonName(_ w: String, _ people: [Person]) -> Bool {
        let core = splitHonorific(w).core
        return isID(core, people) || nameParts(people).contains(core.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: ""))
    }

    struct Candidate {
        var wrong: String
        var right: String
        var who: String? = nil
        var explicit = false
        var confidence: String? = nil
        var transcript: String          // その発話の文字起こし
        var context: String = ""        // 送った文・Claude の返答・次の発話
        var variants: [String] = []     // LLM が出した、同じ人が化けそうな近い読みの形（敬称の有無は問わない）
    }

    struct Accepted: Equatable {
        let term: String   // 個人の辞書の語（本人が言った呼び方。敬称なし）
        let alias: String  // 化けた形。敬称が続くときだけ置き換えるなら「化けた形>敬称」
        let who: String?   // 名簿の ID（分かれば）
        let called: String // 呼び方（敬称つき。koe-people.md に書く）
        var variants: [String] = []  // 近い読みの形の別名（「形>敬称」。守りを通ったものだけ）
    }

    enum Rejection: String {
        case badForm, lowConfidence, notInTranscript, noHonorific, noContext, nicknameToRealName, alreadyCorrect, unknownPerson
    }

    enum Decision: Equatable {
        case add(Accepted)
        case skip(Rejection)
    }

    static func hasKanji(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    // knownCalled: 改善ループで分かった呼び方（ID → 敬称つきの呼び方。people_known.json の called）
    static func judge(_ c: Candidate, people: [Person], knownCalled: [String: [String]] = [:]) -> Decision {
        let (wc, wh) = splitHonorific(c.wrong.trimmingCharacters(in: .whitespaces))
        let (rc, rh) = splitHonorific(c.right.trimmingCharacters(in: .whitespaces))
        guard !wc.isEmpty, wc.count <= 15, (2...30).contains(rc.count), wc != rc,
              !wc.contains("、"), !rc.contains("("), !rc.contains("（") else { return .skip(.badForm) }
        guard c.explicit || c.confidence == "high" else { return .skip(.lowConfidence) }
        guard c.transcript.contains(wc) else { return .skip(.notInTranscript) }
        let h = wh.flatMap { c.transcript.contains(wc + $0) ? $0 : nil } ?? honorific(after: wc, in: c.transcript)
        guard h != nil || c.explicit else { return .skip(.noHonorific) }
        if !c.explicit {
            let around = c.transcript + "\n" + c.context
            guard cues.contains(where: { around.contains($0) }) else { return .skip(.noContext) }
        }
        var who = c.who?.trimmingCharacters(in: .whitespaces)
        if who?.isEmpty == true { who = nil }
        if !people.isEmpty {
            if isPersonName(wc, people) { return .skip(.alreadyCorrect) }
            let rcName = rc.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "")
            if nameParts(people).contains(rcName) && !c.explicit {
                let isKnownCall = knownCalled.values.contains { $0.contains { splitHonorific($0).core == wc } }
                if !hasKanji(wc) || isKnownCall { return .skip(.nicknameToRealName) }
            }
            if let w = who {
                guard let p = people.first(where: { $0.id.lowercased() == w.lowercased() }) else { return .skip(.unknownPerson) }
                who = p.id
            } else if let p = people.first(where: { $0.id.lowercased() == rc.lowercased() }) {
                who = p.id
            }
        }
        let honor = h ?? rh ?? "さん"
        var a = Accepted(term: rc, alias: h.map { "\(wc)>\($0)" } ?? wc, who: who, called: rc + honor)
        if let h, c.confidence == "high" {
            a.variants = variantAliases(c.variants, wrong: wc, right: rc, honorific: h, people: people, knownCalled: knownCalled)
        }
        return .add(a)
    }

    static let maxVariants = 5

    // 近い読みの形を「形>敬称」の別名にする。judge と同じ守り: 名簿の ID・本名そのもの（化けていない）、
    // 誰かの既知の呼び方、本名に対するひらがな・カタカナ・英字だけの形（わざと言ったあだ名かもしれない）は足さない
    static func variantAliases(_ forms: [String], wrong: String, right: String, honorific: String,
                               people: [Person], knownCalled: [String: [String]]) -> [String] {
        let realName = nameParts(people).contains(right.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: ""))
        let calls = Set(knownCalled.values.flatMap { $0.map { splitHonorific($0).core } })
        var out: [String] = [], seen: Set<String> = [wrong, right]
        for f in forms {
            let v = splitHonorific(f.trimmingCharacters(in: .whitespaces)).core
            guard (2...15).contains(v.count), !v.contains(where: { "、,／/>~\t\n ".contains($0) }),
                  seen.insert(v).inserted, !isPersonName(v, people), !calls.contains(v),
                  !(realName && !hasKanji(v)) else { continue }
            out.append("\(v)>\(honorific)")
            if out.count == maxVariants { break }
        }
        return out
    }

    // 「この呼び方は誰か」（化けていない呼び方・あだ名）。koe-people.md に書くだけで、辞書には足さない
    struct Called { var called: String; var who: String; var confidence: String?; var transcript: String }

    static func judgeCalled(_ c: Called, people: [Person]) -> (who: String, called: String)? {
        guard c.confidence == "high", let p = people.first(where: { $0.id.lowercased() == c.who.lowercased() }) else { return nil }
        let (core, h) = splitHonorific(c.called.trimmingCharacters(in: .whitespaces))
        guard (2...20).contains(core.count), c.transcript.contains(core) else { return nil }
        guard let honor = h.flatMap({ c.transcript.contains(core + $0) ? $0 : nil }) ?? honorific(after: core, in: c.transcript) else { return nil }
        return (p.id, core + honor)
    }

    // 改善ループの LLM に渡す名簿
    static func promptBlock(_ people: [Person]) -> String {
        people.map { "\($0.id)\t\($0.name)" }.joined(separator: "\n")
    }

    // 受け取る AI が、分からない名前に出会ったときだけ引く一覧（全員分＋分かった呼び方・化けた形）
    static func receiverNote(_ people: [Person], called: [String: [String]], wrongs: [String: [String]]) -> String {
        var s = "# 社員の名前と呼び方（Koe）\n\n"
        s += "音声入力（Koe）の文に、誰のことか分からない名前・呼び名が出てきたときだけ引く一覧（常時は読み込まない）。\n"
        s += "「〜さん」の前の音が近い ID・本名・呼び方を探して読み替え、読み替えたことは一言添える。"
        s += "わざと言ったあだ名は本名に書き換えず、そのまま扱う。\n\n"
        s += "1 行 1 人: ID<TAB>本名<TAB>呼び方（分かったものだけ）<TAB>化けた形（分かったものだけ）\n\n"
        for p in people {
            var line = "\(p.id)\t\(p.name)"
            let c = called[p.id] ?? [], w = wrongs[p.id] ?? []
            if !c.isEmpty || !w.isEmpty { line += "\t\(c.joined(separator: "、"))" }
            if !w.isEmpty { line += "\t\(w.joined(separator: "、"))" }
            s += line + "\n"
        }
        return s
    }
}
