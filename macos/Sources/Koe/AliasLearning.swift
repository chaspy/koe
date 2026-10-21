import Foundation

// Opt-in alias derivation. Names with honorifics keep their separate People rules.
enum AliasLearning {
    private static let genericSuffixes = [
        ("スキャン", "scan"), ("ツール", "tool"), ("サーバー", "server"),
        ("サーバ", "server"), ("アプリ", "app"), ("サービス", "service")
    ]

    static func isCommon(_ alias: String) -> Bool {
        alias.count <= 3 || !alias.unicodeScalars.contains {
            (0x30A0...0x30FF).contains($0.value) || (CharacterSet.letters.contains($0) && $0.isASCII)
        }
    }

    static func existingMultiword(_ term: String, knownTerms: Set<String>, enabled: Bool) -> Bool {
        enabled && knownTerms.contains(term) && term.split(whereSeparator: \.isWhitespace).count > 1
    }

    static func variants(term: String, wrong: String, termPart: String?, enabled: Bool) -> [String] {
        guard enabled, !wrong.hasPrefix("~"), !wrong.contains(">") else { return [wrong] }
        var aliases = [wrong]
        // An explicit term boundary must be a substantial, literal prefix of the observed alias.
        if let part = termPart, part.count >= 4, part.count < wrong.count,
           wrong.hasPrefix(part), !part.contains(where: \.isWhitespace), !isCommon(part) {
            aliases.append(part)
        }
        if term.split(whereSeparator: \.isWhitespace).count > 1 {
            let lower = term.lowercased()
            for (suffix, english) in genericSuffixes where wrong.hasSuffix(suffix) {
                // Do not remove a generic word that belongs to the actual term itself.
                guard !lower.hasSuffix(english), !term.hasSuffix(suffix) else { continue }
                let short = String(wrong.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                if short.count >= 4, !isCommon(short), !aliases.contains(short) { aliases.append(short) }
            }
        }
        return aliases
    }

    static func stored(_ aliases: [String], sure: Bool, anchored: Bool, person: Bool,
                       ordinaryWordNotes: Bool) -> [String] {
        var result: [String] = []
        for alias in aliases {
            let plain = alias.hasPrefix("~") ? String(alias.dropFirst()) : alias
            // Option (a): new ordinary-word aliases are opt-in and always memo-only.
            if !person && isCommon(plain) && !ordinaryWordNotes { continue }
            let replace = (sure || anchored) && !isCommon(plain) && (!person || plain.contains(">"))
            let value = replace && !alias.hasPrefix("~") ? plain : "~" + plain
            if !result.contains(value) { result.append(value) }
        }
        return result
    }
}
