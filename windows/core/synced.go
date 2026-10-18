package core

import (
	"path/filepath"
	"strings"
	"unicode"
)

// Limits for packs synced from packSources (shared repositories). Their terms
// still go into the whisper prompt and the receiver notes; these rules only
// decide what Autocorrect may insert. macos/Sources/Koe/SyncedTerms.swift has
// the same rules.
const (
	syncedTermMaxLen    = 40
	syncedTermMaxSpaces = 2
	shellCharacters     = "`$;|&<>(){}[]\\\"'*?!~#"
)

// UsableSyncedTerm: a term from a synced pack replaces text only when it is
// short, has no control characters or shell metacharacters, and at most a
// couple of spaces.
func UsableSyncedTerm(term string) bool {
	if term == "" || runeLen(term) > syncedTermMaxLen || strings.ContainsAny(term, shellCharacters) {
		return false
	}
	for _, r := range term {
		if unicode.IsControl(r) || (unicode.Is(unicode.Cf, r) && r != 0x200D) {
			return false
		}
	}
	return strings.Count(term, " ") <= syncedTermMaxSpaces
}

// MarkSyncedPacks sets Synced on packs that are the local copy of a
// packSources entry (userDir/<file name of a gh: source>).
func MarkSyncedPacks(packs []Pack, userDir string, sources []string) []Pack {
	names := map[string]bool{}
	for _, src := range sources {
		if g, ok := ParseGhSource(src); ok {
			names[filepath.Base(g.Path)] = true
		}
	}
	out := make([]Pack, len(packs))
	for i, p := range packs {
		p.Synced = filepath.Clean(filepath.Dir(p.Path)) == filepath.Clean(userDir) && names[filepath.Base(p.Path)]
		out[i] = p
	}
	return out
}
