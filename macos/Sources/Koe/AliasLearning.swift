import Foundation

// Opt-in alias derivation. Names with honorifics keep their separate People rules.
enum AliasLearning {
    private static let genericSuffixes = [
        ("スキャン", "scan"), ("ツール", "tool"), ("サーバー", "server"),
        ("サーバ", "server"), ("アプリ", "app"), ("サービス", "service")
    ]

    static func isCommon(_ alias: String) -> Bool {
        alias.count <= 3 || TermRules.isCommonWord(alias) || !alias.unicodeScalars.contains {
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

    // Count each literal alias once per utterance, never duplicate LLM rows or inferred variants.
    static func observedCounts(term: String, aliases: [String], index: Int?, transcripts: [Int: String],
                               previous: [String: Int], seen: inout Set<String>) -> [String: Int] {
        guard let index, let transcript = transcripts[index] else { return previous }
        var counts = previous
        for alias in aliases {
            let plain = alias.hasPrefix("~") ? String(alias.dropFirst()) : alias
            let key = "\(term)\u{0}\(plain)\u{0}\(index)"
            guard !seen.contains(key), AliasReplace.apply(transcript, wrong: plain, right: plain).hit else { continue }
            seen.insert(key)
            counts[plain, default: 0] += 1
        }
        return counts
    }

    static func merged(existing: [String], learned: [String]) -> [String] {
        let definite = Set(learned.filter { !$0.hasPrefix("~") })
        return Array(Set(existing.filter { !$0.hasPrefix("~") || !definite.contains(String($0.dropFirst())) } + learned)).sorted()
    }

    static func stored(_ aliases: [String], sure: Bool, anchored: Bool, person: Bool,
                       ordinaryWordNotes: Bool, observations: [String: Int] = [:], englishWords: Set<String>? = nil) -> [String] {
        var result: [String] = []
        for alias in aliases {
            let plain = alias.hasPrefix("~") ? String(alias.dropFirst()) : alias
            let asciiWord = plain.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.letters.contains($0) }
            let common = isCommon(plain) || (asciiWord && (englishWords?.contains(plain.lowercased()) ?? true))
            // Option (a): new ordinary-word aliases are opt-in and always memo-only.
            if !person && common && !ordinaryWordNotes { continue }
            let repeated = !person && (observations[plain] ?? 0) >= 2
            let replace = (sure || anchored || repeated) && !common && (!person || plain.contains(">"))
            let value = replace && (!alias.hasPrefix("~") || repeated) ? plain : "~" + plain
            if !result.contains(value) { result.append(value) }
        }
        return result
    }
}

// System vocabulary only; no user dictionary or history. Missing vocabulary fails conservatively for English aliases.
enum AliasVocabulary {
    static let englishWords: Set<String>? = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return nil }
        return Set(text.split(whereSeparator: \.isNewline).map { $0.lowercased() })
    }()
}
