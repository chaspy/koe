package core

import (
	"errors"
	"fmt"
	"io/fs"
	"path/filepath"
	"testing"
	"time"
)

const lockHotkey, lockOtherKey = 0xA5, 0x56

func lockMs(n int) time.Duration { return time.Duration(n) * time.Millisecond }

func TestHoldTrackerDoubleTapLockOff(t *testing.T) {
	t0 := time.Now()

	// Off (default): two quick taps are two short presses, as before.
	h := HoldTracker{HotkeyVK: lockHotkey, MinHold: lockMs(300)}
	h.Down(lockHotkey, t0)
	h.Up(lockHotkey, t0.Add(lockMs(100)))
	h.Down(lockHotkey, t0.Add(lockMs(300)))
	if a, _ := h.Up(lockHotkey, t0.Add(lockMs(400))); a != ActShort {
		t.Fatal("off: second tap", a)
	}
}

func TestHoldTrackerDoubleTapLockLocksAndStops(t *testing.T) {
	t0 := time.Now()

	// On: tap, then a tap starting within 500 ms of the release locks.
	h := HoldTracker{HotkeyVK: lockHotkey, MinHold: lockMs(300), DoubleTapLock: true}
	h.Down(lockHotkey, t0)
	if a, _ := h.Up(lockHotkey, t0.Add(lockMs(100))); a != ActShort {
		t.Fatal("first tap", a)
	}
	if h.Down(lockHotkey, t0.Add(lockMs(500))) != ActStart {
		t.Fatal("second press starts the recording")
	}
	if a, _ := h.Up(lockHotkey, t0.Add(lockMs(600))); a != ActLock || !h.Latched() {
		t.Fatal("second tap locks", a)
	}
	// Other keys (Ctrl+C, typing) do not stop it.
	if h.Down(lockOtherKey, t0.Add(lockMs(700))) != ActNone {
		t.Fatal("other key while locked")
	}
	h.Up(lockOtherKey, t0.Add(lockMs(750)))
	// The next press ends it; the duration is from the second press.
	if h.Down(lockHotkey, t0.Add(lockMs(60_000))) != ActNone {
		t.Fatal("stop press")
	}
	if a, d := h.Up(lockHotkey, t0.Add(lockMs(60_100))); a != ActFinish || d != lockMs(59_600) {
		t.Fatal("stop", a, d)
	}
	// A third quick tap after the stop is a new short tap, not another lock.
	h.Down(lockHotkey, t0.Add(lockMs(60_300)))
	if a, _ := h.Up(lockHotkey, t0.Add(lockMs(60_350))); a != ActShort {
		t.Fatal("after stop", a)
	}
}

func TestHoldTrackerDoubleTapLockOtherPairs(t *testing.T) {
	t0 := time.Now()
	h := HoldTracker{HotkeyVK: lockHotkey, MinHold: lockMs(300), DoubleTapLock: true}

	// Too slow: the second press starts 500 ms or more after the release.
	h.Reset()
	h.Down(lockHotkey, t0)
	h.Up(lockHotkey, t0.Add(lockMs(100)))
	h.Down(lockHotkey, t0.Add(lockMs(600)))
	if a, _ := h.Up(lockHotkey, t0.Add(lockMs(700))); a != ActShort {
		t.Fatal("slow second tap", a)
	}

	// A quick tap then a long hold is an ordinary recording.
	h.Reset()
	h.Down(lockHotkey, t0)
	h.Up(lockHotkey, t0.Add(lockMs(100)))
	h.Down(lockHotkey, t0.Add(lockMs(200)))
	if a, _ := h.Up(lockHotkey, t0.Add(lockMs(2000))); a != ActFinish || h.Latched() {
		t.Fatal("tap then hold", a)
	}
	// ...and does not count as the first tap of a double tap.
	h.Down(lockHotkey, t0.Add(lockMs(2100)))
	if a, _ := h.Up(lockHotkey, t0.Add(lockMs(2150))); a != ActShort {
		t.Fatal("after hold", a)
	}

	// A press used as a shortcut (cancelled) between the taps breaks the pair.
	h.Reset()
	h.Down(lockHotkey, t0)
	h.Up(lockHotkey, t0.Add(lockMs(50)))
	h.Down(lockHotkey, t0.Add(lockMs(100)))
	h.Down(lockOtherKey, t0.Add(lockMs(120)))
	h.Up(lockHotkey, t0.Add(lockMs(150)))
	h.Down(lockHotkey, t0.Add(lockMs(200)))
	if a, _ := h.Up(lockHotkey, t0.Add(lockMs(250))); a != ActShort {
		t.Fatal("after cancelled press", a)
	}
}

func TestHoldTrackerDoubleTapLockToggleAndSetting(t *testing.T) {
	t0 := time.Now()

	// Toggle mode is unchanged by the setting.
	h := HoldTracker{HotkeyVK: lockHotkey, MinHold: lockMs(300), Toggle: true, DoubleTapLock: true}
	h.Down(lockHotkey, t0)
	if a, _ := h.Up(lockHotkey, t0.Add(lockMs(100))); a != ActLatch {
		t.Fatal("toggle", a)
	}

	// Turning it off forgets the first tap.
	h = HoldTracker{HotkeyVK: lockHotkey, MinHold: lockMs(300), DoubleTapLock: true}
	h.Down(lockHotkey, t0)
	h.Up(lockHotkey, t0.Add(lockMs(100)))
	h.SetDoubleTapLock(false)
	h.SetDoubleTapLock(true)
	h.Down(lockHotkey, t0.Add(lockMs(200)))
	if a, _ := h.Up(lockHotkey, t0.Add(lockMs(250))); a != ActShort {
		t.Fatal("after SetDoubleTapLock", a)
	}
}

func TestKeepLines(t *testing.T) {
	apps := DefaultEnterApps
	cases := []struct {
		lineBreaks, locked bool
		exe                string
		want               bool
	}{
		{false, false, "WINWORD.EXE", false}, // default: joined with spaces
		{true, false, "WINWORD.EXE", true},
		{true, false, "chrome.exe", true},
		{true, false, "WindowsTerminal.exe", false}, // terminals: one line, never Enter
		{false, true, "WindowsTerminal.exe", true},  // lock recording goes to a file
		{false, true, "", true},
	}
	for _, c := range cases {
		if got := KeepLines(c.lineBreaks, c.locked, c.exe, apps); got != c.want {
			t.Errorf("KeepLines(%v, %v, %q) = %v", c.lineBreaks, c.locked, c.exe, got)
		}
	}
}

func TestCleanServerTextLines(t *testing.T) {
	raw := "\n こんにちは \n\n 今日は晴れです\r\n"
	if got := CleanServerTextLines(raw, false); got != "こんにちは 今日は晴れです" {
		t.Errorf("joined: %q", got)
	}
	if got := CleanServerTextLines(raw, true); got != "こんにちは\n今日は晴れです" {
		t.Errorf("lines: %q", got)
	}
	if CleanServerText(raw) != CleanServerTextLines(raw, false) {
		t.Error("CleanServerText changed")
	}
}

func TestLockFileName(t *testing.T) {
	at := time.Date(2026, 10, 18, 9, 5, 59, 0, time.Local)
	if got := LockFileName(`C:\Users\example\Documents\Koe`, at); got != filepath.Join(`C:\Users\example\Documents\Koe`, "2026-10-18-0905.txt") {
		t.Error(got)
	}
}

func TestLockTimeout(t *testing.T) {
	for _, c := range []struct {
		s    float64
		want time.Duration
	}{{0, 120 * time.Second}, {10, 120 * time.Second}, {40, 120 * time.Second}, {60, 180 * time.Second}, {600, 1800 * time.Second}} {
		if got := LockTimeout(c.s); got != c.want {
			t.Errorf("LockTimeout(%v) = %v", c.s, got)
		}
	}
}

func TestToCRLF(t *testing.T) {
	if got := ToCRLF("a\nb\r\nc"); got != "a\r\nb\r\nc" {
		t.Errorf("%q", got)
	}
	if ToCRLF("abc") != "abc" {
		t.Error("no newline")
	}
}

func TestConfigLockAndLineBreaksDefaultOff(t *testing.T) {
	c := DefaultConfig()
	if c.LineBreaks || c.LockRecording {
		t.Fatal("must default off")
	}
	c, err := ParseConfig([]byte(`{"lineBreaks": true, "lockRecording": true}`))
	if err != nil || !c.LineBreaks || !c.LockRecording {
		t.Fatal(c.LineBreaks, c.LockRecording, err)
	}
}

func TestErrWithoutDir(t *testing.T) {
	err := &fs.PathError{Op: "open", Path: `C:\Users\someone\Documents\Koe\2026-10-18-0905.txt`, Err: errors.New("Access is denied.")}
	if got := ErrWithoutDir(fmt.Errorf("save: %w", err)); got != "open 2026-10-18-0905.txt: Access is denied." {
		t.Error(got)
	}
	if got := ErrWithoutDir(errors.New("disk full")); got != "disk full" {
		t.Error(got)
	}
}
