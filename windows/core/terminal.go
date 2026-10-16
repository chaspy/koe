package core

import (
	"path/filepath"
	"strings"
)

// DefaultEnterApps: process exe names that get an Enter after pasting
// (terminals). Other apps (Teams, Slack, browsers …) only get the paste.
var DefaultEnterApps = []string{
	"WindowsTerminal.exe", "OpenConsole.exe", "conhost.exe", "cmd.exe",
	"powershell.exe", "pwsh.exe", "wezterm-gui.exe", "alacritty.exe",
	"mintty.exe", "Hyper.exe", "Tabby.exe",
}

// ExeName returns the base name of a full image path (handles \ and /).
func ExeName(path string) string {
	path = strings.ReplaceAll(path, "\\", "/")
	return filepath.Base(path)
}

// IsTerminal reports whether exe (full path or base name) is in apps
// (case-insensitive).
func IsTerminal(exe string, apps []string) bool {
	name := ExeName(exe)
	if name == "" || name == "." || name == "/" {
		return false
	}
	for _, a := range apps {
		if strings.EqualFold(a, name) {
			return true
		}
	}
	return false
}

// TargetChanged reports whether the foreground app at paste time differs
// from the one at press time (compared by app — exe name — so switching
// windows or tabs inside the same app still pastes). Unknown on either side
// is not a change.
func TargetChanged(startApp, pasteApp string) bool {
	a, b := strings.ToLower(ExeName(startApp)), strings.ToLower(ExeName(pasteApp))
	return a != "" && a != "." && b != "" && b != "." && a != b
}
