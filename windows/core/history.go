package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// HistoryIDLayout is the id / file name of an utterance (sortable).
const HistoryIDLayout = "2006-01-02T15-04-05.000"

// NewHistoryID formats t as an id ("2026-10-13T19-32-00-123").
func NewHistoryID(t time.Time) string {
	return strings.Replace(t.Format(HistoryIDLayout), ".", "-", 1)
}

func parseHistoryID(id string) (time.Time, bool) {
	if len(id) < 23 {
		return time.Time{}, false
	}
	s := id[:19] + "." + id[20:23]
	t, err := time.ParseInLocation(HistoryIDLayout, s, time.Local)
	return t, err == nil
}

// SaveHistory writes <dir>/<YYYY-MM-DD>/<id>.wav and .json.
func SaveHistory(dir, id string, wav []byte, record map[string]any) error {
	day := filepath.Join(dir, id[:10])
	rec := map[string]any{}
	for k, v := range record {
		rec[k] = v
	}
	rec["id"] = id
	if wav != nil {
		rec["audio"] = id + ".wav"
		if err := writeDayFile(day, id+".wav", wav); err != nil {
			return err
		}
	}
	b, err := json.MarshalIndent(rec, "", "  ")
	if err != nil {
		return err
	}
	return writeDayFile(day, id+".json", b)
}

// Test hooks: beforeDayWrite, if set, runs between creating the day folder
// and writing (tests remove the folder there); dayWriteFile writes the file
// (tests make it fail). Package globals: tests that set them must not run in
// parallel (no t.Parallel).
var (
	beforeDayWrite func(day string)
	dayWriteFile   = os.WriteFile
)

// dayWriteRetryWait is the wait before the second try.
const dayWriteRetryWait = 100 * time.Millisecond

// writeDayFile writes day/name, creating the day folder. If that fails, it
// waits a moment and tries once more, whatever the error: the folder may be
// gone between creating it and writing (an empty old day folder removed by
// HistoryPrune, or by hand), or still be "delete pending" on Windows (another
// process had it open when it was removed: ERROR_ACCESS_DENIED until closed).
func writeDayFile(day, name string, data []byte) error {
	var err error
	for i := 0; i < 2; i++ {
		if i > 0 {
			time.Sleep(dayWriteRetryWait)
		}
		if err = os.MkdirAll(day, 0o750); err != nil {
			continue
		}
		if beforeDayWrite != nil {
			beforeDayWrite(day)
		}
		if err = dayWriteFile(filepath.Join(day, name), data, 0o644); err == nil {
			return nil
		}
	}
	return err
}

// Pasted is one pasted utterance from history.
type Pasted struct {
	Time time.Time
	App  string
	Text string
}

// RecentPasted returns up to n pasted texts from the last 3 day folders (oldest first).
func RecentPasted(dir string, n int) []Pasted {
	entries, _ := os.ReadDir(dir)
	var days []string
	for _, e := range entries {
		if e.IsDir() && len(e.Name()) == 10 {
			days = append(days, e.Name())
		}
	}
	sort.Strings(days)
	if len(days) > 3 {
		days = days[len(days)-3:]
	}
	var files []string
	for _, d := range days {
		fs, _ := filepath.Glob(filepath.Join(dir, d, "*.json"))
		files = append(files, fs...)
	}
	sort.Slice(files, func(i, j int) bool { return filepath.Base(files[i]) < filepath.Base(files[j]) })
	if len(files) > n*2 {
		files = files[len(files)-n*2:]
	}
	var out []Pasted
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var r struct {
			ID     string  `json:"id"`
			App    string  `json:"app"`
			Pasted *string `json:"pasted"`
		}
		if json.Unmarshal(b, &r) != nil || r.Pasted == nil || *r.Pasted == "" {
			continue
		}
		t, ok := parseHistoryID(r.ID)
		if !ok {
			continue
		}
		out = append(out, Pasted{Time: t, App: r.App, Text: *r.Pasted})
	}
	if len(out) > n {
		out = out[len(out)-n:]
	}
	return out
}
