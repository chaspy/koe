package core

import (
	"reflect"
	"testing"
)

// The same cases as macOS Tests/judgement (#223): error=false; error + read_ok; error + not read; unknown.
func TestImproveJudgementFields(t *testing.T) {
	at := "2026-10-25T01:00:00Z"
	cases := []struct {
		j    map[string]any
		want map[string]any
	}{
		{map[string]any{"error": false, "read_ok": true},
			map[string]any{"asr_error": false, "read_ok": true, "unknown": false, "impact": nil, "judged_at": at}},
		{map[string]any{"error": true, "read_ok": true},
			map[string]any{"asr_error": true, "read_ok": true, "unknown": false, "impact": nil, "judged_at": at}},
		{map[string]any{"error": true, "read_ok": false, "impact": "redo"},
			map[string]any{"asr_error": true, "read_ok": false, "unknown": false, "impact": "redo", "judged_at": at}},
		{map[string]any{"unknown": true},
			map[string]any{"read_ok": nil, "unknown": true, "impact": nil, "judged_at": at}},
		// an old answer with only a label: no asr_error; an impact outside the list is dropped
		{map[string]any{"label": "unclear", "impact": "other"},
			map[string]any{"read_ok": nil, "unknown": true, "impact": nil, "judged_at": at}},
	}
	for _, c := range cases {
		if got := ImproveJudgementFields(c.j, at); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%v: got %v, want %v", c.j, got, c.want)
		}
	}
}

func TestImproveJudgedCounts(t *testing.T) {
	js := []map[string]any{
		{"error": false}, {"error": true, "read_ok": true}, {"error": true, "read_ok": false},
		{"unknown": true}, {"reason": "unreadable"},
	}
	want := map[string]int{"judged": 4, "asr_error": 2, "not_understood": 1, "unclear": 1, "terms_added": 3}
	if got := ImproveJudgedCounts(js, 3); !reflect.DeepEqual(got, want) {
		t.Fatal(got)
	}
}

func TestImproveMishearings(t *testing.T) {
	batch := []ImproveItem{
		{ID: "a", Record: map[string]any{"raw": "プロリクを出す"}},
		{ID: "b", Record: map[string]any{"raw": "テラホームで作る"}},
	}
	terms := []map[string]any{
		{"i": float64(0), "wrong": "プロリク", "right": "プルリク"},
		{"i": float64(0), "wrong": "プロリク", "right": "プルリク"}, // duplicate
		{"i": float64(1), "wrong": "プロリク", "right": "プルリク"}, // not in [1]'s transcript
		{"i": float64(1), "wrong": "テラホーム", "right": "Terraform"},
		{"i": float64(1), "wrong": "パン粉さん", "right": "panko", "kind": "person"}, // people are macOS only
		{"i": float64(5), "wrong": "テラホーム", "right": "Terraform"},               // out of range
		{"wrong": "テラホーム", "right": "Terraform"},                                // no index
	}
	want := map[int][]map[string]string{
		0: {{"wrong": "プロリク", "right": "プルリク"}},
		1: {{"wrong": "テラホーム", "right": "Terraform"}},
	}
	if got := ImproveMishearings(batch, terms); !reflect.DeepEqual(got, want) {
		t.Fatal(got)
	}
}
