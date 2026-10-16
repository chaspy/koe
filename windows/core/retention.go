package core

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// History retention (the same rules as macOS, History.prune in Retention.swift).
//
// historyKeepDays is how long recordings (.wav / .alt.wav) are kept; the
// text and records (.json) are kept about twice as long; 0 keeps everything.
// On top of that, when the history folder is over HistoryCapBytes, the oldest
// recordings are removed until it fits. Files changed within the last
// HistoryProtect are never removed (the improvement loop and evaluation may be
// using them).
const (
	DefaultHistoryKeepDays = 14
	HistoryCapBytes        = 1 << 30
	HistoryProtect         = 24 * time.Hour
	HistoryPruneEvery      = 24 * time.Hour
)

// HistoryKeepChoices are the menu choices (0 = keep everything).
var HistoryKeepChoices = []int{7, 14, 30, 90, 0}

// HistoryTextDays is how long the text and records are kept for keepDays of
// recordings: 7 → 14, 14 → 30, 30 → 60, 90 → 180, other values × 2; 0 = forever.
func HistoryTextDays(keepDays int) int {
	switch {
	case keepDays <= 0:
		return 0
	case keepDays == 14:
		return 30
	}
	return keepDays * 2
}

// HistoryKeepLabel is the menu label of a choice.
func HistoryKeepLabel(keepDays int) string {
	if keepDays <= 0 {
		return "ずっと（消さない）"
	}
	s := strconv.Itoa(keepDays) + " 日（文字は " + strconv.Itoa(HistoryTextDays(keepDays)) + " 日）"
	if keepDays == DefaultHistoryKeepDays {
		s += "（既定）"
	}
	return s
}

// PruneResult is what HistoryPrune removed.
type PruneResult struct {
	Audio, Text, Dirs int   // files / empty day folders removed
	Bytes             int64 // bytes freed
	SizeAfter         int64 // history size afterwards
}

func isAudio(name string) bool { return strings.HasSuffix(name, ".wav") } // .wav and .alt.wav

type histFile struct {
	path string
	day  string // folder name YYYY-MM-DD
	size int64
	mod  time.Time
}

// HistoryPrune applies the retention to dir (history/YYYY-MM-DD/<id>.*).
// Only day folders and the files in them are touched.
func HistoryPrune(dir string, keepDays int, capBytes int64, now time.Time) PruneResult {
	var r PruneResult
	if keepDays <= 0 {
		r.SizeAfter, _, _ = HistoryUsage(dir)
		return r
	}
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	audioCut := today.AddDate(0, 0, -keepDays).Format("2006-01-02")
	textCut := today.AddDate(0, 0, -HistoryTextDays(keepDays)).Format("2006-01-02")
	protect := now.Add(-HistoryProtect)
	files := historyFiles(dir)
	remove := func(f histFile) bool {
		if f.mod.After(protect) {
			return false
		}
		if os.Remove(f.path) != nil {
			return false
		}
		r.Bytes += f.size
		if isAudio(f.path) {
			r.Audio++
		} else {
			r.Text++
		}
		return true
	}
	var left []histFile
	var total int64
	for _, f := range files {
		cut := textCut
		if isAudio(f.path) {
			cut = audioCut
		}
		if f.day < cut && remove(f) {
			continue
		}
		left = append(left, f)
		total += f.size
	}
	// over the cap: oldest recordings first (files are sorted oldest first)
	for _, f := range left {
		if total <= capBytes {
			break
		}
		if isAudio(f.path) && remove(f) {
			total -= f.size
		}
	}
	// empty day folders
	if entries, err := os.ReadDir(dir); err == nil {
		for _, e := range entries {
			if isDayDir(e) && e.Name() < today.Format("2006-01-02") {
				if os.Remove(filepath.Join(dir, e.Name())) == nil { // only succeeds when empty
					r.Dirs++
				}
			}
		}
	}
	r.SizeAfter, _, _ = HistoryUsage(dir)
	return r
}

func isDayDir(e os.DirEntry) bool {
	if !e.IsDir() || len(e.Name()) != 10 {
		return false
	}
	_, err := time.Parse("2006-01-02", e.Name())
	return err == nil
}

// historyFiles lists the files in the day folders, oldest day first, then by name.
func historyFiles(dir string) []histFile {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []histFile
	for _, e := range entries {
		if !isDayDir(e) {
			continue
		}
		fs, _ := os.ReadDir(filepath.Join(dir, e.Name()))
		for _, f := range fs {
			if f.IsDir() {
				continue
			}
			info, err := f.Info()
			if err != nil {
				continue
			}
			out = append(out, histFile{filepath.Join(dir, e.Name(), f.Name()), e.Name(), info.Size(), info.ModTime()})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].day != out[j].day {
			return out[i].day < out[j].day
		}
		return out[i].path < out[j].path
	})
	return out
}

// HistoryUsage is the size of the history folder, its number of files and
// its oldest day folder.
func HistoryUsage(dir string) (bytes int64, files int, oldest string) {
	for _, f := range historyFiles(dir) {
		bytes += f.size
		files++
		if oldest == "" || f.day < oldest {
			oldest = f.day
		}
	}
	return bytes, files, oldest
}
