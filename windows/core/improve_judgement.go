package core

// Keeping the whole judgement of the improvement loop (#184, macOS #223 / #225,
// ImprovementJudgement.swift): whether whisper misheard (asr_error), whether
// the receiving AI still read it right (read_ok), how bad it was (impact), the
// judged-at time, and the wrong → right pairs found in each utterance. These go
// into the history record only (it already holds the transcript); the log gets
// counts and never words.

import "strings"

// ImproveJudgementFields are the fields written into a history record for one judgement.
// read_ok and impact are null when the answer did not give a usable value; asr_error is
// only written when the answer had error (older answers with only a label do not).
func ImproveJudgementFields(j map[string]any, at string) map[string]any {
	out := map[string]any{"read_ok": nil, "unknown": ImproveLabel(j) == "unclear", "judged_at": at, "impact": nil}
	if v, ok := j["read_ok"].(bool); ok {
		out["read_ok"] = v
	}
	if v, ok := j["unknown"].(bool); ok {
		out["unknown"] = v
	}
	if e, ok := j["error"].(bool); ok {
		out["asr_error"] = e
	}
	switch v, _ := j["impact"].(string); v {
	case "misacted", "redo", "dropped":
		out["impact"] = v
	}
	return out
}

// ImproveJudgedCounts is the one summary of a run for the log (improve_judged): numbers only.
func ImproveJudgedCounts(judgements []map[string]any, termsAdded int) map[string]int {
	c := map[string]int{"judged": 0, "asr_error": 0, "not_understood": 0, "unclear": 0, "terms_added": termsAdded}
	for _, j := range judgements {
		label := ImproveLabel(j)
		if label == "" {
			continue
		}
		c["judged"]++
		if j["error"] == true {
			c["asr_error"]++
		}
		switch label {
		case "corrected":
			c["not_understood"]++
		case "unclear":
			c["unclear"]++
		}
	}
	return c
}

// ImproveMishearings is, per utterance of the batch, the wrong → right pairs of the
// answer that pass the same rules as the glossary (improveTermPair) and whose wrong
// form is really in that utterance's transcript (macOS reportPair). No duplicates.
func ImproveMishearings(batch []ImproveItem, terms []map[string]any) map[int][]map[string]string {
	out := map[int][]map[string]string{}
	for _, t := range terms {
		i, ok := t["i"].(float64)
		if !ok || int(i) < 0 || int(i) >= len(batch) {
			continue
		}
		right, wrong, ok := improveTermPair(t)
		raw, _ := batch[int(i)].Record["raw"].(string)
		if !ok || !strings.Contains(raw, wrong) {
			continue
		}
		pair := map[string]string{"wrong": wrong, "right": right}
		dup := false
		for _, p := range out[int(i)] {
			dup = dup || p["wrong"] == wrong && p["right"] == right
		}
		if !dup {
			out[int(i)] = append(out[int(i)], pair)
		}
	}
	return out
}
