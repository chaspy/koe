package core

// Claude Code session logs (%USERPROFILE%\.claude\projects\*\*.jsonl) for the
// improvement loop (#184), ported from macOS SessionLog: what the user actually
// sent, Claude's reply until the next message, and the user's next message.
// Read locally only; the matching parts go into the improvement request.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"
)

// SessionHuman is one message the user sent, with the reply and the next message.
type SessionHuman struct {
	Time  time.Time
	Text  string
	Reply string // Claude's messages until the user's next message from the input box (up to 400 characters)
	Next  string // the user's next message (up to 200 characters)
}

type sessionEvent struct {
	t    time.Time
	kind int // 0 = Claude, 1 = sent from the input box, 2 = sent while Claude was working (queued)
	text string
}

// ParseSessionLog reads one session file and returns the user's messages from since on.
func ParseSessionLog(data string, since time.Time) []SessionHuman {
	var events []sessionEvent
	for _, line := range strings.Split(data, "\n") {
		if e, ok := parseSessionLine(line); ok {
			events = append(events, e)
		}
	}
	var out []SessionHuman
	for i, e := range events {
		if e.kind == 0 || e.t.Before(since) {
			continue
		}
		reply, next := replyAndNext(events[i+1:])
		out = append(out, SessionHuman{Time: e.t, Text: e.text, Reply: firstRunes(reply, 400), Next: firstRunes(next, 200)})
	}
	return out
}

// replyAndNext: the reply is everything Claude says until the next message from
// the input box (queued messages are crossed); next is the first later message.
func replyAndNext(rest []sessionEvent) (reply, next string) {
	for _, e := range rest {
		if e.kind != 0 && next == "" {
			next = e.text
		}
		if e.kind == 1 {
			break
		}
		if e.kind == 0 {
			reply += e.text + "\n"
		}
	}
	return reply, next
}

func parseSessionLine(line string) (sessionEvent, bool) {
	var d map[string]any
	if json.Unmarshal([]byte(line), &d) != nil {
		return sessionEvent{}, false
	}
	typ, _ := d["type"].(string)
	ts, _ := d["timestamp"].(string)
	t, err := time.Parse(time.RFC3339Nano, ts)
	if err != nil {
		return sessionEvent{}, false
	}
	msg, _ := d["message"].(map[string]any)
	switch typ {
	case "queue-operation":
		if c, _ := d["content"].(string); d["operation"] == "enqueue" && c != "" {
			return sessionEvent{t, 2, c}, true
		}
	case "user":
		s := strings.TrimSpace(sessionText(msg["content"]))
		if s != "" && !strings.HasPrefix(s, "<") && !strings.HasPrefix(s, "Another Claude session") && d["isMeta"] != true {
			return sessionEvent{t, 1, s}, true
		}
	case "assistant":
		if s := sessionText(msg["content"]); s != "" {
			return sessionEvent{t, 0, s}, true
		}
	}
	return sessionEvent{}, false
}

// sessionText: a string, or the text parts of a content list (a tool result is not a message).
func sessionText(content any) string {
	switch c := content.(type) {
	case string:
		return c
	case []any:
		var parts []string
		for _, p := range c {
			m, _ := p.(map[string]any)
			if m["type"] == "tool_result" {
				return ""
			}
			if s, _ := m["text"].(string); m["type"] == "text" {
				parts = append(parts, s)
			}
		}
		return strings.Join(parts, "\n")
	}
	return ""
}

// LoadSessionLogs reads the session files changed since `since` under root.
func LoadSessionLogs(root string, since time.Time) []SessionHuman {
	dirs, _ := os.ReadDir(root)
	var out []SessionHuman
	for _, d := range dirs {
		if !d.IsDir() {
			continue
		}
		files, _ := os.ReadDir(filepath.Join(root, d.Name()))
		for _, f := range files {
			info, err := f.Info()
			if err != nil || !strings.HasSuffix(f.Name(), ".jsonl") || info.ModTime().Before(since) {
				continue
			}
			if b, err := os.ReadFile(filepath.Clean(filepath.Join(root, d.Name(), f.Name()))); err == nil {
				out = append(out, ParseSessionLog(string(b), since)...)
			}
		}
	}
	return out
}

// NormalizeSessionText drops spaces and punctuation, for matching a transcript to what was sent.
func NormalizeSessionText(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) || unicode.IsPunct(r) {
			return -1
		}
		return r
	}, s)
}

// MatchSession finds the message sent within -5..+20 s of the utterance whose
// text contains the first or the last 12 characters of it (pasting takes a few
// seconds; a wider window matches text the user pasted again by hand).
func MatchSession(text string, at time.Time, humans []SessionHuman) *SessionHuman {
	n := []rune(NormalizeSessionText(text))
	if len(n) < 4 {
		return nil
	}
	head, tail := string(n[:min(12, len(n))]), string(n[max(0, len(n)-12):])
	for i, h := range humans {
		if h.Time.Before(at.Add(-5*time.Second)) || h.Time.After(at.Add(20*time.Second)) {
			continue
		}
		if s := NormalizeSessionText(h.Text); strings.Contains(s, head) || strings.Contains(s, tail) {
			return &humans[i]
		}
	}
	return nil
}

func firstRunes(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}
