package core

import "time"

// What Koe does at paste time when the foreground app may have changed
// (BUG-FOCUS; macos/Sources/Koe/PasteTarget.swift decide has the same rule).
const (
	FocusPaste   = "paste"   // same app: paste
	FocusRestore = "restore" // another app came to the front: bring back the window of the press, then paste
	FocusBlock   = "block"   // keep the text on the clipboard (target_changed)
)

// MaxRestoreAge: past this long after the press Koe no longer brings the
// window back (the user may have moved on).
const MaxRestoreAge = 20 * time.Second

// FocusDecision decides for the app at press time (startApp) and at paste
// time (pasteApp), compared like TargetChanged.
func FocusDecision(startApp, pasteApp string, sincePress time.Duration, restore bool) string {
	if !TargetChanged(startApp, pasteApp) {
		return FocusPaste
	}
	if restore && sincePress <= MaxRestoreAge {
		return FocusRestore
	}
	return FocusBlock
}
