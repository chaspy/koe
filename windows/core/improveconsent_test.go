package core

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestImproveConsent(t *testing.T) {
	cmd := DefaultImproveCommand
	none := ImproveConsent{}
	agreed := ImproveConsent{Command: cmd}
	for _, c := range []struct {
		name           string
		enabled        bool
		consent        ImproveConsent
		command        string
		needs, maySend bool
	}{
		{"off: nothing to ask, nothing sent", false, none, cmd, false, false},
		{"written as true in config.json, never asked", true, none, cmd, true, false},
		{"agreed to this command", true, agreed, cmd, false, true},
		{"destination changed since", true, agreed, "other-llm --stdin", true, false},
		{"off after agreeing", false, agreed, cmd, false, false},
	} {
		if got := ImproveNeedsConsent(c.enabled, c.consent, c.command); got != c.needs {
			t.Fatal(c.name, "needs", got)
		}
		if got := ImproveMaySend(c.enabled, c.consent, c.command); got != c.maySend {
			t.Fatal(c.name, "maySend", got)
		}
	}
}

func TestImproveConsentFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "improve_consent.json")
	if c := ReadImproveConsent(p); c.Command != "" {
		t.Fatal(c)
	}
	now := time.Date(2026, 10, 19, 4, 0, 0, 0, time.UTC)
	if err := WriteImproveConsent(p, DefaultImproveCommand, now); err != nil {
		t.Fatal(err)
	}
	c := ReadImproveConsent(p)
	if c.Command != DefaultImproveCommand || !c.At.Equal(now) {
		t.Fatal(c)
	}
	if err := os.WriteFile(p, []byte("{broken"), 0o600); err != nil {
		t.Fatal(err)
	}
	if c := ReadImproveConsent(p); c.Command != "" {
		t.Fatal("unreadable consent means: ask again", c)
	}
}
