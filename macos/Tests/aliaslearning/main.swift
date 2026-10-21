// test-sources: AliasLearning.swift AliasReplace.swift ../../Tests/TestSupport.swift
import Foundation

let term = "Example Security"
let long = "エグザンプルセキュリティスキャン"
let short = "エグザンプルセキュリティ"
check(AliasLearning.variants(term: term, wrong: long, termPart: nil, enabled: false) == [long], "default off")
check(AliasLearning.variants(term: term, wrong: long, termPart: nil, enabled: true) == [long, short], "generic suffix trimmed")
check(AliasLearning.variants(term: term, wrong: short, termPart: short, enabled: true) == [short], "deduplication")
check(AliasLearning.variants(term: "Example Scan", wrong: "エグザンプルスキャン", termPart: nil, enabled: true)
      == ["エグザンプルスキャン"], "suffix belonging to term retained")
check(AliasLearning.variants(term: "Example", wrong: "エグザンプル追加", termPart: "エグザンプル", enabled: true)
      == ["エグザンプル追加", "エグザンプル"], "explicit term boundary")
check(AliasLearning.variants(term: term, wrong: long, termPart: "別ノヨミ", enabled: true) == [long, short], "non-prefix rejected")
check(AliasLearning.variants(term: "Example", wrong: "鏡ツール", termPart: "鏡", enabled: true) == ["鏡ツール"], "unsafe short prefix rejected")
check(AliasLearning.variants(term: "Example", wrong: "エグザンプル>さん", termPart: "エグザンプル", enabled: true)
      == ["エグザンプル>さん"], "conditional aliases unchanged")
check(AliasLearning.existingMultiword(term, knownTerms: [term], enabled: true), "known multiword term can gain aliases")
check(!AliasLearning.existingMultiword(term, knownTerms: [], enabled: true), "no new multiword phrase")
let off = AliasLearning.stored(["鏡"], sure: true, anchored: false, person: false, ordinaryWordNotes: false)
let on = AliasLearning.stored(["鏡"], sure: true, anchored: false, person: false, ordinaryWordNotes: true)
check(off.isEmpty, "ordinary word notes default off")
check(on == ["~鏡"], "ordinary word always memo-only")
for text in ["鏡で確かめて PR を出す", "鏡を見る"] {
    var output = text
    for alias in on where !alias.hasPrefix("~") { output = AliasReplace.apply(output, wrong: alias, right: "Example").text }
    check(output == text, "option a never replaces ordinary words")
}
check(AliasLearning.stored(["パン粉>さん"], sure: true, anchored: true, person: true, ordinaryWordNotes: false)
      == ["パン粉>さん"], "person safety unchanged")
let learned = AliasLearning.stored([long, short], sure: true, anchored: false, person: false, ordinaryWordNotes: false)
check(learned == [long, short], "both unambiguous aliases learned")
check(AliasReplace.apply(short, wrong: learned[1], right: term).text == term, "standalone short alias is corrected")
if failures > 0 { exit(1) }
print("aliaslearning: ok")
