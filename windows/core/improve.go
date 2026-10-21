package core

// The improvement loop ("使うほど賢くする", #184), ported from macOS (Improver in
// macos/Sources/Koe/main.swift). These are the pure parts: which history records
// go into a batch, the text that is sent, reading the answer, the judgement
// label, which terms reach the personal glossary, and the new glossary text.
// Nothing here runs a command or touches the network; the runner is a later
// slice and stays off by default.

import (
	"encoding/json"
	"errors"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	// ImproveBatchMax is how many utterances one request carries at most (macOS: suffix(60)).
	ImproveBatchMax = 60
	// improveKnownMax is how many known glossary terms are listed in the request (macOS: prefix(400)).
	improveKnownMax = 400
	// ImproveGlossaryMax caps the personal glossary (macOS: 300 terms).
	ImproveGlossaryMax = 300
)

// ImprovePrompt is the instruction sent with every batch. Same text as macOS.
const ImprovePrompt = `あなたは音声入力アプリの改善係です。音声認識（whisper）で文字起こしして AI エージェント（Claude Code 等）に送った発話の一覧が渡されます。各発話には、分かる場合は実際に送った文・Claude の返答・本人の次の発話が付いています。
次の 2 つを JSON だけで返してください。

1. terms: 誤変換された語と正しい表記
   - 技術用語・英字略語・サービス名・社内用語・プロダクト名、人の名前・呼び名（ハンドル名・あだ名）が対象
   - 1 つの語だけ。句や言い回し（「〜の〜」「〜を〜する」）、普通の日本語の言葉（「遅延」「返事不要」等）、文の一部は出さない
   - 人の名前・呼び名には kind: "person"、それ以外は kind: "term" を付ける（人の名前は本人の Mac の個人の辞書にだけ入り、共有されない）
   - 人の名前は、普通の言葉と取り違えやすい（「パン粉を買う」の「パン粉」は人ではない）。「〜さん」などの敬称が付き、前後に人とのやりとり（Slack・レビュー・PR・会議など）がある場合だけ出す。wrong は敬称つきで書く（例: "パン粉さん"）
   - 人の名前の right は、本人が言った呼び方の正しい表記にする。わざと言ったあだ名・ハンドル名を本名に書き換えない
   - 人の名前の term には、同じ名前が化けそうな近い読みの形を variants に最大 5 つ付ける（例: right が "panko" で wrong が "パン粉さん" なら ["パンコ", "パンコア", "バンコ"]）。敬称は付けない。正しい表記そのもの・その人のほかの正しい呼び方やあだ名は入れない。思いつかなければ空の配列
   - 各 term に、その語が出てきた発話の番号 i と、確度 confidence（"high" / "medium" / "low"）を付ける。人の名前は "high" のときだけ辞書に入る
   - wrong は文字起こしに実際に含まれる文字列。right は正しい表記（2〜30 文字）
   - 本人の次の発話や送った文の手直しで正しい表記が明示されているか、Claude が「〜と読みました」「〜のことですか？」と読み替えて本人が否定していなければ explicit: true
   - 確信がなければ出さない。既に辞書にある語でも、新しい誤変換の形が見つかれば出す
2. judgements: 各発話について、次の 3 つに true / false で答える
   - error: 文字起こしに、意味を変える誤り（誤変換・欠け・幻聴の繰り返し）があるか。Claude の答えの良し悪し・本人の反論や不満は関係ない
   - read_ok: error が true のとき、Claude が正しい意味に読み替えて応じたか（「〜と読み替えました」と添えた場合も true）。違う意味で動いた／意味を確認する質問をした／その部分を無視した／本人が誤った語を言い直した、なら false
   - impact: read_ok が false のときだけ、困り具合を 1 つ選ぶ
     - "misacted": Claude が誤った意味のまま作業を進めた（違うファイルを直した・違うコマンドを実行した・違う内容で文書を書いた等）
     - "redo": Claude が聞き返した、または答えが噛み合わず本人が言い直した・聞き直した
     - "dropped": 誤った部分を Claude が飛ばしたが、本人は言い直さずに話が進んだ
   - unknown: 返答も次の発話もなく判断できないときだけ true。返答が（なし）で、次の発話が同じ内容の言い直しでもないときも true
   - 「[n] と同じ返答」の発話は、まとめた返答がその発話の内容にも触れていれば read_ok: true。触れていなくても、誤りのせいだと言えなければ unknown: true
   - reason は 30 文字以内。発話の本文は写さない
   - judgements は、すべての発話 [0]〜[最後] について 1 件ずつ必ず出す（terms が空でも省かない）

{"terms": [{"i": 0, "wrong": "...", "right": "...", "kind": "term", "explicit": false, "confidence": "high"}, {"i": 1, "wrong": "...さん", "right": "...", "kind": "person", "explicit": false, "confidence": "high", "variants": ["...", "..."]}], "judgements": [{"i": 0, "error": false, "read_ok": true, "impact": null, "unknown": false, "reason": "..."}]}`

// ImproveItem is one history record (its decoded JSON) and its id.
type ImproveItem struct {
	ID     string
	Record map[string]any
}

// improveSkipOutcomes are recordings that never reached the user as text.
var improveSkipOutcomes = map[string]bool{
	"mic_silent": true, "no_voice": true, "hallucination": true, "error": true, "too_short": true,
}

// ImproveBatch picks the records that were not scanned yet, oldest first, and
// keeps the newest ImproveBatchMax. Lock recordings (they can hold another
// person's voice), records without text and failed recordings are never sent.
func ImproveBatch(items []ImproveItem) []ImproveItem {
	var out []ImproveItem
	for _, it := range items {
		r := it.Record
		raw, _ := r["raw"].(string)
		if strings.TrimSpace(raw) == "" || r["locked"] == true || r["glossary_scanned"] == true || r["dropped"] == true {
			continue
		}
		if o, _ := r["outcome"].(string); improveSkipOutcomes[o] {
			continue
		}
		out = append(out, it)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	if len(out) > ImproveBatchMax {
		out = out[len(out)-ImproveBatchMax:]
	}
	return out
}

// ImprovePayload builds the user text of a request: the known terms, then each
// utterance with, when a matching Claude Code message is found, what was
// actually sent, Claude's reply and the next message (same lines as macOS).
func ImprovePayload(items []ImproveItem, known []string, humans []SessionHuman) string {
	if len(known) > improveKnownMax {
		known = known[:improveKnownMax]
	}
	lines := make([]string, 0, len(items))
	replyOwner := map[string]int{}
	for i, it := range items {
		lines = append(lines, improveLine(i, it, humans, replyOwner))
	}
	return "既に辞書にある語: " + strings.Join(known, "、") + "\n\n" + strings.Join(lines, "\n\n")
}

func improveLine(i int, it ImproveItem, humans []SessionHuman, replyOwner map[string]int) string {
	raw, _ := it.Record["raw"].(string)
	line := "[" + strconv.Itoa(i) + "] 文字起こし: " + raw
	sent, _ := it.Record["pasted"].(string)
	if sent == "" {
		sent = raw
	}
	t, ok := parseHistoryID(it.ID)
	var h *SessionHuman
	if ok {
		h = MatchSession(sent, t, humans)
	}
	if h == nil {
		return line + "\n  （Claude Code のセッション記録なし）"
	}
	if NormalizeSessionText(h.Text) != NormalizeSessionText(raw) {
		line += "\n  実際に送った文: " + firstRunes(h.Text, 300)
	}
	switch j, seen := replyOwner[h.Reply]; {
	case h.Reply == "":
		line += "\n  Claude の返答: （なし。次の発話が先に入った）"
	case seen:
		line += "\n  Claude の返答: （[" + strconv.Itoa(j) + "] と同じ返答。Claude の作業中に続けて送った発話で、まとめて 1 つの返答になっている）"
	default:
		replyOwner[h.Reply] = i
		line += "\n  Claude の返答: " + h.Reply
	}
	next := h.Next
	if next == "" {
		next = "（なし）"
	}
	return line + "\n  次の発話: " + next
}

// ImproveRequest is what goes to the command (and what the preview shows).
func ImproveRequest(items []ImproveItem, known []string, humans []SessionHuman) string {
	return ImprovePrompt + "\n\n---\n\n" + ImprovePayload(items, known, humans)
}

// ImproveSince is from when session logs are read for a batch: an hour before its oldest utterance.
func ImproveSince(batch []ImproveItem, now time.Time) time.Time {
	oldest := now
	for _, it := range batch {
		if t, ok := parseHistoryID(it.ID); ok && t.Before(oldest) {
			oldest = t
		}
	}
	return oldest.Add(-time.Hour)
}

// ImproveAnswer is the part of the LLM's JSON answer that Koe uses.
type ImproveAnswer struct {
	Terms      []map[string]any `json:"terms"`
	Judgements []map[string]any `json:"judgements"`
}

// ErrImproveAnswer means the answer had no readable JSON object.
var ErrImproveAnswer = errors.New("improve: the answer has no JSON object")

// ParseImproveAnswer reads the JSON object in an answer (text around it, such
// as a code fence, is ignored).
func ParseImproveAnswer(content string) (ImproveAnswer, error) {
	var a ImproveAnswer
	s, e := strings.Index(content, "{"), strings.LastIndex(content, "}")
	if s < 0 || e < s {
		return a, ErrImproveAnswer
	}
	if err := json.Unmarshal([]byte(content[s:e+1]), &a); err != nil {
		return a, ErrImproveAnswer
	}
	return a, nil
}

// ImproveLabel turns a judgement into understood / corrected / unclear, or ""
// when it cannot be read. The LLM answers small questions and Koe decides the
// label (it tends to write "read it as …" and still pick corrected).
func ImproveLabel(j map[string]any) string {
	if j["unknown"] == true {
		return "unclear"
	}
	if err, ok := j["error"].(bool); ok {
		if !err || j["read_ok"] == true {
			return "understood"
		}
		return "corrected"
	}
	if l, _ := j["label"].(string); l == "understood" || l == "corrected" || l == "unclear" {
		return l
	}
	return ""
}

// ImproveImpact is how bad a corrected utterance was: misacted / redo / dropped (redo when missing).
func ImproveImpact(j map[string]any) string {
	switch v, _ := j["impact"].(string); v {
	case "misacted", "redo", "dropped":
		return v
	}
	return "redo"
}

var improveParticles = []string{"の", "を", "が", "は", "に", "で", "と", "へ", "から", "まで"}

// IsImproveTerm reports whether w may go into the glossary: 2–20 characters,
// with katakana or latin letters, and not a phrase joined by a particle.
func IsImproveTerm(w string, person bool) bool {
	n := len([]rune(w))
	if n < 2 || n > 20 {
		return false
	}
	return person || hasKanaOrLatin(w) && !hasParticle(w)
}

func hasKanaOrLatin(w string) bool {
	for _, r := range w {
		if isKatakana(r) || isASCIIAlnum(r) {
			return true
		}
	}
	return false
}

func hasParticle(w string) bool {
	for _, p := range improveParticles {
		if strings.Contains(w, p) {
			return true
		}
	}
	return false
}

func isASCIIAlnum(r rune) bool {
	return r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z'
}

func isASCIILetter(r rune) bool { return r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' }

func isKatakana(r rune) bool { return r >= 0x30A0 && r <= 0x30FF }

// improveCommon: hiragana/kanji-only or 3 characters or fewer overlaps with
// ordinary words, so it is never replaced automatically.
func improveCommon(w string) bool {
	if len([]rune(w)) <= 3 {
		return true
	}
	for _, r := range w {
		if isKatakana(r) || isASCIILetter(r) {
			return false
		}
	}
	return true
}

// TermCandidate counts how often a term was found misrecognized.
type TermCandidate struct {
	Count    int      `json:"count"`
	Wrongs   []string `json:"wrongs"`
	Explicit bool     `json:"explicit,omitempty"`
}

// MergeImproveTerms adds the answer's terms to the candidates and returns the
// terms to promote into the glossary with their aliases. A term is promoted
// once it was seen twice, or at once when the user named the right spelling
// (explicit). Only explicit, non-common forms are sure replacements; the rest
// get "~" (a note for the receiving AI, never replaced). People names are
// macOS only (peopleSources), so kind "person" is skipped.
func MergeImproveTerms(cand map[string]TermCandidate, terms []map[string]any) (map[string]TermCandidate, map[string][]string) {
	if cand == nil {
		cand = map[string]TermCandidate{}
	}
	promote := map[string][]string{}
	for _, t := range terms {
		right, wrong, ok := improveTermPair(t)
		if !ok {
			continue
		}
		c := cand[right]
		c.Count++
		if !contains(c.Wrongs, wrong) {
			c.Wrongs = append(c.Wrongs, wrong)
		}
		c.Explicit = c.Explicit || t["explicit"] == true
		cand[right] = c
		if c.Count >= 2 || c.Explicit {
			promote[right] = c.aliases()
		}
	}
	return cand, promote
}

// improveTermPair returns the right spelling and the misrecognized form of a
// term from the answer, or ok=false when it must not reach the glossary.
func improveTermPair(t map[string]any) (right, wrong string, ok bool) {
	if k, _ := t["kind"].(string); k == "person" {
		return "", "", false
	}
	right, _ = t["right"].(string)
	wrong, _ = t["wrong"].(string)
	right, wrong = strings.TrimSpace(right), strings.TrimSpace(wrong)
	rn := len([]rune(right))
	// a sentence or a note is not a term (「(聞き取り不能)」「〜、〜のやつ」)
	if rn < 2 || rn > 30 || wrong == "" || wrong == right || len([]rune(wrong)) > 15 ||
		strings.Contains(wrong, "、") || strings.ContainsAny(right, "(（") {
		return "", "", false
	}
	return right, wrong, IsImproveTerm(right, false)
}

// aliases: only explicit, non-common forms are sure replacements; the rest get "~".
func (c TermCandidate) aliases() []string {
	var out []string
	for _, w := range c.Wrongs {
		if c.Explicit && !improveCommon(w) {
			out = append(out, w)
		} else {
			out = append(out, "~"+w)
		}
	}
	return out
}

// ImproveGlossaryHeader starts a personal glossary the loop creates.
const ImproveGlossaryHeader = "# Koe 個人の辞書（改善ループが自動で育てる。不要な語は消してよい）"

// ApplyImprovePromotions returns the glossary text with the promoted terms:
// aliases are merged into an existing line, a new term goes right after the
// first line while the glossary has fewer than ImproveGlossaryMax terms. The
// line ending of the file (CRLF or LF) is kept. It returns the terms added.
func ApplyImprovePromotions(text string, promote map[string][]string) (string, []string) {
	nl := "\n"
	if strings.Contains(text, "\r\n") {
		nl = "\r\n"
	}
	if strings.TrimSpace(text) == "" {
		text = ImproveGlossaryHeader + nl
	}
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	count := len(ParseGlossary(text))
	terms := make([]string, 0, len(promote))
	for t := range promote {
		terms = append(terms, t)
	}
	sort.Strings(terms)
	var added []string
	for _, term := range terms {
		if at := glossaryLineOf(lines, term); at >= 0 {
			lines[at] = mergeGlossaryLine(lines[at], term, promote[term])
		} else if count+len(added) < ImproveGlossaryMax {
			// right after the first line (the header), like macOS
			pos := min(1, len(lines))
			lines = append(lines[:pos], append([]string{term + "\t" + strings.Join(promote[term], "／")}, lines[pos:]...)...)
			added = append(added, term)
		}
	}
	return strings.Join(lines, nl), added
}

// glossaryLineOf is the index of the line for term, or -1.
func glossaryLineOf(lines []string, term string) int {
	for i, l := range lines {
		if strings.HasPrefix(strings.TrimSpace(l), "#") {
			continue
		}
		if strings.TrimSpace(strings.SplitN(l, "\t", 2)[0]) == term {
			return i
		}
	}
	return -1
}

// mergeGlossaryLine adds aliases to an existing line (sorted, no duplicates).
func mergeGlossaryLine(line, term string, wrongs []string) string {
	var old []string
	if e := ParseGlossary(line); len(e) > 0 {
		old = e[0].Aliases
	}
	return term + "\t" + strings.Join(uniqueSorted(append(old, wrongs...)), "／")
}

func uniqueSorted(xs []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, x := range xs {
		if !seen[x] {
			seen[x] = true
			out = append(out, x)
		}
	}
	sort.Strings(out)
	return out
}
