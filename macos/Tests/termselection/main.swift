// test-sources: TermSelection.swift TermRules.swift AliasReplace.swift ../../Tests/TestSupport.swift
import Foundation

let target = TermSelection.Entry(term: "Nebulon", aliases: ["~ネブロン"])
let absent = TermSelection.Entry(term: "Zetaron", aliases: ["~ゼタロン"])
let fillers = (0..<30).map { TermSelection.Entry(term: String(format: "Filler%02d", $0), aliases: []) }
let entries = fillers + [target, absent]
let sample = TermSelection.Sample(pasted: "確認してください", raw: "ネブロンを確認してください")
let scores = TermSelection.counts(entries, samples: [sample, sample])
check(scores[target.term] == 2 && scores[absent.term] == nil, "raw-only hints are counted; unseen term is not")
let selected = TermSelection.select(personal: entries, packs: [], organization: [], counts: scores, limit: 120)
check(selected.contains(target.term) && !selected.contains(absent.term), "raw-only term enters a full prompt; absent term stays out")
check(TermSelection.counts([target], samples: [.init(pasted: "Nebulon", raw: "ネブロン ネブロン")])[target.term] == 2, "one hit per channel, not per repeated token")
check(TermSelection.counts([target], samples: [.init(pasted: "", raw: "ネブロンツール")]).isEmpty, "substring guard")
let conditional = TermSelection.Entry(term: "FictionName", aliases: ["~パン粉>さん"])
check(TermSelection.counts([conditional], samples: [.init(pasted: "", raw: "パン粉を買う")]).isEmpty, "honorific condition required")
check(TermSelection.counts([conditional], samples: [.init(pasted: "", raw: "パン粉さん")])[conditional.term] == 1, "honorific condition satisfied")
let short = TermSelection.Entry(term: "Nebulon", aliases: ["~鏡"])
check(TermSelection.counts([short], samples: [.init(pasted: "", raw: "鏡で確認")])[short.term] == 1, "short raw hint counts without replacing")
check(TermSelection.counts([target], samples: [sample] + Array(repeating: .init(pasted: "", raw: ""), count: 300)).isEmpty, "same 300 utterance bound")
let tied = TermSelection.select(personal: [target, absent], packs: [], organization: [], counts: [target.term: 1, absent.term: 1], limit: 7)
check(tied == [target.term], "stable tie and character budget")
let common = TermSelection.Entry(term: "how", aliases: [])
check(TermSelection.select(personal: [common, target], packs: [], organization: [], counts: ["how": 99, target.term: 1], limit: 7) == [target.term], "term quality preference retained")

// Deterministic synthetic replay: select before adding the current utterance (no lookahead).
// No files, model, user history, or transcript output. This is coverage, not ASR accuracy.
var history = [TermSelection.Sample]()
var before = 0, after = 0
for _ in 0..<12 {
    let old = TermSelection.counts(entries, samples: history, includeRaw: false)
    let new = TermSelection.counts(entries, samples: history)
    if TermSelection.select(personal: entries, packs: [], organization: [], counts: old, limit: 120).contains(target.term) { before += 1 }
    if TermSelection.select(personal: entries, packs: [], organization: [], counts: new, limit: 120).contains(target.term) { after += 1 }
    history.append(sample)
}
check(before == 0 && after == 11, "causal replay coverage")
if failures > 0 { exit(1) }
print("termselection: ok; replay utterances=12 before=\(before) after=\(after)")
