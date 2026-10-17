package core

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Consent-based update prompt (the same rules as macOS, UpdatePrompt.swift).
// Koe never replaces itself on its own: when a newer release is found it asks
// once, when Koe is settled (not recording or transcribing, and not used in
// the last 30 s). "Later" keeps it quiet for 24 hours of this run (the next
// start asks again). A release with no changes for this platform is not asked
// about; the tray item for the new version stays either way.
const (
	UpdateQuietAfterUse = 30 * time.Second
	UpdateSnooze        = 24 * time.Hour
)

// MessageBox flags of the update prompt (winuser.h).
const (
	MBYesNo         = 0x00000004
	MBIconInfo      = 0x00000040
	MBDefButton2    = 0x00000100
	MBSetForeground = 0x00010000
	MBTopmost       = 0x00040000
	IDYes           = 6
)

// UpdatePromptBoxFlags: Yes = update now, No = later. People may be typing
// in another app when it appears, so Enter / Esc must never start the
// update: No is the default button (Enter = later), there is no Cancel
// button (Esc does nothing), and the box does not take the foreground
// (no MB_SETFOREGROUND; it is only shown on top).
const UpdatePromptBoxFlags = MBYesNo | MBIconInfo | MBDefButton2 | MBTopmost

// ShouldPromptUpdate decides whether to ask now. lastUsed / snoozedUntil zero = never.
func ShouldPromptUpdate(now time.Time, available string, busy bool, lastUsed, snoozedUntil time.Time, noChanges bool) bool {
	if available == "" || busy || noChanges {
		return false
	}
	if !lastUsed.IsZero() && now.Sub(lastUsed) < UpdateQuietAfterUse {
		return false
	}
	return snoozedUntil.IsZero() || !now.Before(snoozedUntil)
}

// ChangelogSummary returns the first item of the platform ("macOS" /
// "Windows") subsection of "## <version>" in CHANGELOG.md as one line
// (markdown ** and ` removed, at most maxRunes). noChanges when that item is
// "No changes.". ("", false) if not found.
func ChangelogSummary(md, version, platform string, maxRunes int) (line string, noChanges bool) {
	inVersion, inPlatform := false, false
	for _, raw := range strings.Split(md, "\n") {
		l := strings.TrimSpace(raw)
		if strings.HasPrefix(l, "## ") {
			if inVersion {
				break
			}
			head := strings.TrimPrefix(l, "## ")
			inVersion = head == version || strings.HasPrefix(head, version+" ")
			continue
		}
		if !inVersion {
			continue
		}
		if strings.HasPrefix(l, "### ") {
			inPlatform = strings.EqualFold(strings.TrimSpace(strings.TrimPrefix(l, "### ")), platform)
			continue
		}
		if !inPlatform || !strings.HasPrefix(l, "- ") {
			continue
		}
		t := strings.TrimPrefix(l, "- ")
		if strings.HasPrefix(strings.ToLower(t), "no changes") {
			return "", true
		}
		t = strings.NewReplacer("**", "", "`", "").Replace(t)
		if r := []rune(t); len(r) > maxRunes {
			t = string(r[:maxRunes-1]) + "…"
		}
		return t, false
	}
	return "", false
}

// RawBase serves repository files at a ref (no REST API, so no rate limit).
const RawBase = "https://raw.githubusercontent.com"

// FetchChangelog downloads CHANGELOG.md of repo at tag from rawBase.
func FetchChangelog(ctx context.Context, rawBase, repo, tag, userAgent string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(rawBase, "/")+"/"+repo+"/"+tag+"/CHANGELOG.md", nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", userAgent)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("CHANGELOG.md: HTTP %d", resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	return string(b), err
}
