package core

import (
	"fmt"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestUsageCache(t *testing.T) {
	var calls atomic.Int32
	release := make(chan struct{})
	c := &UsageCache{Compute: func() map[string]int {
		calls.Add(1)
		<-release
		return map[string]int{"プルリク": 3}
	}}
	if c.Get() != nil {
		t.Fatal("nothing cached yet")
	}
	now := time.Now()
	if !c.RefreshIfStale(now, UsageMaxAge) {
		t.Fatal("missing counts are stale")
	}
	time.Sleep(20 * time.Millisecond)
	// while computing: Get does not wait, a second refresh is not started
	t0 := time.Now()
	if c.Get() != nil || time.Since(t0) > 10*time.Millisecond {
		t.Fatal("Get must not wait for Compute")
	}
	if c.RefreshIfStale(now, UsageMaxAge) || c.Refresh() {
		t.Fatal("one refresh at a time")
	}
	close(release)
	for i := 0; i < 100 && c.Get() == nil; i++ {
		time.Sleep(5 * time.Millisecond)
	}
	if c.Get()["プルリク"] != 3 || calls.Load() != 1 {
		t.Fatalf("counts %v calls %d", c.Get(), calls.Load())
	}
	if c.RefreshIfStale(time.Now(), UsageMaxAge) {
		t.Fatal("fresh counts are not refreshed")
	}
	if !c.RefreshIfStale(time.Now().Add(UsageMaxAge+time.Second), UsageMaxAge) {
		t.Fatal("old counts are refreshed")
	}
}

// TestUsageCacheRealHistory: with a full history (600 files) the
// transcription path only reads the cache. Logs how long a recompute takes on
// this machine (on Windows this was about a second after idling).
func TestUsageCacheRealHistory(t *testing.T) {
	dir := t.TempDir()
	start := time.Now().Add(-48 * time.Hour)
	for i := 0; i < 600; i++ {
		id := NewHistoryID(start.Add(time.Duration(i) * 4 * time.Minute))
		text := fmt.Sprintf("プルリクを出したのでレビューをお願いします %d", i)
		if err := SaveHistory(dir, id, nil, map[string]any{"pasted": text, "app": "cmd.exe"}); err != nil {
			t.Fatal(err)
		}
	}
	entries := []Entry{{Term: "プルリク"}, {Term: "レビュー"}, {Term: "マージ"}}
	c := &UsageCache{Compute: func() map[string]int {
		var texts []string
		for _, p := range RecentPasted(dir, 300) {
			texts = append(texts, p.Text)
		}
		return UsageCounts(entries, texts)
	}}
	t0 := time.Now()
	c.Refresh()
	compute := time.Since(t0)
	t1 := time.Now()
	for i := 0; i < 1000; i++ {
		c.Get()
	}
	get := time.Since(t1) / 1000
	t.Logf("recompute from 600 history files: %v; cached Get: %v", compute, get)
	if c.Get()["プルリク"] == 0 || c.Get()["マージ"] != 0 {
		t.Fatalf("counts %v", c.Get())
	}
	if get > time.Millisecond {
		t.Fatalf("Get took %v", get)
	}
	if !strings.Contains(fmt.Sprint(c.Get()), "レビュー") {
		t.Fatal("レビュー counted")
	}
}
