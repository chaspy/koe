package core

import "strings"

// MicKind is safe to include in diagnostics; device names and IDs are not.
type MicKind string

const (
	MicUSB     MicKind = "usb"
	MicBuiltIn MicKind = "built_in"
	MicOther   MicKind = "other"
)

type FallbackMic struct {
	ID   uint32
	Name string
	Kind MicKind
}

// ChooseFallbackMic is deterministic and does not mutate its inputs. Names
// match a case-insensitive substring, as waveIn names can be truncated.
// Unavailable includes devices that failed to open or produced digital silence.
func ChooseFallbackMic(devices []FallbackMic, primary uint32, unavailable map[uint32]bool, preferred string) (FallbackMic, bool) {
	preferred = strings.ToLower(strings.TrimSpace(preferred))
	var best FallbackMic
	bestRank := 4
	for _, d := range devices {
		if d.ID == primary || unavailable[d.ID] {
			continue
		}
		rank := 3
		if preferred != "" && strings.Contains(strings.ToLower(d.Name), preferred) {
			rank = 0
		} else if d.Kind == MicUSB {
			rank = 1
		} else if d.Kind == MicBuiltIn {
			rank = 2
		}
		if rank < bestRank {
			best, bestRank = d, rank
		}
	}
	return best, bestRank < 4
}

// MutedInput counts consecutive near-zero samples, independent of callback
// chunk size. Ordinary pauses with microphone noise do not trigger fallback.
type MutedInput struct{ samples int }

func (m *MutedInput) Add(pcm []int16) {
	for _, v := range pcm {
		if int(v) > MutedPeak || int(v) < -MutedPeak {
			m.samples = 0
		} else if m.samples < SampleRate {
			m.samples++
		}
	}
}

func (m MutedInput) Muted() bool { return m.samples >= SampleRate }
