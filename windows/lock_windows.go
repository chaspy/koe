//go:build windows

package main

import (
	"os"
	"path/filepath"

	"github.com/chaspy/koe/windows/core"
	"golang.org/x/sys/windows"
)

// Lock recording (config lockRecording, IMP-7): the text of a lock recording
// is not pasted. It goes to Documents\Koe\<date-time>.txt and the clipboard,
// and the file is opened in the default editor (mac: the same).

// lockDir is Documents\Koe (the Documents folder may be moved to OneDrive).
func lockDir() string {
	docs, err := windows.KnownFolderPath(windows.FOLDERID_Documents, 0)
	if err != nil || docs == "" {
		home, _ := os.UserHomeDir()
		docs = filepath.Join(home, "Documents")
	}
	return filepath.Join(docs, "Koe")
}

// saveLocked puts the text of a lock recording on the clipboard first (so
// minutes of talk are never lost when the file cannot be written; mac: the
// same), then writes it to a file and opens the file. Returns the file path.
func (a *App) saveLocked(u *utterance, text string) (string, error) {
	if err := setClipboardText(text); err != nil {
		a.log.Printf("lock_clipboard_failed err=%s", core.ErrWithoutDir(err))
	}
	dir := lockDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	path := core.LockFileName(dir, u.pressedAt)
	// UTF-8 with BOM so that Notepad on older Windows does not guess ANSI
	if err := os.WriteFile(path, append([]byte("\xEF\xBB\xBF"), core.ToCRLF(text)+"\r\n"...), 0o644); err != nil {
		return "", err
	}
	openURL(path)
	return path, nil
}
