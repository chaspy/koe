package core

import (
	"math"
	"testing"
)

func TestRecordingLevel(t *testing.T) {
	for _, tt := range []struct {
		name      string
		amplitude int16
		quiet     bool
	}{
		{"silence", 0, false},
		{"muted", 2, false},
		{"quiet", 100, true},
		{"below threshold", 184, true},
		{"above threshold", 185, false},
		{"normal", 1000, false},
		{"full scale negative", -32768, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			pcm := make([]int16, SampleRate)
			for i := range pcm {
				pcm[i] = tt.amplitude
			}
			level, quiet := RecordingLevel(pcm)
			if quiet != tt.quiet {
				t.Fatalf("level=%f quiet=%v, want %v", level, quiet, tt.quiet)
			}
			want := 0.0
			if Peak(pcm) > MutedPeak {
				want = 20 * math.Log10(math.Abs(float64(tt.amplitude))/32768)
			}
			if math.Abs(level-want) > 1e-9 {
				t.Fatalf("level=%f, want %f", level, want)
			}
		})
	}
	if level, quiet := RecordingLevel(nil); level != 0 || quiet {
		t.Fatalf("empty: %f %v", level, quiet)
	}
}

func TestRecordingLevelUsesAllSamples(t *testing.T) {
	// Alternating polarity, silence, and a partial 30 ms window all contribute.
	pcm := []int16{100, -100, 0, 0, 100}
	level, quiet := RecordingLevel(pcm)
	want := 20 * math.Log10(math.Sqrt(6000)/32768)
	if !quiet || math.Abs(level-want) > 1e-9 {
		t.Fatalf("level=%f quiet=%v, want %f true", level, quiet, want)
	}
}
