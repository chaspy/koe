import Foundation

// 個人の辞書の別名 1 つを文に当てる（Glossary.autocorrectWithLog から使う。単体テストできるよう分けた）。
// 「マジ>(され|し|する)」「パン粉>さん」のように > の後に続く語の条件を書いた別名は、その語が続くときだけ置き換える。
// 長いカタカナ語・英単語の一部（「フォールバック」の「フォール」等）は置き換えない
enum AliasReplace {
    static func matcher(_ wrong: String) -> NSRegularExpression? {
        let parts = wrong.split(separator: ">", maxSplits: 1).map(String.init)
        guard let head = parts.first, !head.isEmpty else { return nil }
        let follow = parts.count > 1 ? "(?=\(parts[1]))" : ""
        let pattern = "(?<![\\p{Katakana}ーA-Za-z0-9])" + NSRegularExpression.escapedPattern(for: head) + "(?![\\p{Katakana}ーA-Za-z0-9])" + follow
        return try? NSRegularExpression(pattern: pattern)
    }

    // longer: 有効な辞書の語のうち right より長く right で始まるもの（HTM に対する HTML。#196）。
    // 文がすでにその長い語へ続いているところでは置き換えない（短い語を当てると長い語が崩れる）
    static func apply(_ text: String, wrong: String, right: String, longer: [String] = []) -> (text: String, hit: Bool) {
        guard let head = wrong.split(separator: ">", maxSplits: 1).first, text.contains(head),
              let re = matcher(wrong) else { return (text, false) }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let longKeys = longer.map(TermRules.key).filter { $0.count > right.count && $0.hasPrefix(TermRules.key(right)) }
        var out = "", cursor = 0, hit = false
        for m in matches {
            let after = TermRules.key(ns.substring(from: m.range.location + m.range.length))
            let found = TermRules.key(ns.substring(with: m.range))
            if longKeys.contains(where: { (TermRules.key(right) + after).hasPrefix($0) || (found + after).hasPrefix($0) }) { continue }
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)) + right
            cursor = m.range.location + m.range.length
            hit = true
        }
        guard hit else { return (text, false) }
        return (out + ns.substring(from: cursor), true)
    }

    /// terms のうち term で始まり、その直後が英数字かカタカナで 1 語として続くもの（HTM → HTML、Java → JavaScript）。
    /// 空白や記号で区切れる語（CI → CI/CD、Claude → Claude Code）や、大文字小文字の違う語（PR → Prometheus）は含めない
    static func longer(than term: String, in terms: [String]) -> [String] {
        guard !term.isEmpty else { return [] }
        return terms.filter { t in
            guard t.count > term.count, t.hasPrefix(term), let next = t.dropFirst(term.count).unicodeScalars.first else { return false }
            return (next.isASCII && CharacterSet.alphanumerics.contains(next)) || (0x30A0...0x30FF).contains(next.value)
        }
    }
}
