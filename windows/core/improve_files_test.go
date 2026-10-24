package core

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func writeRecord(t *testing.T, dir, id string, r map[string]any) string {
	t.Helper()
	day := filepath.Join(dir, id[:10])
	if err := os.MkdirAll(day, 0o750); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(r)
	p := filepath.Join(day, id+".json")
	if err := os.WriteFile(p, b, 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// eightDays writes one record per day for 10/10..10/17 and a broken file.
func eightDays(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for d := 10; d <= 17; d++ {
		writeRecord(t, dir, fmt.Sprintf("2026-10-%02dT09-00-00-000", d), map[string]any{"raw": fmt.Sprintf("日 %d", d), "outcome": "pasted"})
	}
	if err := os.WriteFile(filepath.Join(dir, "2026-10-17", "broken.json"), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

func readJSON(t *testing.T, path string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(filepath.Clean(path))
	if err != nil {
		t.Fatal(err)
	}
	var r map[string]any
	_ = json.Unmarshal(b, &r)
	return r
}

func TestLoadImproveItemsReadsTheNewestSevenDays(t *testing.T) {
	items, paths := LoadImproveItems(eightDays(t))
	if len(items) != 7 || len(paths) != 7 {
		t.Fatal(len(items), len(paths))
	}
	if _, ok := paths["2026-10-10T09-00-00-000"]; ok {
		t.Fatal("the 8th day back is not read")
	}
}

func TestMarkImproveItems(t *testing.T) {
	dir := eightDays(t)
	items, paths := LoadImproveItems(dir)
	batch := ImproveBatch(items)[:3]
	ans := ImproveAnswer{Judgements: []map[string]any{
		{"i": float64(0), "error": false, "reason": "ok"},
		{"i": float64(1), "error": true, "read_ok": false, "impact": "misacted"},
		// [2] has no judgement: still marked as scanned, without a label
	}}
	if m := MarkImproveItems(paths, batch, ans, "2026-10-25T01:00:00Z"); m.Judged != 2 || m.Corrected != 1 || len(m.Saved) != 2 {
		t.Fatal(m)
	}
	r0, r1, r2 := readJSON(t, paths[batch[0].ID]), readJSON(t, paths[batch[1].ID]), readJSON(t, paths[batch[2].ID])
	if r0["communication"] != "understood" || r0["communication_note"] != "ok" || r0["glossary_scanned"] != true || r0["raw"] == nil {
		t.Fatal(r0)
	}
	if r1["communication"] != "corrected" || r1["communication_impact"] != "misacted" {
		t.Fatal(r1)
	}
	if _, ok := r2["communication"]; ok || r2["glossary_scanned"] != true {
		t.Fatal(r2)
	}
	// scanned records are not sent again
	items, _ = LoadImproveItems(dir)
	if n := len(ImproveBatch(items)); n != 4 {
		t.Fatal(n)
	}
}

// The whole judgement is kept (#223): misheard or not, read right or not, the time, and the pairs.
func TestMarkImproveItemsKeepsJudgement(t *testing.T) {
	dir := eightDays(t)
	items, paths := LoadImproveItems(dir)
	batch := ImproveBatch(items)[:3]
	raw, _ := batch[1].Record["raw"].(string)
	ans := ImproveAnswer{
		Judgements: []map[string]any{
			{"i": float64(0), "error": false},
			{"i": float64(1), "error": true, "read_ok": false, "impact": "misacted"},
		},
		Terms: []map[string]any{{"i": float64(1), "wrong": raw, "right": "Terraform"}},
	}
	MarkImproveItems(paths, batch, ans, "2026-10-25T01:00:00Z")
	r0, r1, r2 := readJSON(t, paths[batch[0].ID]), readJSON(t, paths[batch[1].ID]), readJSON(t, paths[batch[2].ID])
	if r0["asr_error"] != false || r0["judged_at"] != "2026-10-25T01:00:00Z" || r0["read_ok"] != nil || r0["unknown"] != false {
		t.Fatal(r0)
	}
	if r1["asr_error"] != true || r1["read_ok"] != false || r1["impact"] != "misacted" {
		t.Fatal(r1)
	}
	if ms, _ := r1["mishearings"].([]any); len(ms) != 1 {
		t.Fatal(r1["mishearings"])
	}
	if ms, ok := r2["mishearings"].([]any); !ok || len(ms) != 0 || r2["judged_at"] != nil {
		t.Fatal(r2)
	}
}

func TestTermCandidatesFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "glossary_candidates.json")
	if c := ReadTermCandidates(p); len(c) != 0 {
		t.Fatal(c)
	}
	want := map[string]TermCandidate{"プルリク": {Count: 1, Wrongs: []string{"プロリク"}}}
	if err := WriteTermCandidates(p, want); err != nil {
		t.Fatal(err)
	}
	got := ReadTermCandidates(p)
	if got["プルリク"].Count != 1 || got["プルリク"].Wrongs[0] != "プロリク" {
		t.Fatal(got)
	}
}

func TestShouldRunImprove(t *testing.T) {
	for _, c := range []struct {
		enabled, busy  bool
		pending, batch int
		force, want    bool
	}{
		{true, false, 30, 30, false, true},
		{true, false, 29, 30, false, false},
		{true, false, 1, 30, true, true}, // "now" from the menu
		{true, false, 0, 30, true, false},
		{false, false, 60, 30, false, false}, // off: never
		{true, true, 60, 30, true, false},    // never while recording or transcribing
	} {
		if got := ShouldRunImprove(c.enabled, c.busy, c.pending, c.batch, c.force); got != c.want {
			t.Fatal(c, got)
		}
	}
}

func TestImproveConfigDefaults(t *testing.T) {
	c, err := ParseConfig([]byte(`{}`))
	if err != nil || c.ImproveEnabled || c.ImproveCommand != DefaultImproveCommand || c.ImproveBatch != DefaultImproveBatch {
		t.Fatal(c.ImproveEnabled, c.ImproveCommand, c.ImproveBatch, err)
	}
	c, _ = ParseConfig([]byte(`{"improveEnabled": true, "improveCommand": " ", "improveBatch": -1}`))
	if !c.ImproveEnabled || c.ImproveCommand != DefaultImproveCommand || c.ImproveBatch != DefaultImproveBatch {
		t.Fatal(c.ImproveCommand, c.ImproveBatch)
	}
	if c.ImproveTarget() != "コマンド: "+DefaultImproveCommand {
		t.Fatal(c.ImproveTarget())
	}
}
