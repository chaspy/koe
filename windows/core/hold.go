package core

import "time"

// Action is what the app should do after a key event.
type Action int

const (
	ActNone   Action = iota
	ActStart         // hotkey pressed: start recording
	ActFinish        // released after MinHold (or the stop tap in toggle mode): stop and transcribe
	ActShort         // released too early: discard silently
	ActCancel        // another key while holding: discard
	ActLatch         // toggle mode: a tap started recording; keep recording until the next tap
)

func (a Action) String() string {
	return [...]string{"none", "start", "finish", "short", "cancel", "latch"}[a]
}

// DefaultTapMax: in toggle mode a press shorter than this is a tap.
const DefaultTapMax = 500 * time.Millisecond

// HoldTracker turns low-level key events into push-to-talk actions.
// It is driven from one goroutine only.
//
// Hold mode: press starts, release finishes (or ActShort below MinHold);
// another key while held cancels.
//
// Toggle mode: press starts recording at once. Released within TapMax with no
// other key in between, it latches (ActLatch) and keeps recording; the next
// press of the hotkey without another key stops it (ActFinish). While latched,
// other keys do not cancel. A long first press behaves like hold mode.
type HoldTracker struct {
	HotkeyVK uint32
	MinHold  time.Duration
	Toggle   bool
	TapMax   time.Duration // 0 = DefaultTapMax

	down      bool
	cancelled bool
	other     bool // another key went down during this press
	latched   bool
	pressedAt time.Time
	startedAt time.Time
}

func (h *HoldTracker) tapMax() time.Duration {
	if h.TapMax > 0 {
		return h.TapMax
	}
	return DefaultTapMax
}

// Down handles a key-down. Auto-repeat of the hotkey is ignored.
func (h *HoldTracker) Down(vk uint32, now time.Time) Action {
	if vk == h.HotkeyVK {
		if h.down {
			return ActNone // auto-repeat
		}
		h.down = true
		h.cancelled = false
		h.other = false
		h.pressedAt = now
		if h.latched {
			return ActNone // the stop tap; decided on release
		}
		h.startedAt = now
		return ActStart
	}
	if !h.down {
		return ActNone
	}
	h.other = true
	if h.latched {
		return ActNone // e.g. Ctrl+C while latched: keep recording
	}
	if !h.cancelled {
		h.cancelled = true
		return ActCancel
	}
	return ActNone
}

// Up handles a key-up. Returns the recording duration too (for the stop tap
// in toggle mode: from the start of the recording).
func (h *HoldTracker) Up(vk uint32, now time.Time) (Action, time.Duration) {
	if vk != h.HotkeyVK || !h.down {
		return ActNone, 0
	}
	h.down = false
	held := now.Sub(h.pressedAt)
	if h.latched {
		if h.other {
			return ActNone, held // the hotkey was used as a modifier; keep recording
		}
		h.latched = false
		return ActFinish, now.Sub(h.startedAt)
	}
	if h.cancelled {
		h.cancelled = false
		return ActNone, held
	}
	if h.Toggle && held < h.tapMax() {
		h.latched = true
		return ActLatch, held
	}
	if held < h.MinHold {
		return ActShort, held
	}
	return ActFinish, held
}

// Holding reports whether the hotkey is currently held (and not cancelled).
func (h *HoldTracker) Holding() bool { return h.down && !h.cancelled }

// Latched reports whether a toggle recording is running with the key up.
func (h *HoldTracker) Latched() bool { return h.latched }

// PressedAt is the time of the current / last press.
func (h *HoldTracker) PressedAt() time.Time { return h.pressedAt }

// Reset forgets any press in progress and any latched recording.
func (h *HoldTracker) Reset() {
	h.down = false
	h.cancelled = false
	h.other = false
	h.latched = false
}

// SetHotkey switches to another hotkey. A press in progress is forgotten so
// the release of the old key cannot finish a recording.
func (h *HoldTracker) SetHotkey(vk uint32) {
	if vk == h.HotkeyVK {
		return
	}
	h.HotkeyVK = vk
	h.Reset()
}

// SetToggle switches between hold and toggle mode, forgetting any press.
func (h *HoldTracker) SetToggle(on bool) {
	if on == h.Toggle {
		return
	}
	h.Toggle = on
	h.Reset()
}
