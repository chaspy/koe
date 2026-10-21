package core

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// one session: sent → reply → queued while working → more reply → next sent
const sessionLines = `{"type":"user","timestamp":"2026-10-19T01:00:00.000Z","message":{"content":"プルリクを出して"}}
{"type":"assistant","timestamp":"2026-10-19T01:00:05.000Z","message":{"content":[{"type":"text","text":"出しました"}]}}
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-19T01:00:06.000Z","content":"ついでにレビューも"}
{"type":"user","timestamp":"2026-10-19T01:00:07.000Z","message":{"content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","timestamp":"2026-10-19T01:00:09.000Z","message":{"content":"レビューも頼みました"}}
{"type":"user","timestamp":"2026-10-19T01:01:00.000Z","message":{"content":"ありがとう"}}
{"type":"user","timestamp":"2026-10-19T01:01:01.000Z","message":{"content":"<command-name>/clear</command-name>"}}
{"type":"user","isMeta":true,"timestamp":"2026-10-19T01:01:02.000Z","message":{"content":"meta"}}
not json
{"type":"user","timestamp":"2026-10-19T00:00:00.000Z","message":{"content":"古い"}}`

func TestParseSessionLog(t *testing.T) {
	since := time.Date(2026, 10, 19, 0, 30, 0, 0, time.UTC)
	hs := ParseSessionLog(sessionLines, since)
	if len(hs) != 3 {
		t.Fatal(len(hs), hs)
	}
	first := hs[0]
	// the reply runs until the next message from the input box, across the queued one
	if first.Text != "プルリクを出して" || first.Reply != "出しました\nレビューも頼みました\n" || first.Next != "ついでにレビューも" {
		t.Fatalf("%+v", first)
	}
	if hs[1].Text != "ついでにレビューも" || hs[1].Next != "ありがとう" || hs[2].Text != "ありがとう" || hs[2].Reply != "" {
		t.Fatalf("%+v", hs[1:])
	}
}

func TestMatchSession(t *testing.T) {
	at := time.Date(2026, 10, 19, 1, 0, 0, 0, time.UTC)
	hs := []SessionHuman{
		{Time: at.Add(-10 * time.Second), Text: "プルリクを出して"},     // too early
		{Time: at.Add(3 * time.Second), Text: "プルリクを、出して！ほかにも"}, // spaces/punctuation do not matter
	}
	if h := MatchSession("プルリクを出して", at, hs); h == nil || h.Time != hs[1].Time {
		t.Fatal(h)
	}
	if MatchSession("プルリクを出して", at.Add(30*time.Second), hs) != nil {
		t.Fatal("outside -5..+20 s")
	}
	if MatchSession("はい", at, hs) != nil {
		t.Fatal("under 4 characters is never matched")
	}
	if NormalizeSessionText(" a、b。 c!") != "abc" {
		t.Fatal(NormalizeSessionText(" a、b。 c!"))
	}
}

func TestImprovePayloadWithSession(t *testing.T) {
	at := time.Date(2026, 10, 19, 10, 0, 0, 0, time.Local)
	items := []ImproveItem{
		{ID: NewHistoryID(at), Record: map[string]any{"raw": "プロリクを出して", "pasted": "プルリクを出して"}},
		{ID: NewHistoryID(at.Add(2 * time.Second)), Record: map[string]any{"raw": "レビューも頼む"}},
		{ID: NewHistoryID(at.Add(time.Minute)), Record: map[string]any{"raw": "記録のない発話"}},
	}
	hs := []SessionHuman{
		{Time: at.Add(time.Second), Text: "プルリクを出して（手で直した）", Reply: "出しました\n", Next: "レビューも頼む"},
		{Time: at.Add(3 * time.Second), Text: "レビューも頼む", Reply: "出しました\n", Next: ""},
	}
	got := ImprovePayload(items, nil, hs)
	for _, want := range []string{
		"[0] 文字起こし: プロリクを出して\n  実際に送った文: プルリクを出して（手で直した）\n  Claude の返答: 出しました\n\n  次の発話: レビューも頼む",
		"[1] 文字起こし: レビューも頼む\n  Claude の返答: （[0] と同じ返答。",
		"  次の発話: （なし）",
		"[2] 文字起こし: 記録のない発話\n  （Claude Code のセッション記録なし）",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("missing %q in\n%s", want, got)
		}
	}
	if since := ImproveSince(items, at.Add(time.Hour)); !since.Equal(at.Add(-time.Hour)) {
		t.Fatal(since)
	}
}

func TestLoadSessionLogs(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "C--work-repo")
	if err := os.MkdirAll(dir, 0o750); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{"a.jsonl": sessionLines, "notes.txt": sessionLines} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	since := time.Date(2026, 10, 19, 0, 30, 0, 0, time.UTC)
	recent := since.Add(time.Hour)
	if err := os.Chtimes(filepath.Join(dir, "a.jsonl"), recent, recent); err != nil {
		t.Fatal(err)
	}
	if n := len(LoadSessionLogs(root, since)); n != 3 {
		t.Fatal(n)
	}
	// a file not changed since `since` is not read
	old := since.Add(-time.Hour)
	if err := os.Chtimes(filepath.Join(dir, "a.jsonl"), old, old); err != nil {
		t.Fatal(err)
	}
	if n := len(LoadSessionLogs(root, since)); n != 0 {
		t.Fatal(n)
	}
	if LoadSessionLogs(filepath.Join(root, "missing"), since) != nil {
		t.Fatal("missing root")
	}
}
