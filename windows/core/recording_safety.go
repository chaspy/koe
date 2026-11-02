package core

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

// MustKeepRecording mirrors macOS RecordingSafety, including the strict boundary.
func MustKeepRecording(seconds, held float64, saveHistory bool) bool {
	return saveHistory && max(seconds, held) > 2
}

// WriteRecordingEnd records only a reason code and durations, never speech or paths.
func WriteRecordingEnd(path, reason string, seconds, held float64) (err error) {
	event := struct {
		At           string  `json:"t"`
		Event        string  `json:"outcome"`
		Reason       string  `json:"reason"`
		AudioSeconds float64 `json:"audio_seconds"`
		HoldSeconds  float64 `json:"hold_seconds"`
	}{time.Now().Format(time.RFC3339Nano), "recording_ended", reason, seconds, held}
	b, err := json.Marshal(event)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Clean(path), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, f.Close()) }()
	if _, err = f.Write(append(b, '\n')); err != nil {
		return err
	}
	return f.Sync()
}
