package core

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"strconv"
	"time"
)

// ServerArgs are the whisper-server command line arguments.
// All flags exist in whisper-server v1.9.2 (examples/server/server.cpp):
//
//	-t      threads for the encoder / decoder
//	-bs 1   beam size 1 = greedy decoding (the default is already greedy; explicit)
//	-bo 1   keep 1 candidate (only matters when sampling at temperature > 0)
//	-fa     flash attention (default on in v1.9.2; explicit so older defaults do not slow it down)
//
// The temperature fallback (re-decoding up to 5 times at 0.2, 0.4, ...) is
// turned off per request with temperature_inc=0 (see BuildInferenceBody):
// v1.9.2's server parses -nf but never applies it.
func ServerArgs(c Config, modelPath string, threads int) []string {
	return []string{
		"-m", modelPath,
		"-l", c.Language,
		"--host", "127.0.0.1",
		"--port", strconv.Itoa(c.Port),
		"-t", strconv.Itoa(threads),
		"-bs", "1",
		"-bo", "1",
		"-fa",
		"--prompt", c.Prompt,
	}
}

// MaxThreads caps the automatic thread count.
const MaxThreads = 16

// AutoThreads picks whisper threads: the number of logical CPUs, capped at
// MaxThreads.
func AutoThreads(numCPU int) int {
	if numCPU < 1 {
		return 1
	}
	if numCPU > MaxThreads {
		return MaxThreads
	}
	return numCPU
}

// ThreadsFor is the configured thread count, or AutoThreads when 0 / negative.
func (c Config) ThreadsFor(numCPU int) int {
	if c.Threads > 0 {
		return c.Threads
	}
	return AutoThreads(numCPU)
}

// AudioCtx is the audioCtx setting: AudioCtxAuto, 0 (whisper's whole 30 s
// window) or a fixed number of encoder frames (50 per second).
//
// whisper's encoder always processes the full 30 s window unless audio_ctx is
// smaller, so on CPU a 3 s utterance costs as much as a 30 s one. Sizing the
// window to the utterance makes short utterances several times faster, at a
// small cost in accuracy.
type AudioCtx int

const (
	AudioCtxAuto AudioCtx = -1
	MaxAudioCtx           = 1500 // the 30 s window
	MinAudioCtx           = 768  // 15 s; with 384 short real-voice utterances lost accuracy (windows/bench/results.md)
)

// UnmarshalJSON accepts "auto" or a number. Anything else (null, a negative
// number) is auto; MaxAudioCtx or more is 0 (the whole window).
func (c *AudioCtx) UnmarshalJSON(b []byte) error {
	var n *float64
	if err := json.Unmarshal(b, &n); err != nil || n == nil || *n < 0 {
		*c = AudioCtxAuto
		return nil
	}
	*c = AudioCtx(*n)
	if *n >= MaxAudioCtx {
		*c = 0
	}
	return nil
}

func (c AudioCtx) MarshalJSON() ([]byte, error) {
	if c == AudioCtxAuto {
		return []byte(`"auto"`), nil
	}
	return []byte(strconv.Itoa(int(c))), nil
}

func (c AudioCtx) String() string {
	if c == AudioCtxAuto {
		return "auto"
	}
	return strconv.Itoa(int(c))
}

// For is the audio_ctx to send for an utterance of seconds with model:
// always 0 for models that need the whole window (FullWindowOnly).
func (c AudioCtx) For(seconds float64, model string) int {
	if FullWindowOnly(model) {
		return 0
	}
	if c == AudioCtxAuto {
		return AutoAudioCtx(seconds)
	}
	return int(c)
}

// AutoAudioCtx sizes the encoder window to the audio: 50 frames per second
// plus 10% and 64 frames of margin, between MinAudioCtx and MaxAudioCtx.
// 30 s or more uses the whole window (0).
func AutoAudioCtx(seconds float64) int { return AutoAudioCtxMin(seconds, MinAudioCtx) }

// AutoAudioCtxMin is AutoAudioCtx with another lower bound (for experiments
// with the minimum window; Koe uses MinAudioCtx).
func AutoAudioCtxMin(seconds float64, min int) int {
	if seconds >= 30 {
		return 0
	}
	n := int(math.Ceil(seconds*50*1.1-1e-9)) + 64
	if n < min {
		n = min
	}
	if n > MaxAudioCtx {
		n = MaxAudioCtx
	}
	return n
}

// BaseURL of the local whisper-server.
func BaseURL(port int) string { return fmt.Sprintf("http://127.0.0.1:%d", port) }

// IsHealthy: GET /health answers 200 once whisper-server has loaded its model
// (503 while loading). It says nothing about which process answered; Koe
// also checks that the listener is the server it started (CheckServer).
func IsHealthy(baseURL string) bool {
	cl := http.Client{Timeout: time.Second}
	resp, err := cl.Get(baseURL + "/health")
	if err != nil {
		return false
	}
	_ = resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// BuildInferenceBody builds the multipart body of POST /inference
// (response_format=text, prompt, temperature=0.0, temperature_inc, audio_ctx,
// file=audio.wav). Without fallback temperature_inc=0.0 decodes a hard segment
// once instead of up to six times; with fallback it is 0.2 (whisper's default).
// Both are always sent so the request does not depend on server defaults.
func BuildInferenceBody(wav []byte, prompt string, fallback bool, audioCtx int) (body []byte, contentType string, err error) {
	var b bytes.Buffer
	w := multipart.NewWriter(&b)
	inc := "0.0"
	if fallback {
		inc = "0.2"
	}
	fields := [][2]string{{"response_format", "text"}, {"prompt", prompt}, {"temperature", "0.0"}, {"temperature_inc", inc}, {"audio_ctx", strconv.Itoa(audioCtx)}}
	for _, f := range fields {
		if err := w.WriteField(f[0], f[1]); err != nil {
			return nil, "", err
		}
	}
	h := make(textproto.MIMEHeader)
	h.Set("Content-Disposition", `form-data; name="file"; filename="audio.wav"`)
	h.Set("Content-Type", "audio/wav")
	pw, err := w.CreatePart(h)
	if err != nil {
		return nil, "", err
	}
	if _, err := pw.Write(wav); err != nil {
		return nil, "", err
	}
	if err := w.Close(); err != nil {
		return nil, "", err
	}
	return b.Bytes(), w.FormDataContentType(), nil
}

// Transcribe posts wav to /inference and returns the cleaned text.
func Transcribe(ctx context.Context, baseURL string, wav []byte, prompt string, fallback bool, audioCtx int) (string, error) {
	body, ct, err := BuildInferenceBody(wav, prompt, fallback, audioCtx)
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(ctx, 120*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/inference", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", ct)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode != http.StatusOK {
		s := string(raw)
		if len(s) > 200 {
			s = s[:200]
		}
		return "", fmt.Errorf("whisper-server HTTP %d: %s", resp.StatusCode, s)
	}
	return CleanServerText(string(raw)), nil
}
