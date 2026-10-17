// make test: Sources/Koe/People.swift の単体テスト。改善ループの LLM の返り値を固定して、人の名前を辞書に足す／足さないを確かめる。
// 名簿は架空の人（実在の社員の名前は使わない）
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

let tsv = """
# Slack の ID と本名の対応表
# 1 行 1 つ: <ID><TAB><本名>

panko\t山田 花子
yamapi\t山下 智
  \t空の ID
bad line without tab
"""
let people = People.parse(tsv)
check(people == [.init(id: "panko", name: "山田 花子"), .init(id: "yamapi", name: "山下 智")], "parse: \(people)")

func judge(_ wrong: String, _ right: String, who: String? = nil, explicit: Bool = false, confidence: String? = "high",
           transcript: String, context: String = "") -> People.Decision {
    People.judge(.init(wrong: wrong, right: right, who: who, explicit: explicit, confidence: confidence,
                       transcript: transcript, context: context), people: people)
}
func added(_ d: People.Decision) -> People.Accepted? { if case .add(let a) = d { return a }; return nil }

// 足す: 「〜さん」付きで、前後に Slack・レビューの文脈がある
let ok = judge("パン粉さん", "panko", who: "panko", transcript: "パン粉さんに聞いてみて", context: "Slack でレビューを頼みました")
check(added(ok) == .init(term: "panko", alias: "パン粉>さん", who: "panko", called: "pankoさん"), "add with honorific and context: \(ok)")
// LLM が敬称を落として返しても、文字起こしに敬称が続いていれば足す（別名は敬称つきの条件にする）
let ok2 = judge("パン粉", "panko", who: "panko", transcript: "パン粉さんの PR を見て")
check(added(ok2)?.alias == "パン粉>さん", "honorific from transcript: \(ok2)")
// who が無くても、正しい表記が名簿の ID なら誰か分かる
check(added(judge("パン粉さん", "panko", transcript: "パン粉さんにメンションして"))?.who == "panko", "who from id")

// 足さない: 普通の語（敬称なし）
check(judge("パン粉", "panko", who: "panko", transcript: "パン粉を買ってきて", context: "Slack で頼まれた") == .skip(.noHonorific), "common word")
// 足さない: 敬称はあるが、人とのやりとりの文脈が無い
check(judge("パン粉さん", "panko", who: "panko", transcript: "パン粉さんのお店でパンを買った") == .skip(.noContext), "no context")
// 足さない: LLM の確度が high でない
check(judge("パン粉さん", "panko", who: "panko", confidence: "medium", transcript: "パン粉さんに Slack で聞いて") == .skip(.lowConfidence), "low confidence")
check(judge("パン粉さん", "panko", who: "panko", confidence: nil, transcript: "パン粉さんに Slack で聞いて") == .skip(.lowConfidence), "no confidence")
// 足さない: 化けた形が文字起こしに無い
check(judge("パンコさん", "panko", transcript: "パン粉さんに Slack で聞いて") == .skip(.notInTranscript), "not in transcript")
// 足さない: わざと言ったあだ名を本名に書き換える
check(judge("やまぴーさん", "山下", who: "yamapi", transcript: "やまぴーさんにレビュー頼んで") == .skip(.nicknameToRealName), "nickname to surname")
check(judge("やまぴーさん", "山下 智", who: "yamapi", transcript: "やまぴーさんにレビュー頼んで") == .skip(.nicknameToRealName), "nickname to full name")
check(judge("やまぴーさん", "山下智さん", who: "yamapi", transcript: "やまぴーさんにレビュー頼んで") == .skip(.nicknameToRealName), "nickname to full name without space")
// 足す: 名字の化け（同じ読みの別の字）→ 本名の名字
let sur = judge("山舌さん", "山下", who: "yamapi", transcript: "山舌さんにレビューをお願いして")
check(added(sur) == .init(term: "山下", alias: "山舌>さん", who: "yamapi", called: "山下さん"), "surname misrecognition: \(sur)")
// 足さない: 漢字の形でも、その人の既知の呼び方（わざとそう呼んでいる）なら本名に書き換えない
check(People.judge(.init(wrong: "山舌さん", right: "山下", who: "yamapi", confidence: "high", transcript: "山舌さんにレビューをお願いして"),
                   people: people, knownCalled: ["yamapi": ["山舌さん"]]) == .skip(.nicknameToRealName), "known calling form")
// 足さない: 化けていない（名簿の ID・本名がそのまま出ている）
check(judge("yamapiさん", "panko", transcript: "yamapiさんに Slack で") == .skip(.alreadyCorrect), "already an id")
check(judge("山田さん", "panko", transcript: "山田さんに Slack で") == .skip(.alreadyCorrect), "already a name")
// 足さない: 名簿にいない人
check(judge("パン粉さん", "panko", who: "nobody", transcript: "パン粉さんに Slack で") == .skip(.unknownPerson), "unknown who")
// 足さない: 語ではないもの
check(judge("パン粉さん、あの", "panko", transcript: "パン粉さん、あの Slack") == .skip(.badForm), "phrase")

// 近い読みの形（IMP-8）: 1 回検出したら、LLM が出した近い読みの形も「形>敬称」の別名に足す
func judgeV(_ wrong: String, _ right: String, who: String? = nil, confidence: String? = "high", transcript: String,
            context: String = "", variants: [String], knownCalled: [String: [String]] = [:]) -> People.Decision {
    People.judge(.init(wrong: wrong, right: right, who: who, confidence: confidence, transcript: transcript, context: context,
                       variants: variants), people: people, knownCalled: knownCalled)
}
let v = judgeV("パン粉さん", "panko", who: "panko", transcript: "パン粉さんに Slack で聞いて",
               variants: ["パンコ", "パンコアさん", "バンコ", " パンコ ", "パン粉"])
check(added(v)?.alias == "パン粉>さん" && added(v)?.variants == ["パンコ>さん", "パンコア>さん", "バンコ>さん"], "variants: \(v)")
// 別名はどれも敬称の条件つきなので、普通の語（「パン粉を買う」「パンコアの粉」）は置き換わらない。敬称が無ければ variants も足さない
check(judgeV("パン粉", "panko", who: "panko", transcript: "パン粉を買う", context: "Slack で頼まれた", variants: ["パンコ"]) == .skip(.noHonorific),
      "variants, common word")
check((added(v).map { [$0.alias] + $0.variants } ?? []).allSatisfy { $0.hasSuffix(">さん") }, "variants anchored by honorific")
func corrected(_ text: String, _ a: People.Accepted) -> String {
    ([a.alias] + a.variants).reduce(text) { AliasReplace.apply($0, wrong: $1, right: a.term).text }
}
if let a = added(v) {
    check(corrected("パンコアさんにレビューを頼んで", a) == "pankoさんにレビューを頼んで", "variant replaces: \(corrected("パンコアさんにレビューを頼んで", a))")
    check(corrected("パンコさんとバンコさん", a) == "pankoさんとpankoさん", "variants replace")
    check(corrected("パン粉を買う", a) == "パン粉を買う" && corrected("パンコアの粉", a) == "パンコアの粉", "common words unchanged")
}
// 確度 high でないときは variants も足さない（判定そのものが通らない）。本人が示した explicit でも、確度 high でなければ variants は足さない
check(judgeV("パン粉さん", "panko", who: "panko", confidence: "medium", transcript: "パン粉さんに Slack で", variants: ["パンコ"]) == .skip(.lowConfidence),
      "variants, low confidence")
let exV = People.judge(.init(wrong: "パン粉さん", right: "panko", who: "panko", explicit: true, transcript: "パン粉さんに送って",
                             variants: ["パンコ"]), people: people)
check(added(exV) != nil && added(exV)!.variants.isEmpty, "explicit without confidence adds no variants: \(exV)")
// 本人が示した explicit でも、敬称が無ければ variants は足さない（別名が敬称の条件つきにならないため）
let exV2 = People.judge(.init(wrong: "パン粉", right: "panko", who: "panko", explicit: true, confidence: "high", transcript: "パン粉に送って",
                              variants: ["パンコ"]), people: people)
check(added(exV2)?.alias == "パン粉" && added(exV2)!.variants.isEmpty, "explicit without honorific adds no variants: \(exV2)")
// 名簿の ID・本名そのもの（化けていない）や、既知の呼び方は別名にしない
let vr = judgeV("パン粉さん", "panko", who: "panko", transcript: "パン粉さんに Slack で聞いて",
                variants: ["panko", "PANKO", "山田", "山田花子", "山田 花子", "yamapi", "やまぴー", "パンコ"],
                knownCalled: ["yamapi": ["やまぴーさん"]])
check(added(vr)?.variants == ["パンコ>さん"], "variants exclude roster names and known calls: \(vr)")
// 本名に対するひらがな・カタカナ・英字だけの形は、わざと言ったあだ名かもしれないので別名にしない（漢字の化けは足す）
let vs = judgeV("山舌さん", "山下", who: "yamapi", transcript: "山舌さんにレビューをお願いして", variants: ["ヤマシタ", "やました", "山舌", "山志多"])
check(added(vs)?.variants == ["山志多>さん"], "variants for a real name: \(vs)")
// 最大 5 つ。区切りの文字・長すぎる形・1 文字は入れない
let vm = judgeV("パン粉さん", "panko", who: "panko", transcript: "パン粉さんに Slack で聞いて",
                variants: ["パ", "パンコ／パンコア", "パン>コ", "あいうえおかきくけこさしすせそた", "パンコ", "パンコア", "バンコ", "パンコー", "ハンコ", "パンゴ"])
check(added(vm)?.variants.count == 5 && added(vm)?.variants.first == "パンコ>さん", "variants max 5: \(vm)")

// 本人が正しい表記を示した（explicit）なら、敬称・文脈が無くても足す。本名でもよい（本人がそう呼んだ）
let ex = judge("パン粉", "panko", who: "panko", explicit: true, confidence: nil, transcript: "パン粉に送って")
check(added(ex) == .init(term: "panko", alias: "パン粉", who: "panko", called: "pankoさん"), "explicit: \(ex)")
check(added(judge("八万田さん", "山田", who: "panko", explicit: true, transcript: "八万田さんに")) != nil, "explicit real name")

// 名簿が無い（peopleSources 未設定）ときも、敬称と文脈の条件は同じ
let none = People.judge(.init(wrong: "パン粉さん", right: "panko", confidence: "high", transcript: "パン粉さんに Slack で聞いて"), people: [])
check(added(none)?.alias == "パン粉>さん", "no people: \(none)")
check(People.judge(.init(wrong: "パン粉", right: "panko", confidence: "high", transcript: "パン粉を買う"), people: []) == .skip(.noHonorific), "no people, common word")

// kind: "term" で返ってきても、名簿の人なら人の判定に回す
check(People.isPersonName("panko", people) && People.isPersonName("山田さん", people) && !People.isPersonName("パン粉", people), "isPersonName")

// 呼び方（あだ名）は koe-people.md に書くだけ。敬称つきで実際に出てきたときだけ
check(People.judgeCalled(.init(called: "やまぴー", who: "yamapi", confidence: "high", transcript: "やまぴーさんに聞いて"), people: people)! == ("yamapi", "やまぴーさん"), "called")
check(People.judgeCalled(.init(called: "やまぴー", who: "yamapi", confidence: "low", transcript: "やまぴーさんに聞いて"), people: people) == nil, "called low")
check(People.judgeCalled(.init(called: "やまぴー", who: "nobody", confidence: "high", transcript: "やまぴーさんに聞いて"), people: people) == nil, "called unknown")
check(People.judgeCalled(.init(called: "やまぴー", who: "yamapi", confidence: "high", transcript: "やまぴーの歌"), people: people) == nil, "called without honorific")

// LLM に渡す名簿・受け取る AI 向けの一覧
check(People.promptBlock(people) == "panko\t山田 花子\nyamapi\t山下 智", "promptBlock")
let note = People.receiverNote(people, called: ["yamapi": ["やまぴーさん"]], wrongs: ["panko": ["パン粉さん"]])
check(note.contains("panko\t山田 花子\t\tパン粉さん\n") && note.contains("yamapi\t山下 智\tやまぴーさん\n"), "receiverNote:\n\(note)")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("people: ok")
