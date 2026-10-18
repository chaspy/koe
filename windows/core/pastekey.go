package core

import "strings"

// Paste keys Koe can send after putting the text on the clipboard.
const (
	PasteCtrlV       = "ctrl+v"
	PasteCtrlShiftV  = "ctrl+shift+v"
	PasteShiftInsert = "shift+insert"
)

// DefaultPasteKeys are the apps (exe name, lower case) whose paste is not
// Ctrl+V out of the box. In them Ctrl+V reaches the program inside as a raw
// ^V, so nothing is typed (and a CLI such as Claude Code may read it as
// "paste an image"). Every other app gets Ctrl+V.
//
//   - Windows Terminal: Ctrl+V is only in the settings.json written on first
//     run (userDefaults.json), so older or edited settings lack it;
//     Ctrl+Shift+V is in the built-in defaults.json
//   - WezTerm, Alacritty, Hyper, Tabby: Ctrl+Shift+V
//   - mintty (Git Bash): Shift+Insert (Ctrl+Shift+V needs an option)
//
// The classic console (cmd.exe, PowerShell, conhost) pastes with Ctrl+V.
var DefaultPasteKeys = map[string]string{
	"windowsterminal.exe": PasteCtrlShiftV,
	"wezterm-gui.exe":     PasteCtrlShiftV,
	"alacritty.exe":       PasteCtrlShiftV,
	"hyper.exe":           PasteCtrlShiftV,
	"tabby.exe":           PasteCtrlShiftV,
	"mintty.exe":          PasteShiftInsert,
}

// ValidPasteKey reports whether k is one of the paste keys.
func ValidPasteKey(k string) bool {
	return k == PasteCtrlV || k == PasteCtrlShiftV || k == PasteShiftInsert
}

// PasteKeyFor is the paste key for exe (full path or name): the config
// "pasteKeys" entry if there is a valid one, else DefaultPasteKeys when
// terminals is on (config "terminalPasteKeys", default off), else Ctrl+V.
func PasteKeyFor(exe string, overrides map[string]string, terminals bool) string {
	name := strings.ToLower(ExeName(exe))
	for app, k := range overrides {
		if strings.EqualFold(app, name) {
			if k = strings.ToLower(strings.ReplaceAll(k, " ", "")); ValidPasteKey(k) {
				return k
			}
		}
	}
	if k, ok := DefaultPasteKeys[name]; ok && terminals {
		return k
	}
	return PasteCtrlV
}
