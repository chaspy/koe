package core

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func probe(log string) *GPUProbe {
	p := &GPUProbe{}
	for _, l := range strings.Split(log, "\n") {
		p.Line(l)
	}
	return p
}

func TestGPUProbe(t *testing.T) {
	cases := []struct {
		log, backend, reason string
	}{
		{"whisper_backend_init_gpu: device 0: CPU (type: 0)\nwhisper_backend_init_gpu: device 1: Vulkan0 (type: 2)\nwhisper_backend_init_gpu: found GPU device 1: Vulkan0 (type: 2, cnt: 0)\nwhisper_backend_init_gpu: using Vulkan0 backend\nwhisper_model_load: Vulkan0 total size = 190.00 MB", "Vulkan0", ""},
		{"ggml_vulkan: No devices found.\nwhisper_backend_init_gpu: device 0: CPU (type: 0)\nwhisper_backend_init_gpu: no GPU found", "", FallbackNoDevice},
		{"whisper_backend_init_gpu: using Vulkan0 backend\nwhisper_backend_init_gpu: failed to initialize Vulkan0 backend", "", FallbackInitFailed},
		{"whisper_init_from_file_with_params_no_state: loading model\nsystem_info: n_threads = 4", "", FallbackNoBackend},
		{"whisper_backend_init_gpu: using Vulkan0 backend\r", "Vulkan0", ""},
	}
	for _, c := range cases {
		p := probe(c.log)
		if p.Backend() != c.backend || p.FallbackReason() != c.reason {
			t.Errorf("%q: backend=%q reason=%q, want %q %q", c.log, p.Backend(), p.FallbackReason(), c.backend, c.reason)
		}
	}
}

func TestGPUConfig(t *testing.T) {
	c, _ := ParseConfig([]byte(`{}`))
	if c.GPU != GPUAuto || c.GPUAudioCtx != 0 {
		t.Fatalf("defaults: %q %v", c.GPU, c.GPUAudioCtx)
	}
	for in, want := range map[string]string{`{"gpu":"OFF"}`: GPUOff, `{"gpu":"x"}`: GPUAuto, `{"gpu":"auto"}`: GPUAuto} {
		if c, _ := ParseConfig([]byte(in)); c.GPU != want {
			t.Errorf("%s: %q", in, c.GPU)
		}
	}
	c, _ = ParseConfig([]byte(`{"gpuAudioCtx":"auto","audioCtx":0}`))
	if c.AudioCtxSetting(true, c.AudioCtx) != AudioCtxAuto || c.AudioCtxSetting(false, c.AudioCtx) != 0 {
		t.Fatal("gpuAudioCtx on GPU, audioCtx on CPU")
	}
	d := DefaultConfig()
	if d.AudioCtxSetting(true, AudioCtxAuto).For(3, DefaultModel) != 0 || d.AudioCtxSetting(false, AudioCtxAuto).For(3, DefaultModel) != 768 {
		t.Fatal("GPU uses the whole window by default; CPU keeps speed first")
	}
}

func TestBackendChoice(t *testing.T) {
	ad := []string{"Intel(R) Graphics"}
	c := NewBackendChoice("0.4.0", `C:\m\ggml-small-q5_1.bin`, 190, ad, BackendCPU, "cpu_faster")
	if !c.Matches("0.4.0", "ggml-small-q5_1.bin", 190, ad) {
		t.Fatal("same key must match")
	}
	for name, ok := range map[string]bool{
		"version": c.Matches("0.4.1", "ggml-small-q5_1.bin", 190, ad),
		"model":   c.Matches("0.4.0", "ggml-base-q5_1.bin", 190, ad),
		"size":    c.Matches("0.4.0", "ggml-small-q5_1.bin", 191, ad),
		"adapter": c.Matches("0.4.0", "ggml-small-q5_1.bin", 190, []string{"Intel(R) Arc(TM) Graphics"}),
	} {
		if ok {
			t.Errorf("a different %s must be measured again", name)
		}
	}
	path := filepath.Join(t.TempDir(), "backend.json")
	if _, ok := LoadBackendChoice(path); ok {
		t.Fatal("missing file")
	}
	c.GPUms, c.CPUms = 4100, 3900
	if err := SaveBackendChoice(path, c); err != nil {
		t.Fatal(err)
	}
	got, ok := LoadBackendChoice(path)
	if !ok || !got.Matches("0.4.0", "ggml-small-q5_1.bin", 190, ad) || got.GPUms != 4100 || got.Choice != BackendCPU {
		t.Fatalf("round trip: %+v", got)
	}
	os.WriteFile(path, []byte("{broken"), 0o644)
	if _, ok := LoadBackendChoice(path); ok {
		t.Fatal("broken file")
	}
	for _, c := range []struct {
		g, c int64
		want string
	}{{1000, 3000, BackendGPU}, {3000, 1000, BackendCPU}, {2000, 2000, BackendCPU}, {0, 1000, BackendCPU}, {1000, 0, BackendGPU}, {0, 0, BackendCPU}} {
		if got := PickBackend(c.g, c.c); got != c.want {
			t.Errorf("PickBackend(%d, %d) = %s", c.g, c.c, got)
		}
	}
}

func TestMeasureTranscribe(t *testing.T) {
	srv, seen := fakeWhisper(t, "テストです")
	ms, err := MeasureTranscribe(context.Background(), srv.URL, EncodeWAV(make([]int16, 1600)), "p", 0)
	if err != nil || ms < 0 || len(*seen) != 2 || (*seen)[1].actx != "0" {
		t.Fatalf("warm-up + one timed request: %d %v %+v", ms, err, *seen)
	}
	if _, err := MeasureTranscribe(context.Background(), "http://127.0.0.1:1", nil, "", 0); err == nil {
		t.Fatal("server down must be an error")
	}
}

func TestProbeWAV(t *testing.T) {
	pcm := []int16{0, 1, -1, 32767, -32768}
	if got := WAVSamples(EncodeWAV(pcm)); !slices.Equal(got, pcm) {
		t.Fatalf("WAVSamples round trip: %v", got)
	}
	raw, err := os.ReadFile(filepath.Join("..", "assets", ProbeWAV))
	if err != nil {
		t.Fatal(err)
	}
	s := WAVSamples(raw)
	if sec := Seconds(TrimSilence(s)); sec < 2 || sec > 8 || Peak(s) < 3000 {
		t.Fatalf("probe.wav must be a few seconds of clear speech: %.2f s peak %d", sec, Peak(s))
	}
}
