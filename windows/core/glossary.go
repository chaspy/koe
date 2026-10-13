// Package core holds the platform-independent logic of Koe for Windows.
// It is a port of the Glossary / Settings logic in macos/Sources/Koe/main.swift
// and is unit-tested on any OS (go test ./core).
package core

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Entry is one line of a glossary / term pack: the correct term and its
// misrecognized forms (aliases).
//
//	plain alias   … sure misrecognition, replaced before pasting
//	~alias        … ambiguous (also a normal word); only written to the receiver note
//	form>(a|b)    … replaced only when followed by one of a / b
type Entry struct {
	Term    string
	Aliases []string
}

// ParseGlossary parses "term<TAB>alias／alias" lines. '#' lines are comments.
func ParseGlossary(text string) []Entry {
	var out []Entry
	for _, line := range splitLines(text) {
		l := strings.TrimSpace(line)
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		parts := strings.SplitN(l, "\t", 2)
		term := strings.TrimSpace(parts[0])
		var aliases []string
		if len(parts) > 1 {
			for _, a := range strings.FieldsFunc(parts[1], func(r rune) bool { return r == '／' || r == '/' }) {
				if a = strings.TrimSpace(a); a != "" {
					aliases = append(aliases, a)
				}
			}
		}
		out = append(out, Entry{Term: term, Aliases: aliases})
	}
	return out
}

func splitLines(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == '\n' || r == '\r' })
}

// Sure returns the aliases that are safe to replace (no leading ~).
func Sure(aliases []string) []string {
	var out []string
	for _, a := range aliases {
		if !strings.HasPrefix(a, "~") {
			out = append(out, a)
		}
	}
	return out
}

// Ambiguous returns the ~aliases without the ~.
func Ambiguous(aliases []string) []string {
	var out []string
	for _, a := range aliases {
		if strings.HasPrefix(a, "~") {
			out = append(out, strings.TrimPrefix(a, "~"))
		}
	}
	return out
}

func runeLen(s string) int { return utf8.RuneCountInString(s) }

// isWordRune: characters that make a longer katakana / latin word. A match
// next to one of these is not replaced (「フォールバック」の「フォール」).
// Same class as the mac regex [\p{Katakana}ーA-Za-z0-9].
func isWordRune(r rune) bool {
	return unicode.Is(unicode.Katakana, r) || r == 'ー' ||
		(r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')
}

type correction struct {
	wrong  string // whole alias (for sorting)
	head   string // the form to find
	follow *regexp.Regexp
	right  string
}

// Autocorrect replaces sure misrecognitions of personal + pack entries.
// It returns the corrected text and the applied replacements ("wrong→right").
func Autocorrect(text string, entries []Entry) (string, []string) {
	var pairs []correction
	for _, e := range entries {
		for _, a := range Sure(e.Aliases) {
			if runeLen(a) < 2 || a == e.Term {
				continue
			}
			parts := strings.SplitN(a, ">", 2)
			c := correction{wrong: a, head: parts[0], right: e.Term}
			if len(parts) > 1 {
				re, err := regexp.Compile("^(?:" + parts[1] + ")")
				if err != nil {
					continue
				}
				c.follow = re
			}
			if c.head == "" {
				continue
			}
			pairs = append(pairs, c)
		}
	}
	// longer forms first (stable, like the mac sort on count)
	sort.SliceStable(pairs, func(i, j int) bool { return runeLen(pairs[i].wrong) > runeLen(pairs[j].wrong) })

	var applied []string
	t := text
	for _, p := range pairs {
		if !strings.Contains(t, p.head) {
			continue
		}
		var b strings.Builder
		n := 0
		i := 0
		for i < len(t) {
			if strings.HasPrefix(t[i:], p.head) && boundaryOK(t, i, i+len(p.head)) &&
				(p.follow == nil || p.follow.MatchString(t[i+len(p.head):])) {
				b.WriteString(p.right)
				i += len(p.head)
				n++
				continue
			}
			_, size := utf8.DecodeRuneInString(t[i:])
			b.WriteString(t[i : i+size])
			i += size
		}
		if n > 0 {
			applied = append(applied, p.head+"→"+p.right)
			t = b.String()
		}
	}
	return t, applied
}

func boundaryOK(t string, start, end int) bool {
	if start > 0 {
		r, _ := utf8.DecodeLastRuneInString(t[:start])
		if isWordRune(r) {
			return false
		}
	}
	if end < len(t) {
		r, _ := utf8.DecodeRuneInString(t[end:])
		if isWordRune(r) {
			return false
		}
	}
	return true
}

// UsageCounts counts in how many recent texts each entry appears (term or any
// alias, case-insensitive, keys of 2+ chars).
func UsageCounts(entries []Entry, recentTexts []string) map[string]int {
	texts := make([]string, len(recentTexts))
	for i, t := range recentTexts {
		texts[i] = strings.ToLower(t)
	}
	u := map[string]int{}
	for _, e := range entries {
		var keys []string
		for _, k := range append([]string{e.Term}, e.Aliases...) {
			k = strings.ToLower(strings.TrimPrefix(k, "~"))
			if runeLen(k) >= 2 {
				keys = append(keys, k)
			}
		}
		n := 0
		for _, t := range texts {
			for _, k := range keys {
				if strings.Contains(t, k) {
					n++
					break
				}
			}
		}
		if n > 0 {
			u[e.Term] = n
		}
	}
	return u
}

// WhisperTerms picks terms for whisper's initial prompt within `limit` chars:
// recently used terms first (most used first), then unused personal terms,
// then unused pack terms (file order).
func WhisperTerms(personal, packs []Entry, counts map[string]int, limit int) []string {
	has := func(list []Entry, term string) bool {
		for _, e := range list {
			if e.Term == term {
				return true
			}
		}
		return false
	}
	var k []Entry
	for _, e := range packs {
		if !has(personal, e.Term) {
			k = append(k, e)
		}
	}
	all := append(append([]Entry{}, personal...), k...)
	var used, rest []string
	for _, e := range all {
		if counts[e.Term] > 0 {
			used = append(used, e.Term)
		} else {
			rest = append(rest, e.Term)
		}
	}
	sort.SliceStable(used, func(i, j int) bool { return counts[used[i]] > counts[used[j]] })
	var out []string
	length := 0
	seen := map[string]bool{}
	for _, t := range append(used, rest...) {
		if seen[t] {
			continue
		}
		if length+runeLen(t) > limit {
			continue
		}
		seen[t] = true
		out = append(out, t)
		length += runeLen(t) + 1
	}
	return out
}

// DefaultPrompt is the mac default whisper prompt (makes whisper add 、。？).
const DefaultPrompt = "これで合ってる？はい、承知しました。それって本当？では、次の作業に進みましょう。"

// WhisperPromptTermLimit: whisper's initial prompt is 224 tokens; ~120 chars of terms.
const WhisperPromptTermLimit = 120

// BuildWhisperPrompt = previous utterance (last 150 chars) + terms + base prompt.
func BuildWhisperPrompt(base string, terms []string, previous string) string {
	p := base
	if len(terms) > 0 {
		p = strings.Join(terms, "、") + "。" + base
	}
	if previous != "" {
		r := []rune(previous)
		if len(r) > 150 {
			r = r[len(r)-150:]
		}
		p = string(r) + " " + p
	}
	return p
}

// ReceiverShortRows is how many rows the always-loaded receiver note gets.
const ReceiverShortRows = 20

func receiverRow(term string, aliases []string) string {
	var s []string
	for _, a := range Sure(aliases) {
		x := strings.ReplaceAll(a, ">", "（直後が ")
		if strings.Contains(a, ">") {
			x += " のとき）"
		}
		s = append(s, x)
	}
	amb := Ambiguous(aliases)
	line := "- " + term
	if len(s) > 0 {
		line += " ← " + strings.Join(s, "、")
	}
	if len(amb) > 0 {
		line += "（文脈によっては「" + strings.Join(amb, "」「") + "」と化ける）"
	}
	return line
}

// ReceiverNotes builds the short and full receiver notes (same wording as mac).
// fullDisplayPath is how the full file is referred to from the short one.
func ReceiverNotes(personal, packs []Entry, counts map[string]int, fullDisplayPath string) (short, full string) {
	var merged []Entry
	for _, e := range append(append([]Entry{}, personal...), packs...) {
		found := false
		for i := range merged {
			if merged[i].Term == e.Term {
				for _, a := range e.Aliases {
					if !contains(merged[i].Aliases, a) {
						merged[i].Aliases = append(merged[i].Aliases, a)
					}
				}
				found = true
				break
			}
		}
		if !found {
			merged = append(merged, Entry{Term: e.Term, Aliases: append([]string{}, e.Aliases...)})
		}
	}
	var withAliases []Entry
	var terms []string
	for _, e := range merged {
		if len(e.Aliases) > 0 {
			withAliases = append(withAliases, e)
		} else {
			terms = append(terms, e.Term)
		}
	}
	ranked := append([]Entry{}, withAliases...)
	sort.SliceStable(ranked, func(i, j int) bool { return counts[ranked[i].Term] > counts[ranked[j].Term] })

	head := "# 音声入力（Koe）の誤変換メモ\n\n"
	head += "ユーザーは音声入力（Koe・whisper）でも入力する。文字起こしの誤変換が混ざるので、意味が通らない語は音の近い語として読み替えてから解釈すること。読み替えたことは一言添える。\n\n"
	head += "音声入力では疑問の「？」が落ちて「。」になることがある。口語の文末（〜てる、〜ない、〜だっけ、〜ってこと）が質問か断定か曖昧なときは、質問として受け取り、答えてから進めること。\n\n"

	rows := func(list []Entry) string {
		var r []string
		for _, e := range list {
			r = append(r, receiverRow(e.Term, e.Aliases))
		}
		return strings.Join(r, "\n")
	}

	short = head
	short += "意味が取れない語があって下の一覧に無いときは、全部入りの一覧 `" + fullDisplayPath + "` を grep してから読み替える（" + strconv.Itoa(len(withAliases)) + " 語）。\n\n"
	if len(ranked) > 0 {
		top := ranked
		if len(top) > ReceiverShortRows {
			top = top[:ReceiverShortRows]
		}
		short += "## よく起きる誤変換（正しい表記 ← 化けた形）\n\n" + rows(top) + "\n"
	}
	full = head
	if len(ranked) > 0 {
		full += "## 実際に起きた誤変換（正しい表記 ← 化けた形）\n\n" + rows(ranked) + "\n\n"
	}
	if len(terms) > 0 {
		full += "## よく使う語（この表記が正しい）\n\n" + strings.Join(terms, "、") + "\n"
	}
	return short, full
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// Pack is a term pack file (packs/<id>.txt).
type Pack struct {
	ID    string
	Title string
	Path  string
}

// ListPacks lists *.txt packs in dirs; earlier dirs win on duplicate ids.
func ListPacks(dirs ...string) []Pack {
	seen := map[string]bool{}
	var out []Pack
	for _, d := range dirs {
		files, _ := filepath.Glob(filepath.Join(d, "*.txt"))
		sort.Strings(files)
		for _, f := range files {
			id := strings.TrimSuffix(filepath.Base(f), ".txt")
			if seen[id] {
				continue
			}
			seen[id] = true
			title := id
			if b, err := os.ReadFile(f); err == nil {
				lines := splitLines(string(b))
				if len(lines) > 0 && strings.HasPrefix(lines[0], "#") {
					title = strings.TrimSpace(strings.Replace(lines[0], "# Koe 用語パック:", "", 1))
				}
			}
			out = append(out, Pack{ID: id, Title: title, Path: f})
		}
	}
	return out
}

// LoadPackEntries reads the enabled packs.
func LoadPackEntries(packs []Pack, enabled []string) []Entry {
	var out []Entry
	for _, p := range packs {
		if !contains(enabled, p.ID) {
			continue
		}
		b, err := os.ReadFile(p.Path)
		if err != nil {
			continue
		}
		out = append(out, ParseGlossary(string(b))...)
	}
	return out
}

// ReadGlossaryFile parses a glossary file (missing file = empty).
func ReadGlossaryFile(path string) []Entry {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	return ParseGlossary(string(b))
}
