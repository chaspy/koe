package core

import "math"

// RecordingLevel measures the RMS of pcm in dBFS and whether it is below -45 dBFS.
// Callers pass the silence-trimmed (voiced) part of a recording, like macOS's
// level_db, so leading and trailing silence does not pull the level down. Empty
// and digitally muted input has no useful level (0, false). Unlike macOS
// AudioQuality, this does not discard windows below RMS 330: that would make
// -45 dB unreachable.
func RecordingLevel(pcm []int16) (levelDB float64, tooQuiet bool) {
	if len(pcm) == 0 || Peak(pcm) <= MutedPeak {
		return 0, false
	}
	var sum float64
	for _, sample := range pcm {
		v := float64(sample)
		sum += v * v
	}
	levelDB = 20 * math.Log10(math.Sqrt(sum/float64(len(pcm)))/32768)
	return levelDB, levelDB < -45
}
