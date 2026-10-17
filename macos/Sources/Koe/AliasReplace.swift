import Foundation

// 個人の辞書の別名 1 つを文に当てる（Glossary.autocorrectWithLog から使う。単体テストできるよう分けた）。
// 「マジ>(され|し|する)」「パン粉>さん」のように > の後に続く語の条件を書いた別名は、その語が続くときだけ置き換える。
// 長いカタカナ語・英単語の一部（「フォールバック」の「フォール」等）は置き換えない
enum AliasReplace {
    static func apply(_ text: String, wrong: String, right: String) -> (text: String, hit: Bool) {
        let parts = wrong.split(separator: ">", maxSplits: 1).map(String.init)
        guard let head = parts.first, text.contains(head) else { return (text, false) }
        let follow = parts.count > 1 ? "(?=\(parts[1]))" : ""
        let pattern = "(?<![\\p{Katakana}ーA-Za-z0-9])" + NSRegularExpression.escapedPattern(for: head) + "(?![\\p{Katakana}ーA-Za-z0-9])" + follow
        guard let re = try? NSRegularExpression(pattern: pattern) else { return (text, false) }
        let range = NSRange(text.startIndex..., in: text)
        guard re.numberOfMatches(in: text, range: range) > 0 else { return (text, false) }
        return (re.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: right)), true)
    }
}
