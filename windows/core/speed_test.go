package core

import (
	"archive/zip"
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	vkRCtrl = 0xA3
	vkC     = 0x43
	vkV     = 0x56
)

func ms(n int) time.Duration { return time.Duration(n) * time.Millisecond }

func TestToggleTapStartsAndTapStops(t *testing.T) {
	h := HoldTracker{HotkeyVK: vkRCtrl, MinHold: ms(300), Toggle: true}
	t0 := time.Now()
	if h.Down(vkRCtrl, t0) != ActStart {
		t.Fatal("start")
	}
	if h.Down(vkRCtrl, t0.Add(ms(30))) != ActNone {
		t.Fatal("auto-repeat")
	}
	if a, _ := h.Up(vkRCtrl, t0.Add(ms(150))); a != ActLatch || !h.Latched() {
		t.Fatal("tap should latch", a)
	}
	// typing while latched does not cancel
	if h.Down(vkV, t0.Add(ms(500))) != ActNone {
		t.Fatal("other key while latched")
	}
	if a, _ := h.Up(vkV, t0.Add(ms(550))); a != ActNone {
		t.Fatal("other key up")
	}
	if h.Down(vkRCtrl, t0.Add(3*time.Second)) != ActNone {
		t.Fatal("stop tap down")
	}
	a, d := h.Up(vkRCtrl, t0.Add(3*time.Second+ms(100)))
	if a != ActFinish || d != 3*time.Second+ms(100) || h.Latched() {
		t.Fatal("stop tap", a, d)
	}
	// next tap starts a new recording
	if h.Down(vkRCtrl, t0.Add(5*time.Second)) != ActStart {
		t.Fatal("restart")
	}
}

func TestToggleLongHoldIsHoldToTalk(t *testing.T) {
	h := HoldTracker{HotkeyVK: vkRCtrl, MinHold: ms(300), Toggle: true}
	t0 := time.Now()
	h.Down(vkRCtrl, t0)
	if a, d := h.Up(vkRCtrl, t0.Add(2*time.Second)); a != ActFinish || d != 2*time.Second || h.Latched() {
		t.Fatal("long hold", a, d)
	}
	// exactly the tap limit is not a tap
	h.Down(vkRCtrl, t0)
	if a, _ := h.Up(vkRCtrl, t0.Add(DefaultTapMax)); a != ActFinish {
		t.Fatal("at tap max", a)
	}
}

func TestToggleShortcutIsNotATap(t *testing.T) {
	h := HoldTracker{HotkeyVK: vkRCtrl, MinHold: ms(300), Toggle: true}
	t0 := time.Now()
	// RCtrl+C before latching: cancel like hold mode, no latch
	h.Down(vkRCtrl, t0)
	if h.Down(vkC, t0.Add(ms(50))) != ActCancel {
		t.Fatal("cancel")
	}
	if a, _ := h.Up(vkRCtrl, t0.Add(ms(100))); a != ActNone || h.Latched() {
		t.Fatal("shortcut must not latch", a)
	}
	// latched, then RCtrl+C: keeps recording
	h.Down(vkRCtrl, t0.Add(time.Second))
	h.Up(vkRCtrl, t0.Add(time.Second+ms(100)))
	if !h.Latched() {
		t.Fatal("latch")
	}
	h.Down(vkRCtrl, t0.Add(2*time.Second))
	h.Down(vkC, t0.Add(2*time.Second+ms(20)))
	if a, _ := h.Up(vkRCtrl, t0.Add(2*time.Second+ms(80))); a != ActNone || !h.Latched() {
		t.Fatal("modifier use while latched must not stop", a)
	}
	h.Down(vkRCtrl, t0.Add(3*time.Second))
	if a, _ := h.Up(vkRCtrl, t0.Add(3*time.Second+ms(80))); a != ActFinish {
		t.Fatal("stop", a)
	}
}

func TestToggleResetOnModeOrHotkeyChange(t *testing.T) {
	h := HoldTracker{HotkeyVK: vkRCtrl, MinHold: ms(300), Toggle: true}
	t0 := time.Now()
	h.Down(vkRCtrl, t0)
	h.Up(vkRCtrl, t0.Add(ms(100)))
	h.SetToggle(false)
	if h.Latched() || h.Toggle {
		t.Fatal("mode change must clear latch")
	}
	// hold mode: a tap is too short again
	h.Down(vkRCtrl, t0.Add(time.Second))
	if a, _ := h.Up(vkRCtrl, t0.Add(time.Second+ms(100))); a != ActShort {
		t.Fatal("hold short", a)
	}
	h.SetToggle(true)
	h.Down(vkRCtrl, t0.Add(2*time.Second))
	h.Up(vkRCtrl, t0.Add(2*time.Second+ms(100)))
	h.SetHotkey(0xA5)
	if h.Latched() {
		t.Fatal("hotkey change must clear latch")
	}
}

func TestPressModeConfig(t *testing.T) {
	c, _ := ParseConfig([]byte(`{"pressMode":"Toggle"}`))
	if c.PressMode != PressToggle {
		t.Fatal(c.PressMode)
	}
	for _, in := range []string{`{}`, `{"pressMode":"x"}`} {
		c, _ = ParseConfig([]byte(in))
		if c.PressMode != PressHold {
			t.Fatal(in, c.PressMode)
		}
	}
	c, _ = ParseConfig([]byte(`{"threads":-3}`))
	if c.Threads != 0 || c.TemperatureFallback {
		t.Fatal(c.Threads)
	}
}

func TestModelMapping(t *testing.T) {
	cases := map[string]string{
		"small-q5_1":                   "ggml-small-q5_1.bin",
		"ggml-base-q5_1":               "ggml-base-q5_1.bin",
		"ggml-large-v3-turbo-q5_0.bin": "ggml-large-v3-turbo-q5_0.bin",
		`D:\models\x.bin`:              `D:\models\x.bin`,
		"":                             "",
	}
	for in, want := range cases {
		if got := NormalizeModel(in); got != want {
			t.Errorf("NormalizeModel(%q) = %q, want %q", in, got, want)
		}
	}
	want := map[string]string{
		"ggml-large-v3-turbo-q5_0.bin": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
		"ggml-small-q5_1.bin":          "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin",
		"ggml-base-q5_1.bin":           "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin",
	}
	if len(ModelChoices) != 3 || ModelChoices[0].File != DefaultModel {
		t.Fatal(ModelChoices)
	}
	for _, c := range ModelChoices {
		if ModelFileURL(c.File) != want[c.File] || !IsModelChoice(c.File) {
			t.Errorf("%s -> %s", c.File, ModelFileURL(c.File))
		}
	}
	if ModelFileURL("small-q5_1") != want["ggml-small-q5_1.bin"] || IsModelChoice("ggml-tiny.bin") {
		t.Fatal("short name")
	}
	c, _ := ParseConfig([]byte(`{"model":"base-q5_1"}`))
	if c.Model != "ggml-base-q5_1.bin" || c.ModelDownloadURL() != want["ggml-base-q5_1.bin"] {
		t.Fatal(c.Model, c.ModelDownloadURL())
	}
}

func TestLineFilter(t *testing.T) {
	var got []string
	f := &LineFilter{Match: InterestingServerLine, Fn: func(s string) { got = append(got, s) }}
	io.WriteString(f, "whisper_init_from_file: loading\r\nsystem_info: n_threads = 8 / 8 | AVX = 1 | AVX2 = 1\r\nRunning whis")
	io.WriteString(f, "per.cpp inference\nwhisper_print_timings:    total time =  1234.00 ms\n\npartial")
	if len(got) != 2 || !strings.HasPrefix(got[0], "system_info") || !strings.Contains(got[1], "total time") {
		t.Fatalf("%q", got)
	}
	if MsPerAudioSecond(3000, 2) != 1500 || MsPerAudioSecond(100, 0) != 0 {
		t.Fatal("ratio")
	}
}

func TestDiagnosticsRedaction(t *testing.T) {
	cfg := []byte(`{"hotkey":"rctrl","menuMaskKey":true,"apiKey":"abc","githubToken":"ghp_x","Password":"p","nested":{"clientSecret":"s","ok":1},"model":"m.bin","pressMode":"toggle"}`)
	lines, err := RedactedConfigLines(cfg, "model", "pressMode")
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(lines, "\n")
	for _, secret := range []string{"abc", "ghp_x", `"p"`, `"s"`} {
		if strings.Contains(joined, secret) {
			t.Fatalf("secret %s leaked:\n%s", secret, joined)
		}
	}
	for _, want := range []string{`apiKey = "***"`, `githubToken = "***"`, `Password = "***"`, `"clientSecret":"***"`, `"ok":1`, `hotkey = "rctrl"`, `menuMaskKey = true`} {
		if !strings.Contains(joined, want) {
			t.Fatalf("missing %s:\n%s", want, joined)
		}
	}
	if strings.Contains(joined, "model =") || strings.Contains(joined, "pressMode") {
		t.Fatal("skipped keys shown")
	}

	line := `2026-10-14 10:00:00.000 whisper_ok ms=900 chars=12 prompt_chars=40 text="マイクテスト" raw=こんにちは pasted="a \"b\" c" autocorrected=[プロリク→プルリク] prompt="用語"`
	r := RedactLogLine(line)
	for _, leak := range []string{"マイクテスト", "こんにちは", `\"b\"`, "プロリク", "用語"} {
		if strings.Contains(r, leak) {
			t.Fatalf("leak %s: %s", leak, r)
		}
	}
	if !strings.Contains(r, "prompt_chars=40") || !strings.Contains(r, "chars=12") || !strings.Contains(r, "text=***") {
		t.Fatal(r)
	}

	tail := TailLines([]byte("a\r\nb\r\nc text=\"x\"\r\n"), 2)
	if string(tail) != "b\r\nc text=***\r\n" {
		t.Fatalf("%q", tail)
	}
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "koe.log.1"), []byte("1\n2"), 0o644)
	os.WriteFile(filepath.Join(dir, "koe.log"), []byte("3\n4\n"), 0o644)
	if got := string(ReadTail(3, filepath.Join(dir, "koe.log.1"), filepath.Join(dir, "koe.log"), filepath.Join(dir, "none"))); got != "2\r\n3\r\n4\r\n" {
		t.Fatalf("%q", got)
	}

	var buf bytes.Buffer
	if err := WriteZip(&buf, []ZipFile{{"diagnostics.txt", []byte("x")}, {"koe.log", tail}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	zr, err := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if err != nil || len(zr.File) != 2 || zr.File[1].Name != "koe.log" {
		t.Fatal(err)
	}
	if DiagnosticsName(time.Date(2026, 10, 14, 9, 5, 0, 0, time.Local)) != "Koe-diagnostics-20261014-0905.zip" {
		t.Fatal("name")
	}
}
