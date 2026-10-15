package core

import "strings"

// Hallucinations: phrases whisper often produces from silence / noise.
var Hallucinations = map[string]bool{
	"ご視聴ありがとうございました": true, "ご視聴ありがとうございました。": true,
	"ありがとうございました": true, "ありがとうございました。": true,
	"おやすみなさい": true, "おやすみなさい。": true,
	"(音楽)": true, "(拍手)": true, "[音楽]": true, "[BLANK_AUDIO]": true,
}

const sentenceEnds = "。！？!?\n"

// Repetition thresholds. whisper sometimes loops on one word or a few
// characters ("ドラフ、ドラフ、ドラフ、…", "ミティミティミティ…"), more often
// with a small audio_ctx and without the temperature fallback.
const (
	repeatSentenceMin = 3 // the same sentence (4+ chars) anywhere
	repeatWordRun     = 5 // the same word (between 、 , space 。 …) in a row
	repeatUnitRun     = 6 // the same 2–6 characters in a row, separators or not
	repeatUnitMin     = 2
	repeatUnitMax     = 6
)

const wordSeps = "、,，。 　！？!?\n"

// IsRepetitive: the same sentence (4+ chars) appears 3+ times, the same word
// appears 5+ times in a row, or the same 2–6 characters repeat 6+ times in a row.
func IsRepetitive(text string) bool {
	return repeatedSentences(text) || wordRun(text) || unitRun([]rune(text))
}

func repeatedSentences(text string) bool {
	parts := strings.FieldsFunc(text, func(r rune) bool { return strings.ContainsRune(sentenceEnds+" ", r) })
	count := map[string]int{}
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if runeLen(p) < 4 {
			continue
		}
		count[p]++
		if count[p] >= repeatSentenceMin {
			return true
		}
	}
	return false
}

// wordToken is a word and the separators after it.
type wordToken struct{ word, sep string }

func splitWords(text string) []wordToken {
	var out []wordToken
	var w, sep strings.Builder
	for _, r := range text {
		if strings.ContainsRune(wordSeps, r) {
			sep.WriteRune(r)
			continue
		}
		if sep.Len() > 0 {
			out = append(out, wordToken{w.String(), sep.String()})
			w.Reset()
			sep.Reset()
		}
		w.WriteRune(r)
	}
	if w.Len() > 0 || sep.Len() > 0 {
		out = append(out, wordToken{w.String(), sep.String()})
	}
	return out
}

func wordRun(text string) bool {
	run := 0
	prev := ""
	for _, t := range splitWords(text) {
		if t.word == "" {
			continue
		}
		if t.word == prev {
			run++
		} else {
			prev, run = t.word, 1
		}
		if run >= repeatWordRun {
			return true
		}
	}
	return false
}

// unitAt returns the length and count of the shortest 2–6 character unit
// repeating repeatUnitRun+ times from i (0, 0 if none). Digits are not a
// unit ("1000000000000" is a number, not a loop).
func unitAt(r []rune, i int) (size, count int) {
	for l := repeatUnitMin; l <= repeatUnitMax && i+l <= len(r); l++ {
		if strings.Trim(string(r[i:i+l]), "0123456789") == "" {
			continue
		}
		n := 1
		for j := i + l; j+l <= len(r) && string(r[j:j+l]) == string(r[i:i+l]); j += l {
			n++
		}
		if n >= repeatUnitRun {
			return l, n
		}
	}
	return 0, 0
}

func unitRun(r []rune) bool {
	for i := range r {
		if l, _ := unitAt(r, i); l > 0 {
			return true
		}
	}
	return false
}

// CollapseRepeats shrinks each repetition to one: a run of 5+ same words keeps
// the first word (with the run's last separator), a run of 6+ same 2–6
// characters keeps one, and when a sentence (4+ chars) appears 3+ times its
// later copies are dropped. Text without repetition comes back trimmed.
func CollapseRepeats(text string) string {
	text = collapseUnits(collapseWords(text))
	if repeatedSentences(text) {
		text = collapseSentences(text)
	}
	return strings.TrimSpace(text)
}

func collapseWords(text string) string {
	toks := splitWords(text)
	var out strings.Builder
	for i := 0; i < len(toks); {
		j := i + 1
		for toks[i].word != "" && j < len(toks) && toks[j].word == toks[i].word {
			j++
		}
		if j-i >= repeatWordRun {
			out.WriteString(toks[i].word + toks[j-1].sep)
		} else {
			for _, t := range toks[i:j] {
				out.WriteString(t.word + t.sep)
			}
		}
		i = j
	}
	return out.String()
}

func collapseUnits(text string) string {
	r := []rune(text)
	var out strings.Builder
	for i := 0; i < len(r); {
		if l, n := unitAt(r, i); l > 0 {
			out.WriteString(string(r[i : i+l]))
			i += l * n
			continue
		}
		out.WriteRune(r[i])
		i++
	}
	return out.String()
}

func collapseSentences(text string) string {
	seen := map[string]int{}
	var out, cur strings.Builder
	flush := func(sep string) {
		c := cur.String()
		k := strings.TrimSpace(c)
		if runeLen(k) >= 4 {
			seen[k]++
		}
		if runeLen(k) < 4 || seen[k] == 1 {
			out.WriteString(c + sep)
		}
		cur.Reset()
	}
	for _, r := range text {
		if strings.ContainsRune(sentenceEnds, r) {
			flush(string(r))
		} else {
			cur.WriteRune(r)
		}
	}
	flush("")
	return strings.TrimSpace(out.String())
}

// CleanServerText joins the non-empty trimmed lines of whisper-server's text
// response with a space (mac behavior).
func CleanServerText(raw string) string {
	var parts []string
	for _, l := range splitLines(raw) {
		if l = strings.TrimSpace(l); l != "" {
			parts = append(parts, l)
		}
	}
	return strings.Join(parts, " ")
}
