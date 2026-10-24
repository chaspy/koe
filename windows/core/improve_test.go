package core

import (
	"strings"
	"testing"
)

func rec(id, raw string, extra map[string]any) ImproveItem {
	r := map[string]any{"raw": raw, "outcome": "pasted"}
	for k, v := range extra {
		r[k] = v
	}
	return ImproveItem{ID: id, Record: r}
}

func TestImproveBatchPicksOnlyUnscannedText(t *testing.T) {
	items := []ImproveItem{
		rec("2026-10-19T10-00-02-000", "二つ目", nil),
		rec("2026-10-19T10-00-01-000", "一つ目", nil),
		rec("2026-10-19T10-00-03-000", "ロック録音", map[string]any{"locked": true}), // may hold another person's voice
		rec("2026-10-19T10-00-04-000", "済み", map[string]any{"glossary_scanned": true}),
		rec("2026-10-19T10-00-05-000", "", nil),
		rec("2026-10-19T10-00-06-000", "幻聴", map[string]any{"outcome": "hallucination"}),
		rec("2026-10-19T10-00-07-000", "声なし", map[string]any{"outcome": "no_voice"}),
		rec("2026-10-19T10-00-08-000", "貼れなかった", map[string]any{"outcome": "target_changed"}), // the text existed
	}
	got := ImproveBatch(items)
	var raws []string
	for _, it := range got {
		raws = append(raws, it.Record["raw"].(string))
	}
	if strings.Join(raws, ",") != "一つ目,二つ目,貼れなかった" {
		t.Fatal(raws)
	}
}

func TestImproveBatchKeepsTheNewest(t *testing.T) {
	var items []ImproveItem
	for i := 0; i < ImproveBatchMax+5; i++ {
		items = append(items, rec("2026-10-19T10-00-"+string(rune('A'+i/26))+string(rune('a'+i%26)), "x", nil))
	}
	got := ImproveBatch(items)
	if len(got) != ImproveBatchMax || got[0].ID != items[5].ID {
		t.Fatal(len(got), got[0].ID)
	}
}

func TestImproveRequestText(t *testing.T) {
	items := []ImproveItem{rec("a", "プロリクを出す", nil), rec("b", "マージして", nil)}
	req := ImproveRequest(items, []string{"プルリク", "マージ"}, nil)
	want := ImprovePrompt + "\n\n---\n\n" +
		"既に辞書にある語: プルリク、マージ\n\n" +
		"[0] 文字起こし: プロリクを出す\n  （Claude Code のセッション記録なし）\n\n" +
		"[1] 文字起こし: マージして\n  （Claude Code のセッション記録なし）"
	if req != want {
		t.Fatalf("%q", req[len(ImprovePrompt):])
	}
	if !strings.HasPrefix(ImprovePrompt, "あなたは音声入力アプリの改善係です。") || !strings.Contains(ImprovePrompt, `"judgements"`) {
		t.Fatal("prompt is not the macOS one")
	}
	// at most 400 known terms
	many := make([]string, 500)
	for i := range many {
		many[i] = "語"
	}
	if n := strings.Count(ImprovePayload(nil, many, nil), "、"); n != 399 { // 400 terms, 399 separators
		t.Fatal(n)
	}
}

func TestParseImproveAnswer(t *testing.T) {
	a, err := ParseImproveAnswer("```json\n{\"terms\": [{\"i\": 0, \"wrong\": \"プロリク\", \"right\": \"プルリク\"}], \"judgements\": [{\"i\": 0, \"error\": false}]}\n```")
	if err != nil || len(a.Terms) != 1 || len(a.Judgements) != 1 || a.Terms[0]["right"] != "プルリク" {
		t.Fatal(a, err)
	}
	for _, bad := range []string{"", "no json", "{broken", "} {"} {
		if _, err := ParseImproveAnswer(bad); err != ErrImproveAnswer {
			t.Fatal(bad, err)
		}
	}
}

func TestImproveLabel(t *testing.T) {
	for _, c := range []struct {
		j    map[string]any
		want string
	}{
		{map[string]any{"error": false}, "understood"},
		{map[string]any{"error": true, "read_ok": true}, "understood"},
		{map[string]any{"error": true, "read_ok": false}, "corrected"},
		{map[string]any{"error": true}, "corrected"},
		{map[string]any{"unknown": true, "error": false}, "unclear"},
		{map[string]any{"label": "corrected"}, "corrected"},
		{map[string]any{"label": "something"}, ""},
		{map[string]any{}, ""},
	} {
		if got := ImproveLabel(c.j); got != c.want {
			t.Fatal(c.j, got)
		}
	}
	if ImproveImpact(map[string]any{"impact": "misacted"}) != "misacted" || ImproveImpact(map[string]any{"impact": "other"}) != "redo" || ImproveImpact(nil) != "redo" {
		t.Fatal("impact")
	}
}

func TestIsImproveTerm(t *testing.T) {
	for _, w := range []string{"プルリク", "GitHub", "k8s", "Secret Manager"} {
		if !IsImproveTerm(w, false) {
			t.Fatal("term", w)
		}
	}
	for _, w := range []string{"遅延", "返事不要", "a", "Slackの一本化", "プルリクを出す", strings.Repeat("ア", 21)} {
		if IsImproveTerm(w, false) {
			t.Fatal("not a term", w)
		}
	}
	if !IsImproveTerm("山田", true) {
		t.Fatal("person names skip the kana/latin rule")
	}
}

func TestMergeImproveTerms(t *testing.T) {
	term := func(wrong, right string, explicit bool) map[string]any {
		return map[string]any{"wrong": wrong, "right": right, "kind": "term", "explicit": explicit}
	}
	// once, not explicit: counted, not promoted
	cand, promote := MergeImproveTerms(nil, []map[string]any{term("プロリク", "プルリク", false)}, nil)
	if cand["プルリク"].Count != 1 || len(promote) != 0 {
		t.Fatal(cand, promote)
	}
	// twice: promoted, but only as "~" (a note, never replaced)
	_, promote = MergeImproveTerms(cand, []map[string]any{term("プロリック", "プルリク", false)}, nil)
	if got := strings.Join(promote["プルリク"], ","); got != "~プロリク,~プロリック" {
		t.Fatal(got)
	}
	// explicit once: a sure replacement, except a common form (3 chars or less / no kana or latin)
	_, promote = MergeImproveTerms(nil, []map[string]any{term("テラホーム", "Terraform", true), term("かぶる", "Kaburu", true)}, nil)
	if got := strings.Join(promote["Terraform"], ","); got != "テラホーム" {
		t.Fatal(got)
	}
	if got := strings.Join(promote["Kaburu"], ","); got != "~かぶる" {
		t.Fatal(got)
	}
	// rejected: phrases, notes, same text, too long, people (macOS only)
	_, promote = MergeImproveTerms(nil, []map[string]any{
		term("あれ", "プルリクを出す", true),
		term("x", "(聞き取り不能)", true),
		term("GitHub", "GitHub", true),
		term("これはとても長いまちがいの形です", "GitHub", true),
		term("a、b", "GitHub", true),
		{"wrong": "パン粉さん", "right": "panko", "kind": "person", "explicit": true},
	}, nil)
	if len(promote) != 0 {
		t.Fatal(promote)
	}
}

func TestApplyImprovePromotions(t *testing.T) {
	text := "# Koe 個人の辞書\r\nマージ\t~マジ\r\n"
	out, added := ApplyImprovePromotions(text, map[string][]string{
		"マージ":       {"マージュ"},
		"Terraform": {"テラホーム"},
	})
	want := "# Koe 個人の辞書\r\nTerraform\tテラホーム\r\nマージ\t~マジ／マージュ\r\n"
	if out != want || strings.Join(added, ",") != "Terraform" {
		t.Fatalf("%q %v", out, added)
	}
	// a new glossary gets the header; LF is kept when the file uses LF
	out, _ = ApplyImprovePromotions("", map[string][]string{"GitHub": {"ギットハブ"}})
	if out != ImproveGlossaryHeader+"\nGitHub\tギットハブ\n" {
		t.Fatalf("%q", out)
	}
	// the cap: no new term once the glossary has ImproveGlossaryMax terms, merging still works
	var b strings.Builder
	b.WriteString("# header\n")
	for i := 0; i < ImproveGlossaryMax; i++ {
		b.WriteString("語" + strings.Repeat("ア", i%5+1) + string(rune('A'+i%26)) + string(rune('a'+i/26)) + "\n")
	}
	b.WriteString("マージ\n")
	full := b.String()
	out, added = ApplyImprovePromotions(full, map[string][]string{"New": {"ニュー"}, "マージ": {"マジ"}})
	if len(added) != 0 || strings.Contains(out, "New\t") || !strings.Contains(out, "マージ\tマジ") {
		t.Fatal(added)
	}
}
