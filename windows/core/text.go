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

// IsRepetitive: the same sentence (4+ chars) appears 3+ times.
func IsRepetitive(text string) bool {
	parts := strings.FieldsFunc(text, func(r rune) bool { return strings.ContainsRune(sentenceEnds+" ", r) })
	count := map[string]int{}
	max := 0
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if runeLen(p) < 4 {
			continue
		}
		count[p]++
		if count[p] > max {
			max = count[p]
		}
	}
	return max >= 3
}

// CollapseRepeats keeps only the first occurrence of each repeated sentence.
func CollapseRepeats(text string) string {
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
