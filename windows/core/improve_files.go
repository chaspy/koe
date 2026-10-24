package core

// Reading and writing the files of the improvement loop (#184): the history
// records it sends and marks, and the term candidates. Kept here, next to the
// pure rules in improve.go, so that they can be tested with a temporary folder.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// ImproveDays is how many day folders of history the loop looks at (macOS: 7).
const ImproveDays = 7

// LoadImproveItems reads the records of the newest ImproveDays day folders of
// the history. It returns them with the path of each record, by id.
func LoadImproveItems(dir string) ([]ImproveItem, map[string]string) {
	var items []ImproveItem
	paths := map[string]string{}
	for _, day := range recentDayFolders(dir, ImproveDays) {
		files, _ := os.ReadDir(filepath.Join(dir, day))
		for _, f := range files {
			if !strings.HasSuffix(f.Name(), ".json") {
				continue
			}
			path := filepath.Join(dir, day, f.Name())
			if r, ok := readRecord(path); ok {
				id := strings.TrimSuffix(f.Name(), ".json")
				items = append(items, ImproveItem{ID: id, Record: r})
				paths[id] = path
			}
		}
	}
	return items, paths
}

// recentDayFolders lists the newest n YYYY-MM-DD folders of the history, oldest first.
func recentDayFolders(dir string, n int) []string {
	entries, _ := os.ReadDir(dir)
	var names []string
	for _, d := range entries {
		if d.IsDir() && len(d.Name()) == 10 {
			names = append(names, d.Name())
		}
	}
	sort.Strings(names)
	if len(names) > n {
		names = names[len(names)-n:]
	}
	return names
}

func readRecord(path string) (map[string]any, bool) {
	b, err := os.ReadFile(filepath.Clean(path))
	if err != nil {
		return nil, false
	}
	var r map[string]any
	return r, json.Unmarshal(b, &r) == nil
}

// ImproveMarked is what MarkImproveItems did: how many were judged and corrected, and
// the judgements that were saved (for ImproveJudgedCounts).
type ImproveMarked struct {
	Judged, Corrected int
	Saved             []map[string]any
}

// MarkImproveItems writes the judgements of an answer into the records of the
// batch (by position i), with the whole judgement (ImproveJudgementFields, judged
// at `at`) and the mishearings found in each utterance, and marks every record as
// scanned, so it is not sent again. Each record is replaced atomically.
func MarkImproveItems(paths map[string]string, batch []ImproveItem, a ImproveAnswer, at string) ImproveMarked {
	byIndex := judgementsByIndex(a.Judgements)
	pairs := ImproveMishearings(batch, a.Terms)
	var m ImproveMarked
	for i, it := range batch {
		rec := map[string]any{}
		for k, v := range it.Record {
			rec[k] = v
		}
		if label := applyJudgement(rec, byIndex[i]); label != "" {
			delete(rec, "asr_error")
			for k, v := range ImproveJudgementFields(byIndex[i], at) {
				rec[k] = v
			}
			m.Judged++
			if label == "corrected" {
				m.Corrected++
			}
			m.Saved = append(m.Saved, byIndex[i])
		}
		found := pairs[i]
		if found == nil {
			found = []map[string]string{} // [] rather than null: "looked, none found"
		}
		rec["mishearings"] = found
		rec["glossary_scanned"] = true
		if path, ok := paths[it.ID]; ok {
			_ = writeJSONAtomic(path, rec)
		}
	}
	return m
}

func writeJSONAtomic(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func judgementsByIndex(js []map[string]any) map[int]map[string]any {
	out := map[int]map[string]any{}
	for _, j := range js {
		if i, ok := j["i"].(float64); ok {
			out[int(i)] = j
		}
	}
	return out
}

// applyJudgement writes the label (and the reason and impact) into rec; "" when there is none.
func applyJudgement(rec, j map[string]any) string {
	label := ImproveLabel(j)
	if j == nil || label == "" {
		return ""
	}
	rec["communication"] = label
	if reason, _ := j["reason"].(string); reason != "" {
		rec["communication_note"] = reason
	}
	delete(rec, "communication_impact")
	if label == "corrected" {
		rec["communication_impact"] = ImproveImpact(j)
	}
	return label
}

// ReadTermCandidates reads the counts kept between runs (empty when missing or unreadable).
func ReadTermCandidates(path string) map[string]TermCandidate {
	cand := map[string]TermCandidate{}
	if b, err := os.ReadFile(filepath.Clean(path)); err == nil {
		_ = json.Unmarshal(b, &cand)
	}
	return cand
}

// WriteTermCandidates saves the counts.
func WriteTermCandidates(path string, cand map[string]TermCandidate) error {
	b, err := json.MarshalIndent(cand, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o600)
}

// ShouldRunImprove: run when the loop is on, nothing is being recorded or
// transcribed, and enough new utterances are waiting (any when forced).
func ShouldRunImprove(enabled, busy bool, pending, batch int, force bool) bool {
	if !enabled || busy || pending == 0 {
		return false
	}
	return force || pending >= batch
}
