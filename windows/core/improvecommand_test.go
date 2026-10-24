package core

import (
	"errors"
	"path/filepath"
	"testing"
	"time"
)

// A fake file system: no real PATH, folder or shell is used.
func TestResolveImproveProgram(t *testing.T) {
	home, appData := filepath.Join("H"), filepath.Join("H", "AppData", "Roaming")
	dirs := ImproveCommandDirs(home, appData)
	files := map[string]bool{}
	exists := func(p string) bool { return files[p] }
	noPath := func(string) (string, error) { return "", errors.New("not found") }

	// not anywhere
	if _, ok := ResolveImproveProgram("claude", dirs, exists, noPath); ok {
		t.Fatal("found nothing")
	}
	// only on PATH
	m, ok := ResolveImproveProgram("claude", dirs, exists, func(string) (string, error) { return `C:\tools\claude.exe`, nil })
	if !ok || m.Location != "path" || m.Path != `C:\tools\claude.exe` {
		t.Fatal(m)
	}
	// npm's claude.cmd beats PATH; the native installer's .exe beats npm
	files[filepath.Join(appData, "npm", "claude.cmd")] = true
	if m, _ := ResolveImproveProgram("claude", dirs, exists, noPath); m.Location != "npm" {
		t.Fatal(m)
	}
	files[filepath.Join(home, ".local", "bin", "claude.exe")] = true
	if m, _ := ResolveImproveProgram("claude", dirs, exists, noPath); m.Location != "local" || m.Path != filepath.Join(home, ".local", "bin", "claude.exe") {
		t.Fatal(m)
	}
	// a path is used as given (with an extension tried when it has none)
	files[`C:\x\my tool.bat`] = true
	if m, ok := ResolveImproveProgram(`C:\x\my tool`, dirs, exists, noPath); !ok || m.Location != "absolute" || m.Path != `C:\x\my tool.bat` {
		t.Fatal(m)
	}
	if _, ok := ResolveImproveProgram(`C:\x\missing.exe`, dirs, exists, noPath); ok {
		t.Fatal("a missing path is not looked up elsewhere")
	}
	if _, ok := ResolveImproveProgram("", dirs, exists, noPath); ok {
		t.Fatal("empty")
	}
	if got := ImproveCommandDirs("", ""); len(got) != 0 {
		t.Fatal(got)
	}
}

func TestImproveCommandToken(t *testing.T) {
	cases := []struct{ in, program, rest string }{
		{"claude -p --model sonnet", "claude", " -p --model sonnet"},
		{"  claude", "claude", ""},
		{`"C:\Program Files\x\claude.exe" -p`, `C:\Program Files\x\claude.exe`, " -p"},
	}
	for _, c := range cases {
		p, r, ok := ImproveCommandToken(c.in)
		if !ok || p != c.program || r != c.rest {
			t.Errorf("%q: %q %q %v", c.in, p, r, ok)
		}
	}
	for _, bad := range []string{"", "   ", `"unterminated -p`, `"" -p`} {
		if _, _, ok := ImproveCommandToken(bad); ok {
			t.Errorf("%q should not parse", bad)
		}
	}
	if got := ImproveCmdLine(`C:\Program Files\x\claude.exe`, " -p --model sonnet"); got != `cmd /s /c ""C:\Program Files\x\claude.exe" -p --model sonnet"` {
		t.Fatal(got)
	}
	if got := ImprovePath(ImproveCommandDirs("H", "A"), `C:\Windows`); got != filepath.Join("H", ".local", "bin")+";"+filepath.Join("A", "npm")+";"+filepath.Join("H", ".claude", "local")+`;C:\Windows` {
		t.Fatal(got)
	}
}

// macOS ImproveFailures: 3 in a row → a notice, at most once a day; a success clears.
func TestImproveFailures(t *testing.T) {
	now := time.Date(2026, 10, 25, 9, 0, 0, 0, time.UTC)
	var f ImproveFailures
	f.Record(ImproveNotFoundCode)
	f.Record(ImproveNotFoundCode)
	if f.TakeNotice(now) {
		t.Fatal("2 in a row is not told")
	}
	f.Record(ImproveNotFoundCode)
	if !f.TakeNotice(now) || f.ExitCode != ImproveNotFoundCode {
		t.Fatal("3 in a row is told")
	}
	f.Record(1)
	if f.TakeNotice(now.Add(23 * time.Hour)) {
		t.Fatal("once a day")
	}
	if !f.TakeNotice(now.Add(24 * time.Hour)) {
		t.Fatal("the next day again")
	}
	f.Record(0)
	f.Record(1)
	if f.Consecutive != 1 || f.TakeNotice(now.Add(72*time.Hour)) {
		t.Fatal("a success clears", f)
	}
	title, text := ImproveFailureText("claude", ImproveNotFoundCode)
	if title != "Koe: 改善ループが動いていません（claude が見つかりません）" || text == "" {
		t.Fatal(title)
	}
	if title, _ := ImproveFailureText("claude", 1); title != "Koe: 改善ループが動いていません（終了コード: 1）" {
		t.Fatal(title)
	}
}
