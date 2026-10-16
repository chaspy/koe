package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// Backends a choice can name.
const (
	BackendGPU = "gpu"
	BackendCPU = "cpu"
)

// ProbeWAV is the short test recording (synthetic speech, assets/probe.wav)
// timed on the GPU and on the CPU build to pick the faster one.
const ProbeWAV = "probe.wav"

// BackendChoice is %LOCALAPPDATA%\Koe\backend.json: which build to start with
// gpu "auto", measured once for this version, model and set of adapters.
// Small integrated GPUs can be slower than the CPU, so a GPU that works is
// still only used when it was faster.
type BackendChoice struct {
	Version  string   `json:"version"`
	Model    string   `json:"model"` // file name
	Size     int64    `json:"modelSize"`
	Adapters []string `json:"adapters"`
	Choice   string   `json:"choice"` // BackendGPU | BackendCPU
	Reason   string   `json:"reason"` // "gpu_faster" | "cpu_faster" | a Fallback* reason
	GPUms    int64    `json:"gpuMs,omitempty"`
	CPUms    int64    `json:"cpuMs,omitempty"`
	At       string   `json:"at"`
}

// Matches reports whether the choice was made for this version, model and
// adapters; otherwise Koe measures again.
func (c BackendChoice) Matches(version, model string, size int64, adapters []string) bool {
	return c.Version == version && c.Model == modelName(model) && c.Size == size &&
		slices.Equal(c.Adapters, adapters) && (c.Choice == BackendGPU || c.Choice == BackendCPU)
}

func modelName(m string) string { return filepath.Base(strings.ReplaceAll(m, `\`, "/")) }

// NewBackendChoice fills the key fields.
func NewBackendChoice(version, model string, size int64, adapters []string, choice, reason string) BackendChoice {
	return BackendChoice{Version: version, Model: modelName(model), Size: size, Adapters: append([]string{}, adapters...),
		Choice: choice, Reason: reason, At: time.Now().Format(time.RFC3339)}
}

// LoadBackendChoice reads path; ok is false if missing or broken.
func LoadBackendChoice(path string) (BackendChoice, bool) {
	var c BackendChoice
	b, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(b, &c) != nil {
		return BackendChoice{}, false
	}
	return c, true
}

// SaveBackendChoice writes path.
func SaveBackendChoice(path string, c BackendChoice) error {
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o644)
}

// PickBackend is the faster of the two measured times (the GPU must be
// strictly faster; a failed measurement is <= 0).
func PickBackend(gpuMS, cpuMS int64) string {
	if gpuMS > 0 && (cpuMS <= 0 || gpuMS < cpuMS) {
		return BackendGPU
	}
	return BackendCPU
}

// MeasureTranscribe times one transcription of wav after an untimed warm-up
// request (the first request after start is slower), with the window the
// backend would really use.
func MeasureTranscribe(ctx context.Context, baseURL string, wav []byte, prompt string, audioCtx int) (int64, error) {
	if _, err := Transcribe(ctx, baseURL, wav, prompt, false, audioCtx); err != nil {
		return 0, err
	}
	t0 := time.Now()
	if _, err := Transcribe(ctx, baseURL, wav, prompt, false, audioCtx); err != nil {
		return 0, err
	}
	return time.Since(t0).Milliseconds(), nil
}
