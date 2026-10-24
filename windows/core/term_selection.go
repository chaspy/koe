package core

// Choosing the terms for whisper's initial prompt and learning aliases, kept the
// same as macOS (#184; macOS #227 / #228 TermSelection.swift and AliasLearning.swift,
// #196 / #234 prefix collisions):
//   - a term counts in an utterance when it or an alias is in the pasted text, and
//     again when an alias (including "~" ones) is in the raw text before
//     replacement. A misheard term never shows in the pasted text in its right
//     form, so without the raw count it would never reach the prompt.
//   - matches are on word boundaries only: "HTML" is not a hit for "HTM", nor
//     "bash" / "ssh" for "SH".
//   - a shorter term pulls a longer one down (HTM makes "HTML" come out as "HTM"),
//     so the longer terms that start with it go in first, and a replacement to the
//     shorter term never fires where the text already continues into the longer one.

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// UsageSample is one recent utterance: what was pasted and what whisper wrote.
type UsageSample struct {
	Pasted string
	Raw    string
}

// UsageSamples is how many recent utterances rank the terms (macOS: 300).
const UsageSamples = 300

// CountTermUsage scores each entry over the newest UsageSamples samples: +1 when
// the term or an alias is in the pasted text, +1 when an alias is in the raw text.
func CountTermUsage(entries []Entry, samples []UsageSample) map[string]int {
	if len(samples) > UsageSamples {
		samples = samples[len(samples)-UsageSamples:]
	}
	pasted := make([]string, len(samples))
	raw := make([]string, len(samples))
	for i, s := range samples {
		pasted[i], raw[i] = strings.ToLower(s.Pasted), strings.ToLower(s.Raw)
	}
	u := map[string]int{}
	for _, e := range entries {
		if n := entryUsage(e, pasted, raw); n > 0 {
			u[e.Term] = n
		}
	}
	return u
}

// entryUsage: each channel adds at most one per utterance (the term and aliases in
// pasted, the aliases in raw). pasted and raw are lowercased.
func entryUsage(e Entry, pasted, raw []string) int {
	var pastedKeys, rawKeys []correction
	for i, k := range append([]string{e.Term}, e.Aliases...) {
		if c, ok := usageKey(k); ok {
			pastedKeys = append(pastedKeys, c)
			if i > 0 {
				rawKeys = append(rawKeys, c)
			}
		}
	}
	n := 0
	for i := range pasted {
		if anyFound(pastedKeys, pasted[i]) {
			n++
		}
		if anyFound(rawKeys, raw[i]) {
			n++
		}
	}
	return n
}

// fillTerms adds each term (its longer terms first) while it fits in limit.
func fillTerms(order, all []string, limit int) []string {
	var out []string
	length := 0
	seen := map[string]bool{}
	for _, term := range order {
		for _, t := range append(LongerTerms(term, all), term) {
			if seen[t] || length+runeLen(t) > limit {
				continue
			}
			seen[t] = true
			out = append(out, t)
			length += runeLen(t) + 1
		}
	}
	return out
}

// RecentUsageSamples returns up to n utterances from the last 3 day folders
// (oldest first) with their pasted and raw text, for ranking the prompt's terms.
// An utterance that was not pasted still counts by its raw text (macOS: recentRecords).
func RecentUsageSamples(dir string, n int) []UsageSample {
	// day folders and the ids in them sort by time, so walking them in order is oldest first
	var out []UsageSample
	for _, d := range recentDayFolders(dir, 3) {
		names, _ := os.ReadDir(filepath.Join(dir, d))
		for _, f := range names {
			if !strings.HasSuffix(f.Name(), ".json") {
				continue
			}
			if s, ok := readUsageSample(filepath.Join(dir, d, f.Name())); ok {
				out = append(out, s)
			}
		}
	}
	return out[max(0, len(out)-n):]
}

func readUsageSample(path string) (UsageSample, bool) {
	r, ok := readRecord(path)
	if !ok {
		return UsageSample{}, false
	}
	s := UsageSample{}
	s.Pasted, _ = r["pasted"].(string)
	s.Raw, _ = r["raw"].(string)
	return s, s.Pasted != "" || s.Raw != ""
}

// usageKey: a term or alias (without "~", lowercased) as a word-boundary matcher; 2+ chars.
func usageKey(k string) (correction, bool) {
	k = strings.ToLower(strings.TrimPrefix(k, "~"))
	c, ok := newCorrection(k, Entry{})
	if !ok {
		// newCorrection skips an alias equal to the term; the term itself must still count
		c, ok = correction{wrong: k, head: k}, runeLen(k) >= 2
	}
	return c, ok && runeLen(c.head) >= 2
}

func anyFound(keys []correction, t string) bool {
	for _, k := range keys {
		if k.found(t) {
			return true
		}
	}
	return false
}

// found reports whether head occurs at a word boundary (and before follow, if set).
func (p correction) found(t string) bool {
	for i := 0; i < len(t); {
		j := strings.Index(t[i:], p.head)
		if j < 0 {
			return false
		}
		s := i + j
		if boundaryOK(t, s, s+len(p.head)) && (p.follow == nil || p.follow.MatchString(t[s+len(p.head):])) {
			return true
		}
		_, size := utf8.DecodeRuneInString(t[s:])
		i = s + size
	}
	return false
}

// LongerTerms are the terms that start with term and continue as one word: the next
// character is an ASCII letter/digit or katakana, with the same case (HTM → HTML,
// Java → JavaScript). Terms that continue after a space or symbol (CI → CI/CD,
// Claude → Claude Code) and ones that differ in case (PR → Prometheus) are separate words.
func LongerTerms(term string, terms []string) []string {
	var out []string
	if term == "" {
		return out
	}
	for _, t := range terms {
		if len(t) <= len(term) || !strings.HasPrefix(t, term) {
			continue
		}
		r, _ := utf8.DecodeRuneInString(t[len(term):])
		if r < utf8.RuneSelf && isASCIIAlnum(r) || isKatakana(r) {
			out = append(out, t)
		}
	}
	return out
}

// continuesInto: the text at a match (found, then after) already spells a longer term.
func continuesInto(right, found, after string, longer []string) bool {
	for _, l := range longer {
		l = strings.ToLower(l)
		if strings.HasPrefix(strings.ToLower(right+after), l) || strings.HasPrefix(strings.ToLower(found+after), l) {
			return true
		}
	}
	return false
}

func termsOf(entries []Entry) []string {
	out := make([]string, 0, len(entries))
	for _, e := range entries {
		out = append(out, e.Term)
	}
	return out
}

// commonJapanese are ordinary words that are never made a sure replacement
// (macOS TermRules.commonJapanese). English words are covered by
// improveAliasCommon: Windows has no system word list, so every ASCII-only alias
// is treated as possibly an English word (macOS does the same without /usr/share/dict/words).
var commonJapanese = map[string]bool{
	"これ": true, "それ": true, "あれ": true, "ここ": true, "そこ": true, "こと": true, "もの": true, "ため": true,
	"よう": true, "今日": true, "明日": true, "昨日": true, "今回": true, "次回": true, "自分": true, "相手": true,
	"会社": true, "仕事": true, "時間": true, "確認": true, "対応": true, "変更": true, "追加": true, "削除": true,
	"遅延": true, "返事": true, "不要": true, "必要": true, "普通": true, "問題": true, "お願い": true,
	"ありがとう": true, "ハウ": true, "オハウ": true, "オーケー": true, "オッケー": true, "ナイス": true,
	"ハロー": true, "グッド": true, "ベスト": true, "ナウ": true, "ユー": true, "ミー": true,
}

// improveAliasCommon: an alias that may be an ordinary word is never a sure replacement.
func improveAliasCommon(w string) bool {
	if improveCommon(w) || commonJapanese[w] {
		return true
	}
	for _, r := range w {
		if !isASCIILetter(r) {
			return false
		}
	}
	return true
}

// observeAliases counts each alias of term once per utterance it really appears in
// (word boundary), across runs (macOS AliasLearning.observedCounts). seen keeps one
// run from counting the same utterance twice.
func observeAliases(counts map[string]int, term string, aliases []string, transcript string, index int, seen map[string]bool) map[string]int {
	if counts == nil {
		counts = map[string]int{}
	}
	if transcript == "" {
		return counts
	}
	for _, a := range aliases {
		plain := strings.TrimPrefix(a, "~")
		key := term + "\x00" + plain + "\x00" + strconv.Itoa(index)
		c, ok := newCorrection(plain, Entry{Term: term})
		if seen[key] || !ok || !c.found(transcript) {
			continue
		}
		seen[key] = true
		counts[plain]++
	}
	return counts
}

// mergeAliases keeps the old aliases and adds the new ones; a "~x" goes when x became sure (macOS AliasLearning.merged).
func mergeAliases(old, learned []string) []string {
	sure := map[string]bool{}
	for _, a := range learned {
		if !strings.HasPrefix(a, "~") {
			sure[a] = true
		}
	}
	var keep []string
	for _, a := range old {
		if !strings.HasPrefix(a, "~") || !sure[strings.TrimPrefix(a, "~")] {
			keep = append(keep, a)
		}
	}
	out := uniqueSorted(append(keep, learned...))
	sort.Strings(out)
	return out
}
