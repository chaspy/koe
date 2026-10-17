package core

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unsafe"
)

func TestConfigEngine(t *testing.T) {
	for in, want := range map[string]string{
		``:                        EngineWhisper,
		`{"engine":"parakeet"}`:   EngineParakeet,
		`{"engine":" Parakeet"}`:  EngineParakeet,
		`{"engine":"whisper"}`:    EngineWhisper,
		`{"engine":"sensevoice"}`: EngineWhisper,
	} {
		c, err := ParseConfig([]byte(in))
		if err != nil || c.Engine != want {
			t.Errorf("%s: engine=%q err=%v, want %q", in, c.Engine, err, want)
		}
	}
	if DefaultConfig().Engine != EngineWhisper {
		t.Fatal("the default engine must stay whisper")
	}
}

func TestParakeetThreads(t *testing.T) {
	for _, tc := range []struct{ cfg, cpus, want int }{{0, 1, 1}, {0, 2, 1}, {0, 4, 2}, {0, 12, 4}, {0, 32, 4}, {6, 2, 6}} {
		if got := (Config{Threads: tc.cfg}).ParakeetThreads(tc.cpus); got != tc.want {
			t.Errorf("threads=%d cpus=%d: %d, want %d", tc.cfg, tc.cpus, got, tc.want)
		}
	}
}

// The offsets come from windows/tools/sherpa-offsets.c (c-api.h of
// SherpaVersion, x86_64-pc-windows-msvc).
func TestSherpaRecognizerConfigLayout(t *testing.T) {
	var c sherpaRecognizerConfig
	for name, got := range map[string][2]uintptr{
		"size":                        {unsafe.Sizeof(c), 608},
		"feat_config.sample_rate":     {unsafe.Offsetof(c.SampleRate), 0},
		"feat_config.feature_dim":     {unsafe.Offsetof(c.FeatureDim), 4},
		"model_config.nemo_ctc.model": {unsafe.Offsetof(c.NemoCtcModel), 40},
		"model_config.tokens":         {unsafe.Offsetof(c.Tokens), 104},
		"model_config.num_threads":    {unsafe.Offsetof(c.NumThreads), 112},
		"model_config.debug":          {unsafe.Offsetof(c.Debug), 116},
		"model_config.provider":       {unsafe.Offsetof(c.Provider), 120},
		"decoding_method":             {unsafe.Offsetof(c.DecodingMethod), 528},
	} {
		if got[0] != got[1] {
			t.Errorf("%s at %d, c-api.h has %d", name, got[0], got[1])
		}
	}
}

func TestFloatSamples(t *testing.T) {
	got := FloatSamples(EncodeWAV([]int16{0, 16384, -32768, 32767}))
	want := []float32{0, 0.5, -1, 32767.0 / 32768}
	if len(got) != len(want) {
		t.Fatalf("%v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("%v, want %v", got, want)
		}
	}
	if len(FloatSamples(nil)) != 0 {
		t.Fatal("no wav, no samples")
	}
}

func TestSherpaResultText(t *testing.T) {
	got, err := SherpaResultText(`{"lang": "", "emotion": "", "event": "", "text": " 今日は晴れです。", "timestamps": [], "tokens":["今日","は"], "words": []}`)
	if err != nil || got != "今日は晴れです。" {
		t.Fatalf("%q %v", got, err)
	}
	if _, err := SherpaResultText("not json"); err == nil {
		t.Fatal("broken JSON must be an error")
	}
}

func TestExtractParakeet(t *testing.T) {
	models := t.TempDir()
	dir := ParakeetDir(models)
	if ParakeetReady(dir) {
		t.Fatal("empty dir is not ready")
	}
	// test_wavs/tokens.txt comes first in the archive and must be skipped
	if err := ExtractParakeet(filepath.Join("testdata", "parakeet-mini.tar.bz2"), dir); err != nil {
		t.Fatal(err)
	}
	if !ParakeetReady(dir) {
		t.Fatal("not ready after extraction")
	}
	if b, _ := os.ReadFile(filepath.Join(dir, ParakeetTokensFile)); string(b) != "<unk> 0\n" {
		t.Fatalf("tokens.txt = %q (test_wavs/tokens.txt taken?)", b)
	}
	if _, err := os.Stat(dir + ".tmp"); !os.IsNotExist(err) {
		t.Fatal("tmp dir left behind")
	}
	ents, _ := os.ReadDir(dir)
	if len(ents) != 2 {
		t.Fatalf("only the model and tokens are kept: %v", ents)
	}

	// a cut-off archive leaves no model
	b, _ := os.ReadFile(filepath.Join("testdata", "parakeet-mini.tar.bz2"))
	cut := filepath.Join(models, "cut.tar.bz2")
	_ = os.WriteFile(cut, b[:len(b)/2], 0o644)
	other := filepath.Join(models, "other")
	if err := ExtractParakeet(cut, other); err == nil || ParakeetReady(other) {
		t.Fatalf("cut archive: err=%v ready=%v", err, ParakeetReady(other))
	}
}

// fakeRecognizer answers with replies in order and counts calls.
type fakeRecognizer struct {
	replies []string
	err     error
	calls   int
}

func (f *fakeRecognizer) Recognize(_ context.Context, _ []byte, _ string, _ bool, _ int) (string, error) {
	f.calls++
	if f.err != nil {
		return "", f.err
	}
	i := min(f.calls-1, len(f.replies)-1)
	return f.replies[i], nil
}

func TestTranscribeUtteranceRecognizer(t *testing.T) {
	wav := EncodeWAV(make([]int16, 16000*3))
	entries := []Entry{{Term: "Slack", Aliases: []string{"スラック"}}}
	req := func(f *fakeRecognizer, single bool) UtteranceRequest {
		return UtteranceRequest{Recognizer: f, SingleShot: single, WAV: wav, Voiced: 3, Model: DefaultModel, AudioCtx: AudioCtxAuto, Entries: entries}
	}

	// Autocorrect runs on the recognizer's text, as with whisper
	f := &fakeRecognizer{replies: []string{" スラックで送ります。 "}}
	res := TranscribeUtterance(context.Background(), req(f, true))
	if res.Outcome != OutcomeOK || res.Text != "Slackで送ります。" || len(res.Passes[0].Applied) != 1 || f.calls != 1 {
		t.Fatalf("autocorrect: %+v calls=%d", res, f.calls)
	}

	// single shot: no retry for an empty text, a loop or a stock phrase
	f = &fakeRecognizer{replies: []string{""}}
	if res = TranscribeUtterance(context.Background(), req(f, true)); res.Outcome != OutcomeHallucination || f.calls != 1 || res.RetriedWithoutPrompt {
		t.Fatalf("empty: %+v calls=%d", res, f.calls)
	}
	loop := "了解です" + strings.Repeat("ドラフ、", 40)
	f = &fakeRecognizer{replies: []string{loop}}
	if res = TranscribeUtterance(context.Background(), req(f, true)); res.Outcome != OutcomeCollapsed || res.Text != "了解ですドラフ、" || f.calls != 1 || res.RetriedForRepetition {
		t.Fatalf("loop: %+v calls=%d", res, f.calls)
	}
	f = &fakeRecognizer{replies: []string{"(音楽)了解です"}}
	if res = TranscribeUtterance(context.Background(), req(f, true)); res.Outcome != OutcomeStripped || res.Text != "了解です" || f.calls != 1 {
		t.Fatalf("stock phrase: %+v calls=%d", res, f.calls)
	}

	// without SingleShot the retries still happen (whisper's path)
	f = &fakeRecognizer{replies: []string{loop, "了解です"}}
	if res = TranscribeUtterance(context.Background(), req(f, false)); res.Outcome != OutcomeOK || f.calls != 2 || !res.RetriedForRepetition {
		t.Fatalf("retry: %+v calls=%d", res, f.calls)
	}

	f = &fakeRecognizer{err: errors.New("boom")}
	if res = TranscribeUtterance(context.Background(), req(f, true)); res.Outcome != OutcomeError || res.Err == nil {
		t.Fatalf("error: %+v", res)
	}
}

func TestCheckSHA256(t *testing.T) {
	p := filepath.Join(t.TempDir(), "x")
	_ = os.WriteFile(p, []byte("abc"), 0o644)
	if err := CheckSHA256(p, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"); err != nil {
		t.Fatal(err)
	}
	if err := CheckSHA256(p, ParakeetModelSHA256); err == nil {
		t.Fatal("a different file must fail")
	}
	if err := CheckSHA256(filepath.Join(t.TempDir(), "missing"), ParakeetModelSHA256); err == nil {
		t.Fatal("a missing file must fail")
	}
}
