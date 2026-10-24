package core

// Finding the improvement loop's command and noticing when it keeps failing
// (#184, macOS #213 / #214 ImproveCommand.swift). Koe runs ImproveCommand with
// `cmd /c` and its own PATH, which is the PATH of when Koe started: Claude Code
// installed afterwards, or installed to a folder that is not on that PATH, is
// "not recognized" (exit 9009) on every run, and the loop silently stops. So the
// program is looked up in the usual install folders first, then on PATH, and
// run by its full path. Three failures in a row are told once a day.

import (
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// ImproveNotFoundCode is cmd's exit code for "is not recognized as a command".
const ImproveNotFoundCode = 9009

// ImproveCommandDir is a folder where command-line tools are usually installed.
type ImproveCommandDir struct {
	Path     string
	Location string // a label for the log, never the path (it holds the user name)
}

// ImproveCommandDirs are the folders looked in before PATH: the native Claude Code
// installer (~\.local\bin), npm's global folder (%APPDATA%\npm) and Claude Code's
// own local install (~\.claude\local).
func ImproveCommandDirs(home, appData string) []ImproveCommandDir {
	var out []ImproveCommandDir
	if home != "" {
		out = append(out, ImproveCommandDir{filepath.Join(home, ".local", "bin"), "local"})
	}
	if appData != "" {
		out = append(out, ImproveCommandDir{filepath.Join(appData, "npm"), "npm"})
	}
	if home != "" {
		out = append(out, ImproveCommandDir{filepath.Join(home, ".claude", "local"), "claude"})
	}
	return out
}

// ImproveCommandMatch is where the program was found.
type ImproveCommandMatch struct {
	Path     string
	Location string // absolute / local / npm / claude / path
}

// improveExts are tried, in this order, when the program has no extension (cmd's PATHEXT order).
var improveExts = []string{".exe", ".cmd", ".bat"}

// ResolveImproveProgram finds program: as given when it is a path, then in dirs,
// then with lookPath (exec.LookPath, the PATH Koe has). exists reports whether a
// file is there. It returns false when it is nowhere.
func ResolveImproveProgram(program string, dirs []ImproveCommandDir, exists func(string) bool,
	lookPath func(string) (string, error)) (ImproveCommandMatch, bool) {
	if program == "" {
		return ImproveCommandMatch{}, false
	}
	if filepath.IsAbs(program) || strings.ContainsAny(program, `\/`) {
		p, ok := firstExisting(withExts(program), exists)
		return ImproveCommandMatch{p, "absolute"}, ok
	}
	for _, d := range dirs {
		if p, ok := firstExisting(withExts(filepath.Join(d.Path, program)), exists); ok {
			return ImproveCommandMatch{p, d.Location}, true
		}
	}
	if p, err := lookPath(program); err == nil && p != "" {
		return ImproveCommandMatch{p, "path"}, true
	}
	return ImproveCommandMatch{}, false
}

func firstExisting(paths []string, exists func(string) bool) (string, bool) {
	for _, p := range paths {
		if exists(p) {
			return p, true
		}
	}
	return "", false
}

func withExts(p string) []string {
	if filepath.Ext(p) != "" {
		return []string{p}
	}
	out := make([]string, 0, len(improveExts))
	for _, e := range improveExts {
		out = append(out, p+e)
	}
	return out
}

// ImproveCommandToken splits the program off the command: the first word, which
// may be in double quotes (cmd has no single quotes or backslash escapes). It
// returns the program and the rest of the command, kept as written.
func ImproveCommandToken(command string) (program, rest string, ok bool) {
	s := strings.TrimLeft(command, " \t")
	if s == "" {
		return "", "", false
	}
	if s[0] == '"' {
		end := strings.IndexByte(s[1:], '"')
		if end < 0 {
			return "", "", false
		}
		return s[1 : end+1], s[end+2:], s[1:end+1] != ""
	}
	if i := strings.IndexAny(s, " \t"); i >= 0 {
		return s[:i], s[i:], true
	}
	return s, "", true
}

// ImproveCmdLine is the whole command line for CreateProcess: cmd /s /c "<command>",
// with the program replaced by its full path in quotes. /s makes cmd drop only the
// outer quotes, so the path may contain spaces. cmd /c runs claude.cmd (npm) and .exe alike.
func ImproveCmdLine(path, rest string) string {
	return `cmd /s /c ""` + path + `"` + rest + `"`
}

// ImprovePath is the PATH for the command: the install folders first, so tools the
// command itself calls (node for npm's claude.cmd, git, …) are found too.
func ImprovePath(dirs []ImproveCommandDir, inherited string) string {
	parts := make([]string, 0, len(dirs)+1)
	for _, d := range dirs {
		parts = append(parts, d.Path)
	}
	if inherited != "" {
		parts = append(parts, inherited)
	}
	return strings.Join(parts, ";")
}

// ImproveFailures counts failures in a row (by exit code; 0 = success clears it).
// The notice is at most once a day, after ImproveFailureNoticeAfter in a row.
type ImproveFailures struct {
	Consecutive int       `json:"-"`
	ExitCode    int       `json:"-"`
	LastNotice  time.Time `json:"lastNotice"`
}

// ImproveFailureNoticeAfter is how many failures in a row are told (macOS: 3).
const ImproveFailureNoticeAfter = 3

// Record notes one run's exit code.
func (f *ImproveFailures) Record(code int) {
	f.ExitCode = code
	if code == 0 {
		f.Consecutive = 0
		return
	}
	f.Consecutive++
}

// TakeNotice reports whether to tell the user now, and if so remembers when.
func (f *ImproveFailures) TakeNotice(now time.Time) bool {
	if f.Consecutive < ImproveFailureNoticeAfter || !f.LastNotice.IsZero() && now.Sub(f.LastNotice) < 24*time.Hour {
		return false
	}
	f.LastNotice = now
	return true
}

// ImproveFailureText is the notice: the title and the text (no paths, only folder names).
func ImproveFailureText(program string, code int) (title, text string) {
	if code == ImproveNotFoundCode {
		return "Koe: 改善ループが動いていません（" + program + " が見つかりません）",
			`%USERPROFILE%\.local\bin、%APPDATA%\npm、%USERPROFILE%\.claude\local と PATH で探しました。` +
				"コマンドのインストールや config.json の improveCommand を確かめてください。\n\nもう一度試しますか？"
	}
	return "Koe: 改善ループが動いていません（終了コード: " + strconv.Itoa(code) + "）",
		"改善ループの送り先の設定・ログイン状態・接続を確かめてください。\n\nもう一度試しますか？"
}
