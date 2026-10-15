package core

import (
	"archive/zip"
	"bytes"
	"encoding/json"
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

func TestAutoAudioCtx(t *testing.T) {
	cases := []struct {
		sec  float64
		want int
	}{
		{0, 384}, {2, 384}, {5.81, 384}, {5.82, 385}, {10, 614}, {20, 1164},
		{25.1, 1445}, {26.2, 1500}, {29.99, 1500}, {30, 0}, {45, 0},
	}
	for _, c := range cases {
		if got := AutoAudioCtx(c.sec); got != c.want {
			t.Errorf("AutoAudioCtx(%v) = %d, want %d", c.sec, got, c.want)
		}
		if got := AudioCtxAuto.For(c.sec, DefaultModel); got != c.want {
			t.Errorf("auto For(%v) = %d", c.sec, got)
		}
	}
	if AudioCtx(0).For(3, DefaultModel) != 0 || AudioCtx(768).For(3, "ggml-base-q5_1.bin") != 768 {
		t.Fatal("fixed audioCtx")
	}
	// large-v3 returned empty text with a smaller window: always the whole one
	for _, m := range []string{"ggml-large-v3-turbo-q5_0.bin", `C:\models\ggml-large-v3.bin`, "D:/m/GGML-LARGE-V3-TURBO.bin"} {
		if !FullWindowOnly(m) || AudioCtxAuto.For(3, m) != 0 || AudioCtx(768).For(3, m) != 0 {
			t.Errorf("%s must use the whole window", m)
		}
	}
	for _, m := range []string{"ggml-small-q5_1.bin", "ggml-base-q5_1.bin", "ggml-large-v2.bin", `C:\large-v3\ggml-small.bin`} {
		if FullWindowOnly(m) {
			t.Errorf("%s does not need the whole window", m)
		}
	}
}

func TestAudioCtxConfig(t *testing.T) {
	cases := map[string]AudioCtx{
		`{}`:                  AudioCtxAuto,
		`{"audioCtx":"auto"}`: AudioCtxAuto,
		`{"audioCtx":"x"}`:    AudioCtxAuto,
		`{"audioCtx":-5}`:     AudioCtxAuto,
		`{"audioCtx":null}`:   AudioCtxAuto,
		`{"audioCtx":0}`:      0,
		`{"audioCtx":768}`:    768,
		`{"audioCtx":1500}`:   0,
		`{"audioCtx":4000}`:   0,
	}
	for in, want := range cases {
		c, err := ParseConfig([]byte(in))
		if err != nil || c.AudioCtx != want {
			t.Errorf("%s: %v %v", in, c.AudioCtx, err)
		}
	}
	for v, want := range map[AudioCtx]string{AudioCtxAuto: `"auto"`, 0: `0`, 768: `768`} {
		b, _ := json.Marshal(v)
		if string(b) != want || (v == AudioCtxAuto && v.String() != "auto") {
			t.Errorf("marshal %d = %s", v, b)
		}
	}
	path := filepath.Join(t.TempDir(), "config.json")
	if err := SetConfigValue(path, "audioCtx", AudioCtx(0)); err != nil {
		t.Fatal(err)
	}
	c, _ := LoadConfig(path)
	if c.AudioCtx != 0 {
		t.Fatal("saved off", c.AudioCtx)
	}
	SetConfigValue(path, "audioCtx", AudioCtxAuto)
	if c, _ = LoadConfig(path); c.AudioCtx != AudioCtxAuto {
		t.Fatal("saved auto", c.AudioCtx)
	}
}

func TestDefaultModelOnlyWhenMissing(t *testing.T) {
	c, _ := ParseConfig([]byte(`{"hotkey":"ralt"}`))
	if c.Model != "ggml-small-q5_1.bin" {
		t.Fatal("no model key ->", c.Model)
	}
	c, _ = ParseConfig([]byte(`{"model":"ggml-large-v3-turbo-q5_0.bin"}`))
	if c.Model != "ggml-large-v3-turbo-q5_0.bin" {
		t.Fatal("a chosen model must be kept:", c.Model)
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
	if len(ModelChoices) != 3 || ModelChoices[0].File != DefaultModel || DefaultModel != "ggml-small-q5_1.bin" {
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
