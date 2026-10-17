package core

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestShouldPromptUpdate(t *testing.T) {
	now := time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC)
	var zero time.Time
	cases := []struct {
		name              string
		avail             string
		busy, noChanges   bool
		lastUsed, snoozed time.Time
		want              bool
	}{
		{"idle", "0.5.0", false, false, zero, zero, true},
		{"no update", "", false, false, zero, zero, false},
		{"busy", "0.5.0", true, false, zero, zero, false},
		{"used 29 s ago", "0.5.0", false, false, now.Add(-29 * time.Second), zero, false},
		{"used 31 s ago", "0.5.0", false, false, now.Add(-31 * time.Second), zero, true},
		{"snoozed", "0.5.0", false, false, zero, now.Add(time.Minute), false},
		{"snooze over", "0.5.0", false, false, zero, now.Add(-time.Second), true},
		{"no changes", "0.5.0", false, true, zero, zero, false},
	}
	for _, c := range cases {
		if got := ShouldPromptUpdate(now, c.avail, c.busy, c.lastUsed, c.snoozed, c.noChanges); got != c.want {
			t.Errorf("%s: %v", c.name, got)
		}
	}
}

const changelogMD = `# Changelog

## Unreleased

### Windows
- Not this one.

## 0.5.0 — 2026-10-20

### macOS
- No changes.

### Windows
- Fixed: the **first** utterance after a pause waited about a second (` + "`usageCounts`" + `), and this sentence is long enough to be cut.
- Second.

## 0.4.2 — 2026-10-16

### Windows
- Older.
`

func TestChangelogSummary(t *testing.T) {
	line, no := ChangelogSummary(changelogMD, "0.5.0", "Windows", 60)
	if no || !strings.HasPrefix(line, "Fixed: the first utterance after a pause") || strings.ContainsAny(line, "*`") || len([]rune(line)) != 60 || !strings.HasSuffix(line, "…") {
		t.Fatalf("windows: %q %v", line, no)
	}
	if line, no := ChangelogSummary(changelogMD, "0.5.0", "macOS", 100); line != "" || !no {
		t.Fatalf("macOS no changes: %q %v", line, no)
	}
	if line, _ := ChangelogSummary(changelogMD, "0.4.2", "windows", 100); line != "Older." {
		t.Fatalf("older: %q", line)
	}
	if line, no := ChangelogSummary(changelogMD, "9.9.9", "Windows", 100); line != "" || no {
		t.Fatal("missing")
	}
}

func TestFetchChangelog(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/o/r/v0.5.0/CHANGELOG.md" {
			w.Write([]byte(changelogMD))
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()
	md, err := FetchChangelog(context.Background(), srv.URL, "o/r", "v0.5.0", "x")
	if err != nil || !strings.Contains(md, "## 0.5.0") {
		t.Fatal(md, err)
	}
	if _, err := FetchChangelog(context.Background(), srv.URL, "o/r", "v9", "x"); err == nil {
		t.Fatal("404 must be an error")
	}
}

func TestUpdatePromptBoxFlags(t *testing.T) {
	f := UpdatePromptBoxFlags
	if f&0xF != MBYesNo {
		t.Fatal("Yes / No only: no Cancel button, so Esc does nothing")
	}
	if f&0xF00 != MBDefButton2 {
		t.Fatal("the default button (Enter) must be No = later")
	}
	if f&MBSetForeground != 0 {
		t.Fatal("must not take the foreground from the app being typed in")
	}
	if f&MBTopmost == 0 {
		t.Fatal("shown on top")
	}
}
