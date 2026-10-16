package core

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

// put writes history/<day>/<name> with size bytes and the given mtime.
func put(t *testing.T, dir, day, name string, size int, mod time.Time) string {
	t.Helper()
	p := filepath.Join(dir, day, name)
	os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, make([]byte, size), 0o644); err != nil {
		t.Fatal(err)
	}
	os.Chtimes(p, mod, mod)
	return p
}

func left(t *testing.T, dir string) []string {
	var out []string
	filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			rel, _ := filepath.Rel(dir, p)
			out = append(out, filepath.ToSlash(rel))
		}
		return nil
	})
	sort.Strings(out)
	return out
}

func TestHistoryKeepDays(t *testing.T) {
	for keep, text := range map[int]int{7: 14, 14: 30, 30: 60, 90: 180, 0: 0, 10: 20} {
		if HistoryTextDays(keep) != text {
			t.Errorf("text days for %d = %d, want %d", keep, HistoryTextDays(keep), text)
		}
	}
	if !strings.Contains(HistoryKeepLabel(14), "既定") || !strings.Contains(HistoryKeepLabel(0), "ずっと") || !strings.Contains(HistoryKeepLabel(7), "14 日") {
		t.Fatal(HistoryKeepLabel(14), HistoryKeepLabel(0), HistoryKeepLabel(7))
	}
	c, _ := ParseConfig([]byte(`{"historyDays":7}`))
	if c.HistoryKeepDays != 14 {
		t.Fatal("default 14; the old historyDays key is not used", c.HistoryKeepDays)
	}
	for in, want := range map[string]int{`{"historyKeepDays":0}`: 0, `{"historyKeepDays":90}`: 90, `{"historyKeepDays":-1}`: 14} {
		if c, _ := ParseConfig([]byte(in)); c.HistoryKeepDays != want {
			t.Errorf("%s: %d", in, c.HistoryKeepDays)
		}
	}
}

func TestHistoryPruneByAge(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 10, 16, 12, 0, 0, 0, time.Local)
	day := func(n int) (string, time.Time) {
		d := now.AddDate(0, 0, -n)
		return d.Format("2006-01-02"), d
	}
	for _, n := range []int{0, 1, 13, 14, 15, 29, 30, 31} {
		d, mod := day(n)
		put(t, dir, d, "a.wav", 100, mod)
		put(t, dir, d, "a.alt.wav", 100, mod)
		put(t, dir, d, "a.json", 10, mod)
	}
	// an old day whose json was just rewritten by the improvement loop
	d40, mod40 := day(40)
	put(t, dir, d40, "b.wav", 100, mod40)
	put(t, dir, d40, "b.json", 10, now.Add(-time.Hour))
	os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("x"), 0o644) // not a day folder: untouched

	r := HistoryPrune(dir, 14, HistoryCapBytes, now)
	got := strings.Join(left(t, dir), " ")
	for _, n := range []int{0, 1, 13, 14} {
		d, _ := day(n)
		if !strings.Contains(got, d+"/a.wav") {
			t.Errorf("recording of day -%d must stay (14 days)", n)
		}
	}
	for _, n := range []int{15, 29} {
		d, _ := day(n)
		if strings.Contains(got, d+"/a.wav") || strings.Contains(got, d+"/a.alt.wav") || !strings.Contains(got, d+"/a.json") {
			t.Errorf("day -%d: recordings removed, json kept (30 days): %s", n, got)
		}
	}
	d31, _ := day(31)
	if strings.Contains(got, d31) {
		t.Errorf("day -31 removed entirely, folder too: %s", got)
	}
	d30, _ := day(30)
	if !strings.Contains(got, d30+"/a.json") {
		t.Error("day -30 json stays")
	}
	if !strings.Contains(got, d40+"/b.json") || strings.Contains(got, d40+"/b.wav") {
		t.Errorf("a file changed within a day is never removed: %s", got)
	}
	if !strings.Contains(got, "notes.txt") {
		t.Error("files outside day folders are untouched")
	}
	if r.Audio != 4*2+1 || r.Text != 1 || r.Dirs != 1 || r.Bytes != 9*100+10 { // days -15 -29 -30 -31 (wav + alt) + b.wav; the json of -31
		t.Errorf("result %+v", r)
	}

	// keep everything
	dir2 := t.TempDir()
	d, mod := day(400)
	put(t, dir2, d, "a.wav", 100, mod)
	if r := HistoryPrune(dir2, 0, 1, now); r.Audio != 0 || len(left(t, dir2)) != 1 || r.SizeAfter != 100 {
		t.Fatalf("0 keeps everything, even over the cap: %+v", r)
	}
}

func TestHistoryPruneCap(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 10, 16, 12, 0, 0, 0, time.Local)
	for n := 5; n >= 0; n-- {
		d := now.AddDate(0, 0, -n)
		mod := d
		if n == 0 {
			mod = now.Add(-time.Minute) // today: protected
		}
		put(t, dir, d.Format("2006-01-02"), "a.wav", 1000, mod)
		put(t, dir, d.Format("2006-01-02"), "a.json", 10, mod)
	}
	// 6060 bytes; cap 3500: remove recordings from the oldest day until it fits
	r := HistoryPrune(dir, 14, 3500, now)
	got := left(t, dir)
	wavs := 0
	for _, f := range got {
		if strings.HasSuffix(f, ".wav") {
			wavs++
		}
	}
	if wavs != 3 || r.Audio != 3 || r.Text != 0 || r.SizeAfter > 3500 {
		t.Fatalf("%+v %v", r, got)
	}
	oldest := now.AddDate(0, 0, -5).Format("2006-01-02")
	if strings.Contains(strings.Join(got, " "), oldest+"/a.wav") || !strings.Contains(strings.Join(got, " "), oldest+"/a.json") {
		t.Fatalf("oldest recording goes first, its json stays: %v", got)
	}
	// a cap that cannot be met: the protected recording of today stays
	r = HistoryPrune(dir, 14, 1, now)
	if !strings.Contains(strings.Join(left(t, dir), " "), now.Format("2006-01-02")+"/a.wav") {
		t.Fatal("today's recording is protected")
	}
	b, files, oldestDay := HistoryUsage(dir)
	if b != r.SizeAfter || files == 0 || oldestDay != oldest {
		t.Fatalf("usage %d %d %s vs %+v", b, files, oldestDay, r)
	}
}
