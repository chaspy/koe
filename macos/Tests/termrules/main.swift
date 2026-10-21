// test-sources: TermRules.swift AliasLearning.swift ../../Tests/TestSupport.swift
import Foundation

for word in ["how", "HOW", "the", "people", "ハウ", "確認", "ありがとう"] {
    check(TermRules.rejection(word) == .commonWord, "common vocabulary is rejected")
}
for word in ["Example Tool", "Example\tTool", "マージされたら", "マージして", "テストされる", "開発者向け", "ツールを", "ツールね", "テストの準備"] {
    check(TermRules.rejection(word) == .phrase, "phrases and endings are rejected")
}
for word in ["Kubernetes", "クバネティス", "PostgreSQL", "OAuth", "HTTP", "デプロイ"] {
    check(TermRules.rejection(word) == nil, "technical terms remain eligible")
}
let aliases = Set(["~クバネティス", "SomeAlias>(で|を)", "ＷＲＯＮＧ"].map(TermRules.aliasKey))
check(TermRules.rejection("クバネティス", aliases: aliases) == .aliasChain, "memo alias blocks chain")
check(TermRules.rejection("somealias", aliases: aliases) == .aliasChain, "conditional alias blocks chain")
check(TermRules.rejection("wrong", aliases: aliases) == .aliasChain, "case and width normalized")
check(TermRules.rejection("ハウ", aliases: ["ハウ"]) == .aliasChain, "reported chain")
check(TermRules.rejection("Example Name", person: true) == nil, "name rules are preserved")
let batchAliases = Set(["クバネティス", "別ノヨミ"].map(TermRules.aliasKey))
check(TermRules.rejection("クバネティス", aliases: batchAliases) == .aliasChain, "same-batch chain is rejected")
check(TermRules.preferred(["how", "Kubernetes", "ツール向け", "OAuth"], aliases: [])
      == ["Kubernetes", "OAuth", "how", "ツール向け"], "eligible terms precede more-used invalid entries")
check(!TermRules.aliasAllowed("~Kubernetes", existingTerms: ["kubernetes"], person: false), "reverse chain blocked")
check(TermRules.aliasAllowed("Example", existingTerms: ["example"], person: true), "person alias unaffected")
check(TermRules.rejection("Example Tool", existingMultiword: true) == nil, "known multiword alias learning survives")
check(TermRules.rejection("Example Tool") == .phrase, "new multiword term remains rejected")
check(TermRules.rejection("Example Tool", aliases: ["example tool"], existingMultiword: true) == .aliasChain,
      "known multiword term cannot bypass chain guard")
let derived = AliasLearning.variants(term: "Example Security", wrong: "エグザンプルセキュリティスキャン",
                                    termPart: nil, enabled: true)
check(TermRules.rejection("エグザンプルセキュリティ", aliases: Set(derived.map(TermRules.aliasKey))) == .aliasChain,
      "derived aliases block same-batch chains")
if failures > 0 { exit(1) }
print("termrules: ok")
