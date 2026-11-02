package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRecordingSafetyTable(t *testing.T) {
	for _, seconds := range []float64{0, 0.2, 2, 2.001, 60, 300} {
		for _, held := range []float64{0.2, 2, 2.001, 60, 300} {
			for _, enabled := range []bool{false, true} {
				want := enabled && (seconds > 2 || held > 2)
				if MustKeepRecording(seconds, held, enabled) != want {
					t.Fatalf("seconds=%v held=%v enabled=%v", seconds, held, enabled)
				}
			}
		}
	}
}

func TestLongHoldSurvivesDuplicatePress(t *testing.T) {
	start := time.Now()
	h := HoldTracker{HotkeyVK: 1, MinHold: time.Second}
	if h.Down(1, start) != ActStart {
		t.Fatal("start")
	}
	for _, seconds := range []int{1, 60, 300, 600} {
		if h.Down(1, start.Add(time.Duration(seconds)*time.Second)) != ActNone {
			t.Fatal("duplicate interrupted capture")
		}
		if h.PressedAt() != start || !h.Holding() {
			t.Fatal("original press lost")
		}
	}
	act, held := h.Up(1, start.Add(601*time.Second))
	if act != ActFinish || held != 601*time.Second {
		t.Fatal("long capture lost")
	}
}

func TestPendingRecording(t *testing.T) {
	dir := t.TempDir()
	pcm := make([]int16, 60*SampleRate)
	for i := range pcm {
		pcm[i] = int16(i % 100)
	}
	wav := EncodeWAV(pcm)
	id := NewHistoryID(time.Now())
	rec := map[string]any{"outcome": "pending", "audio_seconds": 60}
	if err := SaveHistory(dir, id, wav, rec); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, id[:10], id+".wav")
	got, err := os.ReadFile(filepath.Clean(path))
	if err != nil || string(got) != string(wav) {
		t.Fatal("full audio must exist before transcription")
	}
	rec["outcome"], rec["audio"] = "error", id+".wav"
	if err := SaveHistory(dir, id, nil, rec); err != nil {
		t.Fatal(err)
	}
	got, err = os.ReadFile(filepath.Clean(path))
	if err != nil || string(got) != string(wav) {
		t.Fatal("outcome update changed audio")
	}
}

func TestRecordingEndEvent(t *testing.T) {
	events := filepath.Join(t.TempDir(), "events.jsonl")
	if err := WriteRecordingEnd(events, "application_quit", 60, 61); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Clean(events))
	if err != nil {
		t.Fatal(err)
	}
	var e map[string]any
	if json.Unmarshal(b, &e) != nil || len(e) != 5 || e["outcome"] != "recording_ended" || e["t"] == nil || e["reason"] != "application_quit" || e["audio_seconds"] != float64(60) {
		t.Fatal("event schema")
	}
}

func TestArchiveFailurePreservesPendingAudio(t *testing.T) {
	dir := t.TempDir()
	id := NewHistoryID(time.Now())
	wav := EncodeWAV(make([]int16, 60*SampleRate))
	rec := map[string]any{"outcome": "pending"}
	if err := SaveHistory(dir, id, wav, rec); err != nil {
		t.Fatal(err)
	}
	oldWrite := dayWriteFile
	defer func() { dayWriteFile = oldWrite }()
	dayWriteFile = func(string, []byte, os.FileMode) error { return os.ErrPermission }
	if err := SaveHistory(dir, id, nil, map[string]any{"outcome": "error"}); err == nil {
		t.Fatal("expected failed update")
	}
	got, err := os.ReadFile(filepath.Clean(filepath.Join(dir, id[:10], id+".wav")))
	if err != nil || string(got) != string(wav) {
		t.Fatal("failed update lost audio")
	}
	b, err := os.ReadFile(filepath.Clean(filepath.Join(dir, id[:10], id+".json")))
	if err != nil {
		t.Fatal(err)
	}
	var record map[string]any
	if json.Unmarshal(b, &record) != nil || record["outcome"] != "pending" {
		t.Fatal("pending record lost")
	}
}
