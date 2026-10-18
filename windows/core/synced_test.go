package core

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestUsableSyncedTerm(t *testing.T) {
	for _, term := range []string{"プルリクエスト", "GitHub", "Claude Code", "Node.js", "CI/CD", "C++", "e-mail", "👨‍👩‍👧", "a b c", strings.Repeat("あ", 40)} {
		if !UsableSyncedTerm(term) {
			t.Errorf("rejected %q", term)
		}
	}
	for _, term := range []string{
		"", strings.Repeat("あ", 41), "a b c d", "line\nbreak", "tab\there", "esc\x1b", "rtl\u202ex",
		"a;b", "a|b", "a&b", "a$b", "a`b`", "(a)", "a>b", "a<b", `a\b`, `"q"`, "'q'", "a*", "a?", "!a", "~a", "C#", "{a}", "[a]",
	} {
		if UsableSyncedTerm(term) {
			t.Errorf("accepted %q", term)
		}
	}
}

func TestMarkSyncedPacks(t *testing.T) {
	user, bundled := filepath.Join("u", "packs"), filepath.Join("app", "packs")
	packs := []Pack{
		{ID: "team", Path: filepath.Join(user, "team.txt")},
		{ID: "mine", Path: filepath.Join(user, "mine.txt")},
		{ID: "developer", Path: filepath.Join(bundled, "developer.txt")},
	}
	got := MarkSyncedPacks(packs, user, []string{"gh:o/r/voice/team.txt", "gh:o/r/developer.txt", "https://x/mine.txt"})
	want := []bool{true, false, false}
	for i, p := range got {
		if p.Synced != want[i] {
			t.Errorf("%s synced=%v want %v", p.ID, p.Synced, want[i])
		}
	}
	if packs[0].Synced {
		t.Error("input changed")
	}
}

func TestAutocorrectSynced(t *testing.T) {
	es := []Entry{
		{Term: "プルリクエスト", Aliases: []string{"プロリクエスト"}},
		{Term: "マージ", Aliases: []string{"マージュ"}, Synced: true},
		{Term: "echo a; echo b", Aliases: []string{"お願いします"}, Synced: true},
	}
	got, applied, synced := AutocorrectSynced("プロリクエストをマージュしてお願いします", es)
	if got != "プルリクエストをマージしてお願いします" || len(applied) != 2 || !synced {
		t.Fatalf("got %q %v %v", got, applied, synced)
	}
	if _, _, synced := AutocorrectSynced("プロリクエストです", es); synced {
		t.Error("synced without a synced replacement")
	}
	if got, _ := Autocorrect("お願いします", es); got != "お願いします" {
		t.Errorf("unusable synced term was used: %q", got)
	}
}

func TestLoadPackEntriesCarriesSynced(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "team.txt")
	if err := os.WriteFile(path, []byte("マージ\tマージュ\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	es := LoadPackEntries([]Pack{{ID: "team", Path: path, Synced: true}}, []string{"team"})
	if len(es) != 1 || !es[0].Synced {
		t.Fatalf("%+v", es)
	}
}

func TestPipelineReportsSyncedReplacement(t *testing.T) {
	es := []Entry{{Term: "マージ", Aliases: []string{"マージュ"}, Synced: true}}
	res := TranscribeUtterance(t.Context(), UtteranceRequest{Recognizer: &fakeRecognizer{replies: []string{"マージュして"}}, Entries: es, Voiced: 2})
	if res.Text != "マージして" || !res.SyncedReplaced {
		t.Fatalf("%+v", res)
	}
	res = TranscribeUtterance(t.Context(), UtteranceRequest{Recognizer: &fakeRecognizer{replies: []string{"そのままで"}}, Entries: es, Voiced: 2})
	if res.SyncedReplaced {
		t.Fatal("no synced replacement expected")
	}
}
