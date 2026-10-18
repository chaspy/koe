package main

import (
	"fmt"
	"sync"
	"time"

	"github.com/chaspy/koe/windows/core"
)

// Independent state keeps concurrent utterances from issuing duplicate hints.
type lowLevelWarningState struct {
	mu   sync.Mutex
	last time.Time
}

func (a *App) warnLowLevel(pcm []int16) bool {
	if !a.cfg.LowLevelWarning {
		return false
	}
	level, quiet := core.RecordingLevel(pcm)
	if !quiet {
		return false
	}
	a.lowLevel.mu.Lock()
	defer a.lowLevel.mu.Unlock()
	if !a.lowLevel.last.IsZero() && time.Since(a.lowLevel.last) <= 10*time.Minute {
		return false
	}
	a.lowLevel.last = time.Now()
	a.log.Printf("low_level level_db=%.1f", level)
	a.setError(fmt.Sprintf("声が小さく録れています（%.0f dB）。Windows の設定 → システム → サウンド → 入力で入力音量を上げるか、マイクを口元に近づけてください", level), false)
	return true
}
