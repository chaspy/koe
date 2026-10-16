package core

import (
	"sync"
	"sync/atomic"
	"time"
)

// UsageMaxAge: the usage counts are recomputed in the background once older
// than this (after a paste, or when asked).
const UsageMaxAge = 5 * time.Minute

// UsageCache keeps the "how often was each term pasted recently" counts that
// rank the whisper prompt's terms. Computing them reads up to 600 history
// files, which took about a second after Koe sat idle; so the transcription
// only ever reads the cached counts (Get) and recomputing happens off the
// transcription path (Refresh / RefreshIfStale).
type UsageCache struct {
	// Compute returns fresh counts (reads the history).
	Compute func() map[string]int

	mu      sync.Mutex
	counts  map[string]int
	at      time.Time
	running atomic.Bool
}

// Get returns the cached counts (nil before the first Refresh). It never
// computes.
func (c *UsageCache) Get() map[string]int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.counts
}

// Age is how old the cached counts are (a very large value if none).
func (c *UsageCache) Age(now time.Time) time.Duration {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.counts == nil {
		return 1 << 62
	}
	return now.Sub(c.at)
}

// Refresh recomputes the counts now, unless a refresh is already running.
// It reports whether it computed.
func (c *UsageCache) Refresh() bool {
	if !c.running.CompareAndSwap(false, true) {
		return false
	}
	defer c.running.Store(false)
	u := c.Compute()
	if u == nil {
		u = map[string]int{}
	}
	c.mu.Lock()
	c.counts, c.at = u, time.Now()
	c.mu.Unlock()
	return true
}

// RefreshIfStale starts a background Refresh when the counts are older than
// maxAge (or missing). It reports whether one was started.
func (c *UsageCache) RefreshIfStale(now time.Time, maxAge time.Duration) bool {
	if c.Age(now) < maxAge || c.running.Load() {
		return false
	}
	go c.Refresh()
	return true
}
