import Foundation

// Conservative local checks for automatic learning, not a classifier for manual dictionaries.
enum TermRules {
    enum Rejection: String {
        case phrase, commonWord, aliasChain
        var label: String {
            switch self {
            case .phrase: return "句・語尾を含む"
            case .commonWord: return "一般語の可能性"
            case .aliasChain: return "別の語の聞き間違いと重複"
            }
        }
    }

    // Hand-maintained frequent vocabulary; deliberately not a claim of corpus rank.
    private static let commonEnglish = Set("""
    a about above across after again against ago all almost alone along already also although always am
    among an and another any anyone anything are around as ask at away back bad be because become been
    before began begin behind being below best better between big bit black blue body book both boy bring
    brought build built but buy by call came can cannot car care carry case change child children city clear
    close cold come common company complete could country course cut day days did different do does doing
    done door down during each early earth easy eat either else end enough even ever every everyone
    everything example eye face fact family far fast father feel feet few find fine first five follow food
    for form found four free friend from front full get getting girl give given go goes going gone good got
    great green group grow had half hand happen hard has have he head hear heard help her here high him
    himself his home hope hot hour house how however hundred i idea if important in inside instead into
    is it its itself job just keep kind knew know known large last late later learn least leave left less
    let life light like likely line list little live local long look lot love low made make making man many
    may me mean men might mile mind minute miss money month more morning most mother move much must my
    name near need never new next night no nobody none nor north not nothing now number of off often old
    on once one only open or order other our out outside over own page paper part past pay people perhaps
    person place plan play point possible power pretty probably problem put question quite rather reach
    read ready real really red remember rest right room run said same saw say school sea second see seem
    seen sentence set several shall she short should show side since small so some somebody someone
    something sometimes soon sound south space speak special stand start state stay still stop story
    street strong student study such sure system take taken talk tell ten than thank that the their them
    then there these they thing think third this those though thought thousand three through time to
    today together told too took top toward town tree true try turn two under understand until up upon
    us use used useful usually very want war was watch water way we week well went were what when where
    whether which while white who whole whom whose why will wish with within without woman women word
    work world would write wrong year yes yet you young your yourself
    """.split(whereSeparator: \.isWhitespace).map(String.init))
    private static let commonJapanese: Set<String> = [
        "これ", "それ", "あれ", "ここ", "そこ", "こと", "もの", "ため", "よう", "今日", "明日", "昨日",
        "今回", "次回", "自分", "相手", "会社", "仕事", "時間", "確認", "対応", "変更", "追加", "削除",
        "遅延", "返事", "不要", "必要", "普通", "問題", "お願い", "ありがとう", "ハウ", "オハウ",
        "オーケー", "オッケー", "ナイス", "ハロー", "グッド", "ベスト", "ナウ", "ユー", "ミー"
    ]
    private static let endings = [
        "される", "された", "されたら", "されて", "され", "する", "した", "したら", "して", "します",
        "できる", "できた", "ください", "ます", "ません", "でした", "です", "だった", "たら",
        "れば", "ながら", "たい", "ない", "向け", "向き", "用の", "から", "まで", "より", "など",
        "の", "を", "が", "は", "に", "で", "と", "へ", "も", "や", "ね", "よ"
    ]

    static func key(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
    }

    static func aliasKey(_ alias: String) -> String {
        let plain = alias.hasPrefix("~") ? String(alias.dropFirst()) : alias
        return key(String(plain.split(separator: ">", maxSplits: 1).first ?? ""))
    }

    static func isCommonWord(_ word: String) -> Bool {
        commonEnglish.contains(key(word)) || commonJapanese.contains(word)
    }

    static func rejection(_ term: String, aliases: Set<String> = [], person: Bool = false,
                          existingMultiword: Bool = false) -> Rejection? {
        guard (2...20).contains(term.count) else { return .phrase }
        if person { return nil } // Names retain the separate People.judge safeguards.
        let normalized = key(term)
        if aliases.contains(normalized) { return .aliasChain }
        if existingMultiword { return nil } // Only an explicitly enabled, already-known multi-word term.
        if commonEnglish.contains(normalized) || commonJapanese.contains(term) { return .commonWord }
        if term.contains(where: \.isWhitespace) || endings.contains(where: term.hasSuffix)
            || term.rangeOfCharacter(from: CharacterSet(charactersIn: "、。!?！？()（）/／")) != nil {
            return .phrase
        }
        if ["の", "を", "が", "は", "に", "で", "と", "へ", "から", "まで"].contains(where: term.contains) {
            return .phrase
        }
        let hasKanaOrLatin = term.unicodeScalars.contains {
            (0x30A0...0x30FF).contains($0.value) || ($0.isASCII && CharacterSet.alphanumerics.contains($0))
        }
        return hasKanaOrLatin ? nil : .commonWord
    }

    static func aliasAllowed(_ alias: String, existingTerms: Set<String>, person: Bool) -> Bool {
        person || !existingTerms.contains(aliasKey(alias))
    }

    // Stable partition preserves usage ranking within each group.
    static func preferred(_ terms: [String], aliases: Set<String>) -> [String] {
        terms.filter { rejection($0, aliases: aliases) == nil }
            + terms.filter { rejection($0, aliases: aliases) != nil }
    }
}
