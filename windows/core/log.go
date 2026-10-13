package core

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Logger appends timestamped lines to koe.log (rotates at 5 MB to koe.log.1).
type Logger struct {
	mu   sync.Mutex
	path string
	f    *os.File
}

const maxLogSize = 5 << 20

func NewLogger(path string) *Logger {
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	l := &Logger{path: path}
	l.open()
	return l
}

func (l *Logger) open() {
	if fi, err := os.Stat(l.path); err == nil && fi.Size() > maxLogSize {
		_ = os.Rename(l.path, l.path+".1")
	}
	f, err := os.OpenFile(l.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err == nil {
		l.f = f
	}
}

// Printf writes one line: "2026-10-13 19:32:00.123 <msg>".
func (l *Logger) Printf(format string, args ...any) {
	if l == nil {
		return
	}
	line := time.Now().Format("2006-01-02 15:04:05.000") + " " + fmt.Sprintf(format, args...) + "\r\n"
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f == nil {
		return
	}
	_, _ = l.f.WriteString(line)
	if fi, err := l.f.Stat(); err == nil && fi.Size() > maxLogSize {
		_ = l.f.Close()
		l.f = nil
		l.open()
	}
}

func (l *Logger) Close() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f != nil {
		_ = l.f.Close()
		l.f = nil
	}
}
