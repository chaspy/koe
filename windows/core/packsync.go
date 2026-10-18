package core

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// GhSource is a parsed "gh:owner/repo/path/to/pack.txt".
type GhSource struct{ Owner, Repo, Path string }

// ParseGhSource parses a gh: pack source.
func ParseGhSource(src string) (GhSource, bool) {
	if !strings.HasPrefix(src, "gh:") {
		return GhSource{}, false
	}
	parts := strings.SplitN(strings.TrimPrefix(src, "gh:"), "/", 3)
	if len(parts) != 3 || !safeSegment(parts[0], 39) || !safeSegment(parts[1], 100) || len(parts[2]) > 512 {
		return GhSource{}, false
	}
	for _, seg := range strings.Split(parts[2], "/") {
		if !safeSegment(seg, 255) {
			return GhSource{}, false
		}
	}
	return GhSource{parts[0], parts[1], parts[2]}, true
}

// safeSegment: 1..max characters from [A-Za-z0-9._-], and not "." or "..".
func safeSegment(s string, max int) bool {
	if s == "" || len(s) > max || s == "." || s == ".." {
		return false
	}
	for _, c := range s {
		ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

// GhArgs are the gh CLI arguments that fetch the raw file.
func (g GhSource) GhArgs() []string {
	return []string{"api", "repos/" + g.Owner + "/" + g.Repo + "/contents/" + g.Path, "-H", "Accept: application/vnd.github.raw"}
}

// ValidPackText: non-empty text that is not a JSON error body.
func ValidPackText(b []byte) bool {
	s := strings.TrimSpace(string(b))
	return s != "" && !strings.HasPrefix(s, "{")
}

// SyncDue: dest is missing or older than a day.
func SyncDue(dest string, now time.Time) bool {
	fi, err := os.Stat(dest)
	return err != nil || now.Sub(fi.ModTime()) >= 24*time.Hour
}

// SyncPackSources fetches each gh: source (at most once a day) into dir.
// run executes gh with args and returns stdout. Failures are logged and ignored.
func SyncPackSources(sources []string, dir string, now time.Time, run func(args []string) ([]byte, error), logf func(string, ...any)) {
	if len(sources) == 0 {
		return
	}
	_ = os.MkdirAll(dir, 0o755)
	for _, src := range sources {
		g, ok := ParseGhSource(src)
		if !ok {
			logf("pack_sync_failed source=%q reason=unsupported (only gh:owner/repo/path)", src)
			continue
		}
		dest := filepath.Join(dir, filepath.Base(g.Path))
		if !SyncDue(dest, now) {
			logf("pack_sync_skip source=%q (synced within 24h)", src)
			continue
		}
		start := time.Now()
		out, err := run(g.GhArgs())
		if err != nil || !ValidPackText(out) {
			if err == nil {
				err = fmt.Errorf("not a pack (%d bytes)", len(out))
			}
			logf("pack_sync_failed source=%q err=%v ms=%d", src, err, time.Since(start).Milliseconds())
			continue
		}
		if err := os.WriteFile(dest, out, 0o644); err != nil {
			logf("pack_sync_failed source=%q write err=%v", src, err)
			continue
		}
		logf("pack_synced source=%q terms=%d ms=%d", src, len(ParseGlossary(string(out))), time.Since(start).Milliseconds())
	}
}
