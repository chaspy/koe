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
func ServerArgs(c Config, modelPath string, threads int) []string {
	return []string{
		"-m", modelPath,
		"-l", c.Language,
		"--host", "127.0.0.1",
		"--port", strconv.Itoa(c.Port),
		"-t", strconv.Itoa(threads),
		"--prompt", c.Prompt,
	}
}

// AutoThreads picks whisper threads from the CPU count: half the logical
// CPUs, clamped to [4, 8].
func AutoThreads(numCPU int) int {
	t := numCPU / 2
	if t < 4 {
		t = 4
	}
	if t > 8 {
		t = 8
	}
	return t
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
// (response_format=text, prompt, temperature=0.0, file=audio.wav).
func BuildInferenceBody(wav []byte, prompt string) (body []byte, contentType string, err error) {
	var b bytes.Buffer
	w := multipart.NewWriter(&b)
	for _, f := range [][2]string{{"response_format", "text"}, {"prompt", prompt}, {"temperature", "0.0"}} {
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
func Transcribe(ctx context.Context, baseURL string, wav []byte, prompt string) (string, error) {
	body, ct, err := BuildInferenceBody(wav, prompt)
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
