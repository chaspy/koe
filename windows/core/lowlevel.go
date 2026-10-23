package core

/*
#cgo CFLAGS: -I${SRCDIR}/../../macos/Sources/KoeAudioCore/include
#cgo CXXFLAGS: -std=c++20 -I${SRCDIR}/../../macos/Sources/KoeAudioCore/include
#cgo darwin LDFLAGS: -lc++
#cgo linux LDFLAGS: -lstdc++ -lm
#cgo windows LDFLAGS: -static -lstdc++ -lm
#include "koe_audio.h"
*/
import "C"

import "unsafe"

// AudioQuality is measured by the same C API as macOS, including rounding and
// the 0.3-second minimum for a quiet-voice warning. Invalid means no voiced
// window, a short recording, or a C API error; it must not produce a warning.
type AudioQuality struct {
	Valid      bool
	LevelDB    float64
	NoiseDB    float64
	SNRDB      float64
	SpeechS    float64
	ClipRatio  float64
	Brightness float64
	TooQuiet   bool
}

// MeasureAudioQuality takes the entire mono 16 kHz recording, before silence
// trimming, so the core can estimate the background from its quietest windows.
// The C API reads the Go-owned samples synchronously and retains no pointer.
func MeasureAudioQuality(pcm []int16) AudioQuality {
	var samples *C.int16_t
	if len(pcm) > 0 {
		samples = (*C.int16_t)(unsafe.Pointer(&pcm[0]))
	}
	var q C.koe_quality
	if C.koe_measure_i16(samples, C.size_t(len(pcm)), C.int(SampleRate), &q) != C.KOE_OK || q.valid == 0 {
		return AudioQuality{}
	}
	return AudioQuality{
		Valid: true, LevelDB: float64(q.level_db), NoiseDB: float64(q.noise_db),
		SNRDB: float64(q.snr_db), SpeechS: float64(q.speech_s),
		ClipRatio: float64(q.clip_ratio), Brightness: float64(q.brightness),
		TooQuiet: C.koe_too_quiet(&q) != 0,
	}
}

// RecordingLevel is the level-only view of the shared quality measurement.
// Unlike the previous implementation, the input must include background windows.
func RecordingLevel(pcm []int16) (levelDB float64, tooQuiet bool) {
	q := MeasureAudioQuality(pcm)
	return q.LevelDB, q.TooQuiet
}
