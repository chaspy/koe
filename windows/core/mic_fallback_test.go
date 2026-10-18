package core

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestChooseFallbackMic(t *testing.T) {
	devices := []FallbackMic{{1, "Primary USB", MicUSB}, {2, "Onboard", MicBuiltIn}, {3, "Camera USB", MicUSB}, {4, "Alice's headset", MicOther}, {5, "Second USB", MicUSB}}
	for _, tc := range []struct {
		name, preferred string
		dead            map[uint32]bool
		want            uint32
	}{
		{"USB before onboard", "", nil, 3},
		{"explicit preference", "ALICE", nil, 4},
		{"empty preference", "  ", nil, 3},
		{"missing preference", "missing", nil, 3},
		{"exclude primary even if preferred", "Primary", nil, 3},
		{"silent preference", "Alice", map[uint32]bool{4: true}, 3},
		{"next USB", "", map[uint32]bool{3: true}, 5},
		{"onboard after USB", "", map[uint32]bool{3: true, 5: true}, 2},
		{"other last", "", map[uint32]bool{2: true, 3: true, 5: true}, 4},
		{"all unavailable", "", map[uint32]bool{2: true, 3: true, 4: true, 5: true}, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			before := append([]FallbackMic(nil), devices...)
			deadBefore, _ := json.Marshal(tc.dead)
			d, ok := ChooseFallbackMic(devices, 1, tc.dead, tc.preferred)
			if ok != (tc.want != 0) || d.ID != tc.want {
				t.Fatalf("got %v, %v; want ID %d", d, ok, tc.want)
			}
			deadAfter, _ := json.Marshal(tc.dead)
			if !reflect.DeepEqual(before, devices) || string(deadBefore) != string(deadAfter) {
				t.Fatal("mutated inputs")
			}
		})
	}
	for _, ds := range [][]FallbackMic{nil, devices[:1]} {
		if _, ok := ChooseFallbackMic(ds, 1, nil, ""); ok {
			t.Fatal("no alternate expected")
		}
	}
}

func TestMutedInput(t *testing.T) {
	var m MutedInput
	m.Add(make([]int16, SampleRate-1))
	if m.Muted() {
		t.Fatal("triggered before one second")
	}
	m.Add([]int16{-2})
	if !m.Muted() {
		t.Fatal("threshold sample should count as silence")
	}
	m.Add(nil)
	if !m.Muted() {
		t.Fatal("empty callback changed state")
	}
	m.Add([]int16{-3})
	if m.Muted() {
		t.Fatal("signal should reset silence")
	}
	m.Add(make([]int16, SampleRate-1))
	if m.Muted() {
		t.Fatal("silence must be consecutive")
	}
	m.Add([]int16{2})
	if !m.Muted() {
		t.Fatal("positive threshold should count as silence")
	}
	m.Add([]int16{-32768})
	if m.Muted() {
		t.Fatal("minimum int16 is signal")
	}
	for i := 0; i < 40; i++ {
		m.Add([]int16{0, 0, 3})
	}
	if m.Muted() {
		t.Fatal("ordinary microphone noise is not digital silence")
	}
}

func TestFallbackConfigAndPrivacy(t *testing.T) {
	for _, data := range []string{"", `{}`, `{"warmMic":true}`} {
		cfg, err := ParseConfig([]byte(data))
		if err != nil || cfg.FallbackMic || cfg.FallbackMicName != "" {
			t.Fatalf("fallback must default off: %+v, %v", cfg, err)
		}
	}
	data := []byte(`{"fallbackMic":true,"fallbackMicName":"Alice's headset"}`)
	cfg, err := ParseConfig(data)
	if err != nil || !cfg.FallbackMic || cfg.FallbackMicName != "Alice's headset" {
		t.Fatal("opt-in settings lost")
	}
	lines, err := RedactedConfigLines(data)
	if err != nil || strings.Contains(strings.Join(lines, "\n"), "Alice") {
		t.Fatal("device name leaked into diagnostics")
	}
}
