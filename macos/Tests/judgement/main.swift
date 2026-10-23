// test-sources: ImprovementJudgement.swift
import Foundation
let fixtures: [[String: Any]] = [
    ["error": false, "read_ok": true, "unknown": false],
    ["error": true, "read_ok": true, "unknown": false],
    ["error": true, "read_ok": false, "impact": "redo", "unknown": false],
    ["unknown": true]
]
let labels = ["understood", "understood", "corrected", "unclear"]
for (i, j) in fixtures.enumerated() {
    precondition(ImprovementJudgement.label(j) == labels[i])
    let f = ImprovementJudgement.fields(j, at: "2026-10-23T00:00:00Z")
    precondition(f["judged_at"] as? String == "2026-10-23T00:00:00Z")
    if i < 3 {
        precondition(f["asr_error"] as? Bool == (i != 0))
        precondition(f["read_ok"] as? Bool == (i != 2))
    } else {
        precondition(f["asr_error"] == nil && f["read_ok"] is NSNull)
        precondition(f["unknown"] as? Bool == true)
    }
    precondition(i == 2 ? f["impact"] as? String == "redo" : f["impact"] is NSNull)
    precondition(JSONSerialization.isValidJSONObject(f))
}
precondition(ImprovementJudgement.counts(fixtures + [["reason": "fixture-only"]], termsAdded: 2) ==
    ["judged": 4, "asr_error": 2, "not_understood": 1, "unclear": 1, "terms_added": 2])
precondition(ImprovementJudgement.label(["label": "corrected"]) == "corrected")
precondition(ImprovementJudgement.fields(["label": "corrected"], at: "fixture")["asr_error"] == nil)
print("judgement: ok")
var record: [String: Any] = ["prompt_terms": ["FixtureTerm"]]
ImprovementJudgement.recordPrompt("fixture", in: &record)
precondition(record["prompt_terms"] as? [String] == ["FixtureTerm"])
ImprovementJudgement.recordPrompt("", in: &record)
precondition(record["prompt_terms"] as? [String] == [])
var pairCount = 0
for index in [nil, 0, 1] as [Int?] {
    ImprovementJudgement.reportPair(index: index, transcripts: [0: "FixtureWrong"], wrong: "FixtureWrong", right: "FixtureRight") { _, _, _ in pairCount += 1 }
}
precondition(pairCount == 1)
