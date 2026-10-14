package core

import (
	"bytes"
	"context"
	"fmt"
	"io"
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

// BaseURL of the local whisper-server.
func BaseURL(port int) string { return fmt.Sprintf("http://127.0.0.1:%d", port) }

// IsAlive: any HTTP response from the server counts as alive.
func IsAlive(baseURL string) bool {
	cl := http.Client{Timeout: time.Second}
	resp, err := cl.Get(baseURL + "/")
	if err != nil {
		return false
	}
	_ = resp.Body.Close()
	return true
}

// BuildInferenceBody builds the multipart body of POST /inference
// (response_format=text, prompt, temperature=0.0, file=audio.wav). Without
// fallback it also sends temperature_inc=0.0 so a hard segment is decoded
// once instead of up to six times.
func BuildInferenceBody(wav []byte, prompt string, fallback bool) (body []byte, contentType string, err error) {
	var b bytes.Buffer
	w := multipart.NewWriter(&b)
	fields := [][2]string{{"response_format", "text"}, {"prompt", prompt}, {"temperature", "0.0"}}
	if !fallback {
		fields = append(fields, [2]string{"temperature_inc", "0.0"})
	}
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
func Transcribe(ctx context.Context, baseURL string, wav []byte, prompt string, fallback bool) (string, error) {
	body, ct, err := BuildInferenceBody(wav, prompt, fallback)
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
