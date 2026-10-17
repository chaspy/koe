package core

import (
	"archive/tar"
	"compress/bzip2"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// Engines the config "engine" can name. whisper is the default; parakeet is
// opt-in while it is being measured.
const (
	EngineWhisper  = "whisper"
	EngineParakeet = "parakeet"
)

// Recognizer turns one utterance (16 kHz mono 16-bit WAV) into text. The
// prompt, fallback and audioCtx are whisper's; other engines ignore them.
type Recognizer interface {
	Recognize(ctx context.Context, wav []byte, prompt string, fallback bool, audioCtx int) (string, error)
}

// WhisperHTTP is the local whisper-server (POST /inference).
type WhisperHTTP struct{ BaseURL string }

func (w WhisperHTTP) Recognize(ctx context.Context, wav []byte, prompt string, fallback bool, audioCtx int) (string, error) {
	return Transcribe(ctx, w.BaseURL, wav, prompt, fallback, audioCtx)
}

// Parakeet-ja (NVIDIA parakeet-tdt_ctc-0.6b-ja, CC-BY-4.0) converted to
// sherpa-onnx by k2-fsa. The int8 export has only the CTC head
// (model.int8.onnx + tokens.txt), so it is decoded greedily: sherpa-onnx's
// hotwords need a transducer (TDT) model and are not available.
const (
	ParakeetModelName  = "sherpa-onnx-nemo-parakeet-tdt_ctc-0.6b-ja-35000-int8"
	ParakeetModelURL   = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/" + ParakeetModelName + ".tar.bz2"
	ParakeetModelFile  = "model.int8.onnx"
	ParakeetTokensFile = "tokens.txt"
	// ParakeetModelSHA256 is the archive's sha256: the "digest" GitHub shows
	// for the asset in the asr-models release (uploaded 2025-07-09, 489389564
	// bytes), checked 2026-10-17 against a fresh download. A different file
	// is removed and never unpacked.
	ParakeetModelSHA256 = "4b0a800ef29f4f4c8667339bf6f60d5bfdc2852ddc9dc5741aea65b6f8d1306b"
	// SherpaVersion is the sherpa-onnx release whose sherpa-onnx-c-api.dll
	// Koe ships (windows/build.sh). sherpaRecognizerConfig matches its c-api.h.
	SherpaVersion = "v1.13.8"
	SherpaDLL     = "sherpa-onnx-c-api.dll"
)

// ParakeetDir is where the model files are kept: models\<ParakeetModelName>.
func ParakeetDir(modelsDir string) string { return filepath.Join(modelsDir, ParakeetModelName) }

// ParakeetReady reports whether the model files are in dir.
func ParakeetReady(dir string) bool {
	for _, f := range []string{ParakeetModelFile, ParakeetTokensFile} {
		if fi, err := os.Stat(filepath.Join(dir, f)); err != nil || fi.Size() == 0 {
			return false
		}
	}
	return true
}

// CheckSHA256 returns an error unless the file at path has the sha256 want (hex).
func CheckSHA256(path, want string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return err
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != want {
		return fmt.Errorf("%s: sha256 %s, want %s", filepath.Base(path), got, want)
	}
	return nil
}

// ExtractParakeet takes model.int8.onnx and tokens.txt out of the release
// archive (tar.bz2) into dir. Other files (test_wavs) are skipped; names are
// reduced to their base name, so nothing is written outside dir. The files go
// to dir+".tmp" first, so a cut-off extraction is never taken for a model.
func ExtractParakeet(archive, dir string) error {
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	tmp := dir + ".tmp"
	_ = os.RemoveAll(tmp)
	if err := os.MkdirAll(tmp, 0o755); err != nil {
		return err
	}
	want := map[string]bool{ParakeetModelFile: true, ParakeetTokensFile: true}
	tr := tar.NewReader(bzip2.NewReader(f))
	for len(want) > 0 {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("extract %s: %w", filepath.Base(archive), err)
		}
		rel := strings.Trim(strings.TrimPrefix(h.Name, "./"), "/")
		name := path.Base(rel)
		// only the model directory's own files (not test_wavs/...)
		if !h.FileInfo().Mode().IsRegular() || !want[name] || strings.Count(rel, "/") > 1 {
			continue
		}
		out, err := os.Create(filepath.Join(tmp, name))
		if err != nil {
			return err
		}
		if _, err := io.Copy(out, tr); err != nil {
			out.Close()
			return fmt.Errorf("extract %s: %w", name, err)
		}
		if err := out.Close(); err != nil {
			return err
		}
		delete(want, name)
	}
	if len(want) > 0 {
		return fmt.Errorf("extract %s: %d file(s) missing", filepath.Base(archive), len(want))
	}
	_ = os.RemoveAll(dir)
	return os.Rename(tmp, dir)
}

// MaxParakeetThreads caps the automatic thread count so the rest of the PC
// stays usable (the first measurements used 2 threads; the bench can tune it).
const MaxParakeetThreads = 4

// ParakeetThreads is the configured thread count, or half the logical CPUs
// (1 to MaxParakeetThreads) when 0.
func (c Config) ParakeetThreads(numCPU int) int {
	if c.Threads > 0 {
		return c.Threads
	}
	return min(max(numCPU/2, 1), MaxParakeetThreads)
}

// FloatSamples is the WAV's samples scaled to [-1, 1), as sherpa-onnx takes them.
func FloatSamples(wav []byte) []float32 {
	pcm := WAVSamples(wav)
	out := make([]float32, len(pcm))
	for i, v := range pcm {
		out[i] = float32(v) / 32768
	}
	return out
}

// SherpaResultText is the "text" of sherpa-onnx's result JSON, trimmed.
func SherpaResultText(js string) (string, error) {
	var r struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal([]byte(js), &r); err != nil {
		return "", fmt.Errorf("sherpa-onnx result: %w", err)
	}
	return strings.TrimSpace(r.Text), nil
}

// sherpaRecognizerConfig is SherpaOnnxOfflineRecognizerConfig of
// sherpa-onnx SherpaVersion (c-api.h) with only the fields Koe sets; the
// rest is padding left zero, which the C API reads as "use the default".
// The offsets are checked against the header by windows/tools/sherpa-offsets.c
// (clang, for x86_64-pc-windows-msvc) and by TestSherpaRecognizerConfigLayout.
// Re-check both when SherpaVersion changes.
type sherpaRecognizerConfig struct {
	SampleRate     int32 // feat_config.sample_rate (0)
	FeatureDim     int32 // feat_config.feature_dim (4)
	_              [32]byte
	NemoCtcModel   *byte // model_config.nemo_ctc.model (40)
	_              [56]byte
	Tokens         *byte // model_config.tokens (104)
	NumThreads     int32 // model_config.num_threads (112)
	Debug          int32 // model_config.debug (116)
	Provider       *byte // model_config.provider (120)
	_              [400]byte
	DecodingMethod *byte // decoding_method (528)
	_              [72]byte
}
