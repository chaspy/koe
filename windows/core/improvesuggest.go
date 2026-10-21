package core

// The one-time suggestion to turn on the improvement loop (#184, macOS #169).
// The loop stays off; this only says that it exists. It is shown after
// SuggestAfterPastes pastes with the loop off, at most SuggestMaxShown times,
// SuggestSnooze apart, and never once improveEnabled has been decided (by the
// user from the tray or written in config.json). Counts only, never text.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	SuggestAfterPastes = 30
	SuggestSnooze      = 14 * 24 * time.Hour
	SuggestMaxShown    = 2
)

// SuggestState is kept in %APPDATA%\Koe\improve_suggest.json.
type SuggestState struct {
	PastedSinceShown int       `json:"pastedSinceShown"` // pastes with the loop off since the last suggestion (or ever)
	PastedTotal      int       `json:"pastedTotal"`      // all pastes with the loop off (the N in the text)
	Shown            int       `json:"shown"`
	LastShown        time.Time `json:"lastShown,omitempty"`
	NeverAgain       bool      `json:"neverAgain,omitempty"` // tray: 「改善ループの提案を出さない」
}

// ShouldSuggestImprove: undecided means improveEnabled was never set.
func ShouldSuggestImprove(s SuggestState, now time.Time, undecided bool) bool {
	if !undecided || s.NeverAgain || s.Shown >= SuggestMaxShown || s.PastedSinceShown < SuggestAfterPastes {
		return false
	}
	return s.LastShown.IsZero() || now.Sub(s.LastShown) >= SuggestSnooze
}

// SuggestPasted counts one paste with the loop off.
func SuggestPasted(s SuggestState) SuggestState {
	s.PastedSinceShown++
	s.PastedTotal++
	return s
}

// SuggestShown records that the suggestion was shown.
func SuggestShown(s SuggestState, now time.Time) SuggestState {
	s.Shown++
	s.LastShown = now
	s.PastedSinceShown = 0
	return s
}

// SuggestText is the hint shown in the tray (it points to the tray item, where turning on asks first).
func SuggestText(s SuggestState) string {
	return "ここまで " + strconv.Itoa(s.PastedTotal) + " 回話しました。トレイの「改善ループ: オフ（有効にすると使うほど賢くなります）」を押すと、" +
		"言い間違えられた語を覚えていきます（送る前に内容を確かめられます）"
}

// ReadSuggestState reads the state (zero when missing or unreadable).
func ReadSuggestState(path string) SuggestState {
	var s SuggestState
	if b, err := os.ReadFile(filepath.Clean(path)); err == nil {
		_ = json.Unmarshal(b, &s)
	}
	return s
}

// WriteSuggestState saves the state.
func WriteSuggestState(path string, s SuggestState) error {
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o600)
}

// ConfigHasKey reports whether config.json sets key (a value written by the
// user, an admin or the tray), as opposed to the default.
func ConfigHasKey(path, key string) bool {
	b, err := os.ReadFile(filepath.Clean(path))
	if err != nil || strings.TrimSpace(string(b)) == "" {
		return false
	}
	m := map[string]json.RawMessage{}
	if json.Unmarshal(b, &m) != nil {
		return false
	}
	_, ok := m[key]
	return ok
}
