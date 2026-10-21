package core

import (
	"errors"
	"io/fs"
	"path/filepath"
	"strings"
	"time"
)

// Lock recording and line breaks, the same rules as the mac app (IMP-7).
//
// Lock recording (config lockRecording, off by default): in hold mode, two
// quick taps of the hotkey (see HoldTracker.DoubleTapLock) keep recording
// with the key up, without a time limit; the next press ends it. The text is
// not pasted: it is written to Documents\Koe\<date-time>.txt, put on the
// clipboard and the file is opened. Other keys and the mouse do not stop it.
//
// Line breaks (config lineBreaks, off by default): outside terminals, each
// whisper segment goes on its own line (Google Docs and other long text).
// A lock recording always keeps the lines.

// DoubleTapGap: the second tap must start within this time after the first
// tap was released.
const DoubleTapGap = 500 * time.Millisecond

// KeepLines reports whether whisper's segments are joined with line breaks
// instead of spaces: always for a lock recording, otherwise when lineBreaks
// is on and the app of the press is not a terminal (terminals would run each
// line as a command).
func KeepLines(lineBreaks, locked bool, exe string, enterApps []string) bool {
	return locked || (lineBreaks && !IsTerminal(exe, enterApps))
}

// LockFileName is the file a lock recording is written to, named after the
// time of the press (mac: yyyy-MM-dd-HHmm.txt).
func LockFileName(dir string, pressedAt time.Time) string {
	return filepath.Join(dir, pressedAt.Format("2006-01-02-1504")+".txt")
}

// LockTimeout is how long Koe waits for whisper to transcribe a recording
// of the given length: lock recordings can be minutes long and the CPU build
// may be slower than real time. At least the usual 120 s.
func LockTimeout(seconds float64) time.Duration {
	d := time.Duration(seconds*3) * time.Second
	if d < 120*time.Second {
		return 120 * time.Second
	}
	return d
}

// ToCRLF turns line breaks into Windows ones for the clipboard and files
// (some apps show a bare LF as nothing).
func ToCRLF(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	return strings.ReplaceAll(s, "\n", "\r\n")
}

// ErrWithoutDir is err's text with any file path cut to its file name, for
// history records and messages (no user folder names).
func ErrWithoutDir(err error) string {
	var pe *fs.PathError
	if errors.As(err, &pe) {
		name := pe.Path[strings.LastIndexAny(pe.Path, `/\`)+1:] // both separators, whatever the OS
		return pe.Op + " " + name + ": " + pe.Err.Error()
	}
	return err.Error()
}
