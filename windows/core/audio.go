package core

import (
	"bytes"
	"encoding/binary"
	"math"
)

const (
	SampleRate = 16000
	// PreRollSeconds of audio kept from before the key press (warm mic).
	PreRollSeconds = 0.5
	// TailSeconds of recording kept after the key release (語尾の切れ対策).
	TailSeconds = 0.25
	// VoiceThreshold: RMS of a 30 ms window above this is voice (about -40 dBFS).
	VoiceThreshold = 330.0
	// MutedPeak: peak at or below this means the mic is muted / no input.
	MutedPeak = 2
)

// Peak is the max absolute sample.
func Peak(pcm []int16) int {
	p := 0
	for _, v := range pcm {
		a := int(v)
		if a < 0 {
			a = -a
		}
		if a > p {
			p = a
		}
	}
	return p
}

// TrimSilence cuts leading/trailing silence like the mac version: finds the
// first and last 30 ms window with RMS > VoiceThreshold, keeps 0.25 s before
// and 0.3 s after. Returns nil if no voice.
func TrimSilence(pcm []int16) []int16 {
	win := SampleRate * 30 / 1000
	if len(pcm) <= win {
		return nil
	}
	loud := func(i int) bool {
		end := i + win
		if end > len(pcm) {
			end = len(pcm)
		}
		sum := 0.0
		for j := i; j < end; j++ {
			v := float64(pcm[j])
			sum += v * v
		}
		return math.Sqrt(sum/float64(end-i)) > VoiceThreshold
	}
	first := -1
	for i := 0; i < len(pcm); i += win {
		if loud(i) {
			first = i
			break
		}
	}
	if first < 0 {
		return nil
	}
	last := -1
	for i := len(pcm) - win; i >= 0; i -= win {
		if loud(i) {
			last = i
			break
		}
	}
	if last < 0 {
		return nil
	}
	s := first - SampleRate/4
	if s < 0 {
		s = 0
	}
	e := last + win + SampleRate*3/10
	if e > len(pcm) {
		e = len(pcm)
	}
	return pcm[s:e]
}

// EncodeWAV encodes 16 kHz mono 16-bit PCM as a WAV file.
func EncodeWAV(pcm []int16) []byte {
	var b bytes.Buffer
	dataSize := uint32(len(pcm) * 2)
	w := func(v any) { _ = binary.Write(&b, binary.LittleEndian, v) }
	b.WriteString("RIFF")
	w(36 + dataSize)
	b.WriteString("WAVE")
	b.WriteString("fmt ")
	w(uint32(16))
	w(uint16(1)) // PCM
	w(uint16(1)) // mono
	w(uint32(SampleRate))
	w(uint32(SampleRate * 2))
	w(uint16(2))
	w(uint16(16))
	b.WriteString("data")
	w(dataSize)
	w(pcm)
	return b.Bytes()
}

// BytesToPCM converts little-endian 16-bit bytes to samples.
func BytesToPCM(b []byte) []int16 {
	out := make([]int16, len(b)/2)
	for i := range out {
		out[i] = int16(binary.LittleEndian.Uint16(b[2*i:]))
	}
	return out
}

// Seconds of a PCM buffer.
func Seconds(pcm []int16) float64 { return float64(len(pcm)) / SampleRate }

// Round2 rounds to 2 decimals (for logs / history).
func Round2(x float64) float64 { return math.Round(x*100) / 100 }
