package core

import (
	"reflect"
	"strings"
	"testing"
)

// macOS Tests/termselection: a term whose aliases are all "~" ranks once its
// alias shows in the raw text; one that never appears does not (#227).
func TestCountTermUsageRaw(t *testing.T) {
	es := []Entry{
		{Term: "Kubernetes", Aliases: []string{"~クバネティス"}},
		{Term: "Terraform", Aliases: []string{"~テラホーム"}},
	}
	samples := []UsageSample{
		{Pasted: "クバネティスで動かす", Raw: "クバネティスで動かす"},
		{Pasted: "", Raw: "クバネティスを見る"}, // not pasted: still counts by raw
	}
	got := CountTermUsage(es, samples)
	// sample 1: pasted (alias) + raw = 2, sample 2: raw = 1
	if !reflect.DeepEqual(got, map[string]int{"Kubernetes": 3}) {
		t.Fatal(got)
	}
	terms := WhisperTerms(nil, es, got, 10)
	if !reflect.DeepEqual(terms, []string{"Kubernetes"}) {
		t.Fatal(terms)
	}
	// only the newest UsageSamples count
	many := make([]UsageSample, UsageSamples)
	if c := CountTermUsage(es, append(samples, many...)); len(c) != 0 {
		t.Fatal(c)
	}
}

// #196: token boundaries, and the longer term first.
func TestTermUsageBoundariesAndLonger(t *testing.T) {
	htm, html, sh := Entry{Term: "HTM"}, Entry{Term: "HTML", Aliases: []string{"エイチティーエムエル"}}, Entry{Term: "SH", Aliases: []string{"エスエイチ"}}
	got := UsageCounts([]Entry{htm, html, sh}, []string{"HTMLを書く", "bash と ssh で入る", "HTM の略"})
	if got["HTM"] != 1 || got["HTML"] != 1 || got["SH"] != 0 {
		t.Fatal(got)
	}
	if c := UsageCounts([]Entry{sh}, []string{"SH で書く"}); c["SH"] != 1 {
		t.Fatal(c)
	}
	terms := WhisperTerms(nil, []Entry{htm, html}, map[string]int{"HTM": 3}, WhisperPromptTermLimit)
	if !reflect.DeepEqual(terms, []string{"HTML", "HTM"}) {
		t.Fatal(terms)
	}
	if tight := WhisperTerms(nil, []Entry{htm, html}, map[string]int{"HTM": 3}, 5); !reflect.DeepEqual(tight, []string{"HTML"}) {
		t.Fatal(tight)
	}
	es := []Entry{{Term: "HTM", Aliases: []string{"エイチティーエム"}}, html}
	if out, _ := Autocorrect("エイチティーエムLを書く", es); out != "エイチティーエムLを書く" {
		t.Fatal(out)
	}
	if out, _ := Autocorrect("エイチティーエムを書く", es); out != "HTMを書く" {
		t.Fatal(out)
	}
	if got := LongerTerms("HTM", []string{"HTML", "HTM", "XML", "htmx"}); !reflect.DeepEqual(got, []string{"HTML"}) {
		t.Fatal(got)
	}
	for _, c := range [][2]string{{"CI", "CI/CD"}, {"Claude", "Claude Code"}, {"PR", "Prometheus"}} {
		if got := LongerTerms(c[0], []string{c[1]}); len(got) != 0 {
			t.Fatal(c, got)
		}
	}
	if got := LongerTerms("プルリク", []string{"プルリクエスト"}); len(got) != 1 {
		t.Fatal(got)
	}
}

// #227: a non-common alias seen in two different utterances becomes a sure
// replacement; ordinary words, short forms and English words stay "~".
func TestMergeImproveTermsRepeated(t *testing.T) {
	term := func(i int, wrong, right string) map[string]any {
		return map[string]any{"i": float64(i), "wrong": wrong, "right": right, "kind": "term"}
	}
	// the same utterance twice in one answer counts once
	cand, promote := MergeImproveTerms(nil, []map[string]any{term(0, "テラホーム", "Terraform"), term(0, "テラホーム", "Terraform")},
		map[int]string{0: "テラホームで作る"})
	if cand["Terraform"].AliasCounts["テラホーム"] != 1 || strings.Join(promote["Terraform"], ",") != "~テラホーム" {
		t.Fatal(cand, promote)
	}
	// a second utterance (next run): sure
	cand, promote = MergeImproveTerms(cand, []map[string]any{term(3, "テラホーム", "Terraform")}, map[int]string{3: "テラホームを直す"})
	if cand["Terraform"].AliasCounts["テラホーム"] != 2 || strings.Join(promote["Terraform"], ",") != "テラホーム" {
		t.Fatal(cand, promote)
	}
	// not in the transcript: not observed
	cand, _ = MergeImproveTerms(nil, []map[string]any{term(0, "クバネティス", "Kubernetes"), term(1, "クバネティス", "Kubernetes")},
		map[int]string{0: "なにか", 1: "ほか"})
	if cand["Kubernetes"].AliasCounts["クバネティス"] != 0 {
		t.Fatal(cand)
	}
	// protected forms stay "~" even when repeated: an ordinary katakana word, an ASCII word, a short form
	for _, w := range []string{"オーケー", "Kitten", "テラ"} {
		_, p := MergeImproveTerms(nil, []map[string]any{term(0, w, "Okta"), term(1, w, "Okta")}, map[int]string{0: w + " で", 1: w + " を"})
		if strings.Join(p["Okta"], ",") != "~"+w {
			t.Fatal(w, p)
		}
	}
}

func TestMergeAliasesDropsNoteWhenSure(t *testing.T) {
	if got := mergeAliases([]string{"~テラホーム", "~テラフォー"}, []string{"テラホーム"}); !reflect.DeepEqual(got, []string{"~テラフォー", "テラホーム"}) {
		t.Fatal(got)
	}
	out, _ := ApplyImprovePromotions("# h\nTerraform\t~テラホーム\n", map[string][]string{"Terraform": {"テラホーム"}})
	if !strings.Contains(out, "Terraform\tテラホーム\n") {
		t.Fatal(out)
	}
}

func TestRecentUsageSamples(t *testing.T) {
	dir := t.TempDir()
	writeRecord(t, dir, "2026-10-24T09-00-00-000", map[string]any{"raw": "クバネティス", "pasted": nil})
	writeRecord(t, dir, "2026-10-24T09-01-00-000", map[string]any{"raw": "テラホーム", "pasted": "Terraform"})
	writeRecord(t, dir, "2026-10-24T09-02-00-000", map[string]any{"raw": ""})
	got := RecentUsageSamples(dir, 10)
	want := []UsageSample{{Raw: "クバネティス"}, {Pasted: "Terraform", Raw: "テラホーム"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatal(got)
	}
}
