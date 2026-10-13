package core

import "time"

// Action is what the app should do after a key event.
type Action int

const (
	ActNone   Action = iota
	ActStart         // hotkey pressed: start recording
	ActFinish        // released after MinHold: stop and transcribe
	ActShort         // released too early: discard silently
	ActCancel        // another key while holding: discard
)

func (a Action) String() string {
	return [...]string{"none", "start", "finish", "short", "cancel"}[a]
}

// HoldTracker turns low-level key events into push-to-talk actions.
// It is driven from one goroutine only.
type HoldTracker struct {
	HotkeyVK uint32
	MinHold  time.Duration

	down      bool
	cancelled bool
	pressedAt time.Time
}

// Down handles a key-down. Auto-repeat of the hotkey is ignored.
func (h *HoldTracker) Down(vk uint32, now time.Time) Action {
	if vk == h.HotkeyVK {
		if h.down {
			return ActNone // auto-repeat
		}
		h.down = true
		h.cancelled = false
		h.pressedAt = now
		return ActStart
	}
	if h.down && !h.cancelled {
		h.cancelled = true
		return ActCancel
	}
	return ActNone
}

// Up handles a key-up. Returns the hold duration too.
func (h *HoldTracker) Up(vk uint32, now time.Time) (Action, time.Duration) {
	if vk != h.HotkeyVK || !h.down {
		return ActNone, 0
	}
	h.down = false
	held := now.Sub(h.pressedAt)
	if h.cancelled {
		h.cancelled = false
		return ActNone, held
	}
	if held < h.MinHold {
		return ActShort, held
	}
	return ActFinish, held
}

// Holding reports whether the hotkey is currently held (and not cancelled).
func (h *HoldTracker) Holding() bool { return h.down && !h.cancelled }

// PressedAt is the time of the current / last press.
func (h *HoldTracker) PressedAt() time.Time { return h.pressedAt }

// SetHotkey switches to another hotkey. A press in progress is forgotten so
// the release of the old key cannot finish a recording.
func (h *HoldTracker) SetHotkey(vk uint32) {
	if vk == h.HotkeyVK {
		return
	}
	h.HotkeyVK = vk
	h.down = false
	h.cancelled = false
}
