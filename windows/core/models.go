package core

import (
	"path/filepath"
	"strings"
)

// ModelChoice is a model offered in the tray menu (speed vs accuracy).
type ModelChoice struct {
	File  string // file name in the models dir and on Hugging Face
	Label string // menu label
}

// ModelChoices, the default first. File names checked on
// huggingface.co/ggerganov/whisper.cpp (190 / 574 / 60 MB).
var ModelChoices = []ModelChoice{
	{"ggml-small-q5_1.bin", "small-q5_1（既定・速さと精度のバランス、約 190MB）"},
	{"ggml-large-v3-turbo-q5_0.bin", "large-v3-turbo-q5_0（精度重視・遅い、約 550MB）"},
	{"ggml-base-q5_1.bin", "base-q5_1（とても速いが誤変換が多い、約 60MB）"},
}

// FullWindowOnly: large-v3 models (turbo included) need whisper's whole 30 s
// window; with a smaller audio_ctx they returned empty text (windows/bench).
func FullWindowOnly(model string) bool {
	return strings.Contains(strings.ToLower(filepath.Base(strings.ReplaceAll(model, `\`, "/"))), "large-v3")
}

// NormalizeModel accepts a short name ("small-q5_1", "ggml-small-q5_1") as
// well as a file name or path, and returns the file name / path.
func NormalizeModel(m string) string {
	m = strings.TrimSpace(m)
	if m == "" || filepath.IsAbs(m) || strings.ContainsAny(m, `/\`) || strings.Contains(m, ":") {
		return m
	}
	if !strings.HasSuffix(m, ".bin") {
		m += ".bin"
	}
	if !strings.HasPrefix(m, "ggml-") {
		m = "ggml-" + m
	}
	return m
}

// ModelFileURL is the Hugging Face download URL of a model file name.
func ModelFileURL(file string) string {
	return ModelBaseURL + filepath.Base(strings.ReplaceAll(NormalizeModel(file), `\`, "/"))
}

// IsModelChoice reports whether file is one of ModelChoices.
func IsModelChoice(file string) bool {
	for _, c := range ModelChoices {
		if c.File == file {
			return true
		}
	}
	return false
}
