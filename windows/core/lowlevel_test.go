package core

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

// These expectations were captured from the old Swift implementation, not C++.
// The macOS test reads this exact file and builds the same integer waveform.
type qualityGolden struct {
	Name              string             `json:"name"`
	BackgroundWindows int                `json:"background_windows"`
	VoiceWindows      int                `json:"voice_windows"`
	Amplitude         int16              `json:"amplitude"`
	Background        int16              `json:"background"`
	TailSamples       int                `json:"tail_samples"`
	Quality           map[string]float64 `json:"quality"`
	TooQuiet          bool               `json:"too_quiet"`
}

func (c qualityGolden) pcm() []int16 {
	var pcm []int16
	for window := 0; window < 2*c.BackgroundWindows+c.VoiceWindows; window++ {
		amplitude := c.Background
		if window >= c.BackgroundWindows && window < c.BackgroundWindows+c.VoiceWindows {
			amplitude = c.Amplitude
		}
		for sample := 0; sample < 480; sample++ {
			value := amplitude
			if sample%2 != 0 {
				value = -value
			}
			pcm = append(pcm, value)
		}
	}
	return append(pcm, make([]int16, c.TailSamples)...)
}

func goldenValues(q AudioQuality) map[string]float64 {
	if !q.Valid {
		return map[string]float64{}
	}
	return map[string]float64{
		"level_db": q.LevelDB, "noise_db": q.NoiseDB, "snr_db": q.SNRDB,
		"speech_s": q.SpeechS, "clip_ratio": q.ClipRatio, "brightness": q.Brightness,
	}
}

func TestAudioQualitySwiftGolden(t *testing.T) {
	var cases []qualityGolden
	data, err := os.ReadFile("../../testdata/audio-quality.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) != 21 {
		t.Fatalf("golden cases: %d", len(cases))
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			pcm := c.pcm()
			q := MeasureAudioQuality(pcm)
			values := goldenValues(q)
			if !reflect.DeepEqual(values, c.Quality) || q.TooQuiet != c.TooQuiet {
				t.Fatalf("quality=%v quiet=%v; want %v quiet=%v", values, q.TooQuiet, c.Quality, c.TooQuiet)
			}
			level, quiet := RecordingLevel(pcm)
			if level != q.LevelDB || quiet != q.TooQuiet {
				t.Fatal("level-only view differs from quality")
			}
		})
	}
}
