package core

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func pastes(s SuggestState, n int) SuggestState {
	for i := 0; i < n; i++ {
		s = SuggestPasted(s)
	}
	return s
}

func TestSuggestImproveTiming(t *testing.T) {
	t0 := time.Date(2026, 10, 19, 10, 0, 0, 0, time.UTC)
	s := pastes(SuggestState{}, 29)
	if ShouldSuggestImprove(s, t0, true) {
		t.Fatal("29 pastes: not yet")
	}
	s = SuggestPasted(s)
	if !ShouldSuggestImprove(s, t0, true) || !strings.Contains(SuggestText(s), "ここまで 30 回") {
		t.Fatal("30 pastes: suggest", SuggestText(s))
	}
	if ShouldSuggestImprove(s, t0, false) {
		t.Fatal("decided (tray / config.json): never")
	}
	s = SuggestShown(s, t0)
	s = pastes(s, 30)
	if ShouldSuggestImprove(s, t0.Add(13*24*time.Hour), true) {
		t.Fatal("snoozed for 14 days")
	}
	if !ShouldSuggestImprove(s, t0.Add(14*24*time.Hour), true) || !strings.Contains(SuggestText(s), "ここまで 60 回") {
		t.Fatal("second suggestion")
	}
	s = SuggestShown(s, t0.Add(14*24*time.Hour))
	if ShouldSuggestImprove(pastes(s, 100), t0.Add(400*24*time.Hour), true) {
		t.Fatal("at most 2")
	}
	few := pastes(SuggestShown(pastes(SuggestState{}, 30), t0), 29)
	if ShouldSuggestImprove(few, t0.Add(20*24*time.Hour), true) {
		t.Fatal("30 new pastes are needed after the snooze")
	}
	never := pastes(SuggestState{NeverAgain: true}, 30)
	if ShouldSuggestImprove(never, t0, true) {
		t.Fatal("never again")
	}
}

func TestSuggestStateFileAndConfigKey(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "improve_suggest.json")
	if s := ReadSuggestState(p); s != (SuggestState{}) {
		t.Fatal(s)
	}
	want := SuggestState{PastedSinceShown: 3, PastedTotal: 33, Shown: 1, LastShown: time.Date(2026, 10, 19, 1, 2, 3, 0, time.UTC), NeverAgain: true}
	if err := WriteSuggestState(p, want); err != nil {
		t.Fatal(err)
	}
	if got := ReadSuggestState(p); !got.LastShown.Equal(want.LastShown) || got.PastedTotal != 33 || !got.NeverAgain {
		t.Fatal(got)
	}
	cfg := filepath.Join(dir, "config.json")
	if ConfigHasKey(cfg, "improveEnabled") {
		t.Fatal("missing file")
	}
	for body, want := range map[string]bool{`{}`: false, `{"improveEnabled": false}`: true, `{"improveEnabled": true}`: true, `{broken`: false, ``: false} {
		if err := os.WriteFile(cfg, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if got := ConfigHasKey(cfg, "improveEnabled"); got != want {
			t.Fatal(body, got)
		}
	}
}
