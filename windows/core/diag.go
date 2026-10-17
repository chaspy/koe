package core

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// ---- whisper-server output → koe.log ----

// serverLogPatterns select whisper-server output lines worth copying into
// koe.log: CPU features, thread count, model load, timings, errors.
var serverLogPatterns = []string{
	"system_info", "AVX", "CPU", "total time", "encode time", "decode time",
	"load time", "model size", "processing '", "error", "failed",
	"whisper_backend_init_gpu", "ggml_vulkan", "total size",
}

// InterestingServerLine reports whether a whisper-server output line should
// be copied into koe.log.
func InterestingServerLine(line string) bool {
	for _, p := range serverLogPatterns {
		if strings.Contains(line, p) {
			return true
		}
	}
	return false
}

// LineFilter is an io.Writer that splits its input into lines and calls Fn
// with each line for which Match returns true (CR / LF stripped, at most
// 400 bytes).
type LineFilter struct {
	Match func(string) bool
	Fn    func(string)

	mu  sync.Mutex
	buf []byte
}

func (f *LineFilter) Write(p []byte) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.buf = append(f.buf, p...)
	for {
		i := bytes.IndexByte(f.buf, '\n')
		if i < 0 {
			break
		}
		f.emit(string(f.buf[:i]))
		f.buf = f.buf[i+1:]
	}
	if len(f.buf) > 64<<10 { // no newline for a long time: drop
		f.buf = f.buf[:0]
	}
	return len(p), nil
}

func (f *LineFilter) emit(line string) {
	line = strings.TrimRight(line, "\r")
	if strings.TrimSpace(line) == "" || f.Match == nil || !f.Match(line) {
		return
	}
	if len(line) > 400 {
		line = line[:400]
	}
	if f.Fn != nil {
		f.Fn(line)
	}
}

// MsPerAudioSecond is transcription time per second of audio (0 if no audio).
func MsPerAudioSecond(ms int64, audioSeconds float64) float64 {
	if audioSeconds <= 0 {
		return 0
	}
	return float64(ms) / audioSeconds
}

// ---- diagnostics export ----

// secretKeyWords: a config key containing one of these has its value hidden.
// Same words as the mac (Diagnostics.secretWords).
var secretKeyWords = []string{"key", "token", "secret", "password", "auth"}

// privateConfigKeys may hold words or text the user wrote (the initial
// prompt, commands, dictionary paths). Only their length is shown, like the
// mac (Diagnostics.privateKeys).
var privateConfigKeys = map[string]bool{
	"prompt": true, "contextprompt": true, "improvecommand": true, "improvetokencommand": true,
	"llmprompt": true, "glossarypath": true, "orgglossary": true,
}

// IsPrivateConfigKey reports whether only the length of a config value may be shown.
func IsPrivateConfigKey(k string) bool { return privateConfigKeys[strings.ToLower(k)] }

// privateValue is what diagnostics show instead of a private value.
func privateValue(v any) string {
	s, ok := v.(string)
	if !ok {
		b, _ := json.Marshal(v)
		s = string(b)
	}
	return fmt.Sprintf("（%d 文字・伏せた）", utf8.RuneCountInString(s))
}

// notSecretKeys contain "key" but are settings, not secrets.
var notSecretKeys = map[string]bool{"hotkey": true, "menumaskkey": true}

// IsSecretKey reports whether a config key's value must be hidden.
func IsSecretKey(k string) bool {
	l := strings.ToLower(k)
	if notSecretKeys[l] {
		return false
	}
	for _, w := range secretKeyWords {
		if strings.Contains(l, w) {
			return true
		}
	}
	return false
}

// RedactValue replaces the values of secret keys (at any depth) with "***"
// and those of private keys with their length.
func RedactValue(v any) any {
	switch t := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(t))
		for k, x := range t {
			if IsSecretKey(k) {
				out[k] = "***"
			} else if IsPrivateConfigKey(k) {
				out[k] = privateValue(x)
			} else {
				out[k] = RedactValue(x)
			}
		}
		return out
	case []any:
		out := make([]any, len(t))
		for i, x := range t {
			out[i] = RedactValue(x)
		}
		return out
	}
	return v
}

// RedactedConfigLines renders config.json as sorted "key = value" lines with
// secrets hidden, skipping the keys in skip (already shown elsewhere).
func RedactedConfigLines(data []byte, skip ...string) ([]string, error) {
	m := map[string]any{}
	if len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, &m); err != nil {
			return nil, err
		}
	}
	red := RedactValue(m).(map[string]any)
	skipSet := map[string]bool{}
	for _, s := range skip {
		skipSet[s] = true
	}
	var keys []string
	for k := range red {
		if !skipSet[k] {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	var out []string
	for _, k := range keys {
		b, _ := json.Marshal(red[k])
		out = append(out, k+" = "+string(b))
	}
	return out, nil
}

// transcriptField matches log fields that could carry transcribed text:
// text=, raw=, pasted=, prompt=, transcript=, whisper_prompt=, autocorrected=[...]
// with a quoted, bracketed or bare value.
var transcriptField = regexp.MustCompile(`\b(text|raw|pasted|prompt|transcript|whisper_prompt|raw_before_autocorrect|repetition_before_retry|repetition_collapsed|stock_phrase_before_retry|stock_phrase_removed|autocorrected)=("(?:[^"\\]|\\.)*"|\[[^\]]*\]|\S+)`)

// RedactLogLine removes transcript-carrying fields from one log line. Koe
// itself does not log text; this protects exports of older logs.
func RedactLogLine(line string) string {
	return transcriptField.ReplaceAllString(line, "$1=***")
}

// TailLines returns the last n lines of data (all if fewer), each passed
// through RedactLogLine, joined with CRLF.
func TailLines(data []byte, n int) []byte {
	s := strings.ReplaceAll(string(data), "\r\n", "\n")
	s = strings.TrimRight(s, "\n")
	if s == "" {
		return nil
	}
	lines := strings.Split(s, "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	for i, l := range lines {
		lines[i] = RedactLogLine(l)
	}
	return []byte(strings.Join(lines, "\r\n") + "\r\n")
}

// ReadTail reads the files in order (e.g. koe.log.1, koe.log) as one stream
// and returns its last n lines, redacted. Missing files are skipped.
func ReadTail(n int, paths ...string) []byte {
	var all []byte
	for _, p := range paths {
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		all = append(all, b...)
		if len(all) > 0 && all[len(all)-1] != '\n' {
			all = append(all, '\n')
		}
	}
	return TailLines(all, n)
}

// ZipFile is one entry of the diagnostics zip.
type ZipFile struct {
	Name string
	Data []byte
}

// WriteZip writes files to w as a zip archive.
func WriteZip(w io.Writer, files []ZipFile, mod time.Time) error {
	zw := zip.NewWriter(w)
	for _, f := range files {
		h := &zip.FileHeader{Name: f.Name, Method: zip.Deflate, Modified: mod}
		fw, err := zw.CreateHeader(h)
		if err != nil {
			return err
		}
		if _, err := fw.Write(f.Data); err != nil {
			return err
		}
	}
	return zw.Close()
}

// DiagnosticsName is the zip file name for time t.
func DiagnosticsName(t time.Time) string {
	return fmt.Sprintf("Koe-diagnostics-%s.zip", t.Format("20060102-1504"))
}
