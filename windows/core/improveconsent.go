package core

// Consent for the improvement loop (#184). improveEnabled can also be written
// straight into config.json (by the user or an admin). Like the macOS config
// import, which asks before turning the loop on, Windows asks once per
// destination: nothing is sent until the user has said yes to this exact
// improveCommand. The consent is kept apart from config.json, in
// %APPDATA%\Koe\improve_consent.json, so writing config.json alone never skips it.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// ImproveConsent is the destination the user agreed to, and when.
type ImproveConsent struct {
	Command string    `json:"command"`
	At      time.Time `json:"at"`
}

// ImproveNeedsConsent: the loop is on, but the user has not said yes to this
// command (never asked, or the destination changed since).
func ImproveNeedsConsent(enabled bool, c ImproveConsent, command string) bool {
	return enabled && c.Command != command
}

// ImproveMaySend: send only when the loop is on and the user agreed to this command.
func ImproveMaySend(enabled bool, c ImproveConsent, command string) bool {
	return enabled && !ImproveNeedsConsent(enabled, c, command)
}

// ReadImproveConsent reads the consent (empty when missing or unreadable: ask).
func ReadImproveConsent(path string) ImproveConsent {
	var c ImproveConsent
	if b, err := os.ReadFile(filepath.Clean(path)); err == nil {
		_ = json.Unmarshal(b, &c)
	}
	return c
}

// WriteImproveConsent records that the user said yes to command.
func WriteImproveConsent(path, command string, now time.Time) error {
	b, err := json.MarshalIndent(ImproveConsent{Command: command, At: now}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o600)
}
