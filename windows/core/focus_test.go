package core

import (
	"testing"
	"time"
)

func TestFocusDecision(t *testing.T) {
	for _, tc := range []struct {
		start, now string
		age        time.Duration
		on         bool
		want       string
	}{
		{"WindowsTerminal.exe", "windowsterminal.exe", 3 * time.Second, true, FocusPaste},
		{"WindowsTerminal.exe", "chrome.exe", 3 * time.Second, true, FocusRestore},
		{"WindowsTerminal.exe", "chrome.exe", 20 * time.Second, true, FocusRestore},
		{"WindowsTerminal.exe", "chrome.exe", 20*time.Second + time.Millisecond, true, FocusBlock},
		{"WindowsTerminal.exe", "chrome.exe", 3 * time.Second, false, FocusBlock},
		{"", "chrome.exe", 3 * time.Second, true, FocusPaste},
	} {
		if got := FocusDecision(tc.start, tc.now, tc.age, tc.on); got != tc.want {
			t.Errorf("%s -> %s age=%v on=%v: %s, want %s", tc.start, tc.now, tc.age, tc.on, got, tc.want)
		}
	}
	if !DefaultConfig().RestoreFocus {
		t.Fatal("restoreFocus is a bug fix: on by default")
	}
	if c, _ := ParseConfig([]byte(`{"restoreFocus":false}`)); c.RestoreFocus {
		t.Fatal("restoreFocus false not read")
	}
}
