package main

import (
	"fmt"
	"time"
)

// warnLowLevel shows the opt-in input-volume hint (lowLevelWarning) for a recording whose
// voiced part measured too quiet, at most once every 10 minutes. process() runs utterances
// one at a time from eventLoop, so a plain timestamp on App is enough. Only the numeric
// level is logged.
func (a *App) warnLowLevel(levelDB float64, tooQuiet bool) bool {
	if !a.cfg.LowLevelWarning || !tooQuiet {
		return false
	}
	if !a.lowLevelAt.IsZero() && time.Since(a.lowLevelAt) <= 10*time.Minute {
		return false
	}
	a.lowLevelAt = time.Now()
	a.log.Printf("low_level level_db=%.1f", levelDB)
	a.setError(fmt.Sprintf("声が小さく録れています（%.0f dB）。Windows の設定 → システム → サウンド → 入力で入力音量を上げるか、マイクを口元に近づけてください", levelDB), false)
	return true
}
