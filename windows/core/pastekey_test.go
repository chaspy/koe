package core

import "testing"

func TestPasteKeyFor(t *testing.T) {
	for _, tc := range []struct {
		exe       string
		overrides map[string]string
		want      string
	}{
		{`C:\Program Files\WindowsApps\Microsoft.WindowsTerminal_1.21\WindowsTerminal.exe`, nil, PasteCtrlShiftV},
		{"wezterm-gui.exe", nil, PasteCtrlShiftV},
		{"Alacritty.exe", nil, PasteCtrlShiftV},
		{`C:\Program Files\Git\usr\bin\mintty.exe`, nil, PasteShiftInsert},
		{"cmd.exe", nil, PasteCtrlV},
		{"powershell.exe", nil, PasteCtrlV},
		{"slack.exe", nil, PasteCtrlV},
		{"", nil, PasteCtrlV},
		// config pasteKeys wins, case and spaces do not matter
		{"WindowsTerminal.exe", map[string]string{"windowsterminal.exe": "Ctrl + V"}, PasteCtrlV},
		{"myterm.exe", map[string]string{"MyTerm.exe": "shift+insert"}, PasteShiftInsert},
		// a key Koe cannot send falls back to the default
		{"wezterm-gui.exe", map[string]string{"wezterm-gui.exe": "ctrl+alt+v"}, PasteCtrlShiftV},
	} {
		if got := PasteKeyFor(tc.exe, tc.overrides, true); got != tc.want {
			t.Errorf("%q %v: %s, want %s", tc.exe, tc.overrides, got, tc.want)
		}
	}
	// terminalPasteKeys off (the default): Ctrl+V everywhere, except what
	// the user wrote in pasteKeys
	if got := PasteKeyFor("WindowsTerminal.exe", nil, false); got != PasteCtrlV {
		t.Errorf("off: %s", got)
	}
	if got := PasteKeyFor("wezterm-gui.exe", map[string]string{"wezterm-gui.exe": "ctrl+shift+v"}, false); got != PasteCtrlShiftV {
		t.Errorf("off with pasteKeys: %s", got)
	}
	// every default terminal has a paste key Koe can send
	for app, k := range DefaultPasteKeys {
		if !ValidPasteKey(k) || !IsTerminal(app, DefaultEnterApps) {
			t.Errorf("%s: %s (in DefaultEnterApps: %v)", app, k, IsTerminal(app, DefaultEnterApps))
		}
	}
}

func TestConfigPasteKeys(t *testing.T) {
	c, err := ParseConfig([]byte(`{"pasteKeys":{"foo.exe":"ctrl+shift+v"}}`))
	if err != nil || c.PasteKeys["foo.exe"] != PasteCtrlShiftV {
		t.Fatalf("%v %v", c.PasteKeys, err)
	}
	if d := DefaultConfig(); len(d.PasteKeys) != 0 || d.TerminalPasteKeys {
		t.Fatalf("new behaviour ships off: %v %v", d.PasteKeys, d.TerminalPasteKeys)
	}
	if c, _ := ParseConfig([]byte(`{"terminalPasteKeys":true}`)); !c.TerminalPasteKeys {
		t.Fatal("terminalPasteKeys not read")
	}
}
