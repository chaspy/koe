import Foundation

// whisper の繰り返し（windows/core/text.go と同じ規則）。
// プロンプトに引っ張られて同じ文を繰り返すほか、小さい audio_ctx・温度のフォールバックなしでは
// 短い語や数文字の並びがずっと続くことがある（「ドラフ、ドラフ、…」「ミティミティ…」）
let repeatSentenceMin = 3  // 同じ文（4 文字以上）がどこかに 3 回以上
let repeatWordRun = 5      // 同じ語（、 , 空白 。 などで区切る）が 5 回以上連続
let repeatUnitRun = 6      // 同じ 2〜6 文字の並びが 6 回以上連続（区切りの有無は問わない）
let repeatUnitMin = 2
let repeatUnitMax = 6

private let sentenceEndChars: Set<Character> = ["。", "！", "？", "!", "?", "\n"]
private let wordSepChars: Set<Character> = ["、", ",", "，", "。", " ", "　", "！", "？", "!", "?", "\n"]

func isRepetitive(_ text: String) -> Bool {
    repeatedSentences(text) || wordRun(text) || unitRun(Array(text))
}

private func repeatedSentences(_ text: String) -> Bool {
    var count: [String: Int] = [:]
    for p in text.split(whereSeparator: { sentenceEndChars.contains($0) || $0 == " " }) {
        let k = p.trimmingCharacters(in: .whitespaces)
        if k.count < 4 { continue }
        count[k, default: 0] += 1
        if count[k]! >= repeatSentenceMin { return true }
    }
    return false
}

// 語と、その後ろの区切り
private func splitWords(_ text: String) -> [(word: String, sep: String)] {
    var out: [(word: String, sep: String)] = []
    var w = "", sep = ""
    for ch in text {
        if wordSepChars.contains(ch) { sep.append(ch); continue }
        if !sep.isEmpty { out.append((w, sep)); w = ""; sep = "" }
        w.append(ch)
    }
    if !w.isEmpty || !sep.isEmpty { out.append((w, sep)) }
    return out
}

private func wordRun(_ text: String) -> Bool {
    var run = 0, prev = ""
    for t in splitWords(text) where !t.word.isEmpty {
        if t.word == prev { run += 1 } else { prev = t.word; run = 1 }
        if run >= repeatWordRun { return true }
    }
    return false
}

// i から 6 回以上続く最短の 2〜6 文字の並び（長さ, 回数）。数字だけの並びは数として扱い対象外
private func unitAt(_ r: [Character], _ i: Int) -> (size: Int, count: Int)? {
    var l = repeatUnitMin
    while l <= repeatUnitMax && i + l <= r.count {
        let unit = Array(r[i..<i + l])
        if unit.allSatisfy({ $0.isASCII && $0.isNumber }) { l += 1; continue }
        var n = 1, j = i + l
        while j + l <= r.count && Array(r[j..<j + l]) == unit { n += 1; j += l }
        if n >= repeatUnitRun { return (l, n) }
        l += 1
    }
    return nil
}

private func unitRun(_ r: [Character]) -> Bool {
    r.indices.contains { unitAt(r, $0) != nil }
}

// 繰り返しを 1 回に縮める: 5 回以上続く語は最初の 1 語（区切りは最後のもの）、6 回以上続く並びは 1 つ、
// 3 回以上出た文は 2 回目以降を消す。繰り返しの無い文はそのまま（前後の空白だけ落とす）
func collapseRepeats(_ text: String) -> String {
    var t = collapseUnits(collapseWords(text))
    if repeatedSentences(t) { t = collapseSentences(t) }
    return t.trimmingCharacters(in: .whitespaces)
}

// 前の語が繰り返しの語で終わっている（語の途中から繰り返しが始まった「…ながらドラフ、ドラフ、…」）ときは、
// 繰り返しを丸ごと落として前の語に最後の区切りを付ける
private func collapseWords(_ text: String) -> String {
    let toks = splitWords(text)
    var out: [(word: String, sep: String)] = []
    var i = 0
    while i < toks.count {
        var j = i + 1
        while !toks[i].word.isEmpty && j < toks.count && toks[j].word == toks[i].word { j += 1 }
        if j - i < repeatWordRun {
            out.append(contentsOf: toks[i..<j])
        } else if let last = out.last, last.word.hasSuffix(toks[i].word) {
            out[out.count - 1].sep = toks[j - 1].sep
        } else {
            out.append((toks[i].word, toks[j - 1].sep))
        }
        i = j
    }
    return out.map { $0.word + $0.sep }.joined()
}

private func collapseUnits(_ text: String) -> String {
    let r = Array(text)
    var out = "", i = 0
    while i < r.count {
        if let (l, n) = unitAt(r, i) {
            out += String(r[i..<i + l])
            i += l * n
        } else {
            out.append(r[i])
            i += 1
        }
    }
    return out
}

private func collapseSentences(_ text: String) -> String {
    var seen: [String: Int] = [:]
    var out = "", cur = ""
    func flush(_ sep: String) {
        let k = cur.trimmingCharacters(in: .whitespaces)
        if k.count >= 4 { seen[k, default: 0] += 1 }
        if k.count < 4 || seen[k]! == 1 { out += cur + sep }
        cur = ""
    }
    for ch in text {
        if sentenceEndChars.contains(ch) { flush(String(ch)) } else { cur.append(ch) }
    }
    flush("")
    return out
}

// whisper が雑音や学習データから入れる札・締めの決まり文句（windows/core の StockPhrases と同じ）。
// 発話の途中に出たら読み間違い（実例:「…残っているテストの収募 (音楽)」）。
// 「ありがとうございました」だけは人が言うので入れない
let stockPhrases = [
    "(音楽)", "（音楽）", "[音楽]", "(拍手)", "（拍手）", "[拍手]", "(笑)", "[笑]",
    "[BLANK_AUDIO]", "[blank_audio]", "(字幕)", "ご視聴ありがとうございました",
]

func hasStockPhrase(_ text: String) -> Bool {
    stockPhrases.contains { text.contains($0) }
}

// 決まり文句（「ご視聴ありがとうございました」の直後の「。」も）を取り除き、残った空白を整える
func removeStockPhrases(_ text: String) -> String {
    var t = text
    for p in stockPhrases {
        t = t.replacingOccurrences(of: p + "。", with: "").replacingOccurrences(of: p, with: "")
    }
    return t.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
}
