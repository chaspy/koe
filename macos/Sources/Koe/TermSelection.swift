import Foundation

// Pure ranking: callers supply dictionaries and at most the latest 300 utterances.
enum TermSelection {
    struct Entry { let term: String; let aliases: [String] }
    struct Sample { let pasted: String; let raw: String }

    static func counts(_ entries: [Entry], samples: [Sample], includeRaw: Bool = true) -> [String: Int] {
        let recent = samples.suffix(300).map { (pasted: TermRules.key($0.pasted) as NSString, raw: TermRules.key($0.raw)) }
        var result: [String: Int] = [:]
        for entry in entries {
            let aliases = entry.aliases.map { $0.hasPrefix("~") ? String($0.dropFirst()) : $0 }
            let pastedKeys = ([entry.term] + aliases).map(TermRules.key).filter { $0.count >= 2 }
            let rawPatterns = aliases.compactMap { AliasReplace.matcher(TermRules.key($0)) }
            let count = recent.reduce(0) { total, sample in
                // Preserve the existing pasted score; each channel contributes at most one per utterance.
                let pasted = pastedKeys.contains { sample.pasted.range(of: $0).location != NSNotFound } ? 1 : 0
                let range = NSRange(sample.raw.startIndex..., in: sample.raw)
                let raw = includeRaw && rawPatterns.contains { $0.firstMatch(in: sample.raw, range: range) != nil } ? 1 : 0
                return total + pasted + raw
            }
            if count > 0 { result[entry.term] = count }
        }
        return result
    }

    static func select(personal: [Entry], packs: [Entry], organization: [Entry], counts: [String: Int], limit: Int) -> [String] {
        let all = personal + packs + organization
        let used = all.enumerated().filter { (counts[$0.element.term] ?? 0) > 0 }.sorted {
            let a = counts[$0.element.term] ?? 0, b = counts[$1.element.term] ?? 0
            return a == b ? $0.offset < $1.offset : a > b
        }.map { $0.element.term }
        let rest = (personal + packs).map(\.term).filter { (counts[$0] ?? 0) == 0 }
        let aliases = Set(all.flatMap(\.aliases).map(TermRules.aliasKey))
        var selected: [String] = [], length = 0
        for term in TermRules.preferred(used + rest, aliases: aliases) {
            guard length + term.count <= limit else { continue }
            selected.append(term)
            length += term.count + 1
        }
        return selected
    }
}
