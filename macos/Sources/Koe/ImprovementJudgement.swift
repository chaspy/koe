import Foundation

// LLM の回答を履歴用に正規化。本文・理由・語をイベントへ渡さない。
enum ImprovementJudgement {
    static func reportPair(index: Int?, transcripts: [Int: String], wrong: String, right: String,
                           report: (Int, String, String) -> Void) {
        guard let index, transcripts[index]?.contains(wrong) == true else { return }
        report(index, wrong, right)
    }

    static func recordPrompt(_ prompt: String, in record: inout [String: Any]) {
        if prompt.isEmpty { record["prompt_terms"] = [String]() }
    }

    static func label(_ j: [String: Any]) -> String? {
        if j["unknown"] as? Bool == true { return "unclear" }
        if let error = j["error"] as? Bool {
            return !error || j["read_ok"] as? Bool == true ? "understood" : "corrected"
        }
        return (j["label"] as? String).flatMap { ["understood", "corrected", "unclear"].contains($0) ? $0 : nil }
    }

    static func fields(_ j: [String: Any], at: String) -> [String: Any] {
        var result: [String: Any] = ["read_ok": j["read_ok"] as? Bool as Any? ?? NSNull(),
                                    "unknown": j["unknown"] as? Bool ?? (label(j) == "unclear"),
                                    "judged_at": at]
        if let error = j["error"] as? Bool { result["asr_error"] = error }
        result["impact"] = (j["impact"] as? String).flatMap {
            ["misacted", "redo", "dropped"].contains($0) ? $0 : nil
        } as Any? ?? NSNull()
        return result
    }

    static func counts(_ judgements: [[String: Any]], termsAdded: Int) -> [String: Int] {
        let valid = judgements.filter { label($0) != nil }
        return ["judged": valid.count, "asr_error": valid.filter { $0["error"] as? Bool == true }.count,
                "not_understood": valid.filter { label($0) == "corrected" }.count,
                "unclear": valid.filter { label($0) == "unclear" }.count, "terms_added": termsAdded]
    }
}
