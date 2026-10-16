// Package benchutil has what the bench commands share: starting
// whisper-server and reading the bench wav files.
package benchutil

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/chaspy/koe/windows/core"
)

// StartServer starts whisper-server with args (its log in logPath) and waits
// until it answers. stop kills it.
func StartServer(bin string, args []string, logPath string) (stop func(), err error) {
	return StartServerLines(bin, args, logPath, nil)
}

// StartServerLines is StartServer that also passes each output line to fn.
func StartServerLines(bin string, args []string, logPath string, fn func(string)) (stop func(), err error) {
	logf, err := os.Create(logPath)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(bin, args...)
	cmd.Stdout, cmd.Stderr = logf, logf
	if fn != nil {
		out := io.MultiWriter(logf, &core.LineFilter{Match: func(string) bool { return true }, Fn: fn})
		cmd.Stdout, cmd.Stderr = out, out
	}
	if err := cmd.Start(); err != nil {
		logf.Close()
		return nil, err
	}
	stop = func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		logf.Close()
	}
	base := core.BaseURL(portOf(args))
	for deadline := time.Now().Add(5 * time.Minute); time.Now().Before(deadline); time.Sleep(500 * time.Millisecond) {
		if core.IsAlive(base) {
			return stop, nil
		}
	}
	stop()
	return nil, fmt.Errorf("whisper-server did not start in 5 minutes (see %s)", logPath)
}

func portOf(args []string) int {
	for i, a := range args {
		if a == "--port" && i+1 < len(args) {
			n, _ := strconv.Atoi(args[i+1])
			return n
		}
	}
	return 0
}

// Sentences reads "id<TAB>text" lines.
func Sentences(path string) (ids []string, text map[string]string, err error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()
	text = map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if id, t, ok := strings.Cut(sc.Text(), "\t"); ok && id != "" {
			ids = append(ids, id)
			text[id] = t
		}
	}
	if len(ids) == 0 {
		return nil, nil, fmt.Errorf("no sentences in %s", path)
	}
	return ids, text, sc.Err()
}

// PCM returns the samples of a 16 kHz mono 16-bit wav.
func PCM(wav []byte) []int16 { return core.WAVSamples(wav) }
