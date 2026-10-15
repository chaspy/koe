// Command bench measures whisper-server speed the way Koe calls it: it starts
// whisper-server with Koe's arguments, posts the wav files in audio/ to
// /inference with Koe's fields, and appends one JSON line per request to -out.
// summary.py turns the lines into a table. Used by .github/workflows/windows-bench.yml;
// also runs on macOS / Linux with a local whisper-server.
//
//	go run ./bench -server whisper-server.exe -model models/ggml-small-q5_1.bin -name small-q5_1 -threads 2,4,0 -runs 3
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/chaspy/koe/windows/bench/internal/benchutil"
	"github.com/chaspy/koe/windows/core"
)

type result struct {
	Model      string  `json:"model"`
	Threads    int     `json:"threads"`
	Audio      string  `json:"audio"`
	Seconds    float64 `json:"seconds"`
	CtxMode    string  `json:"ctx_mode"` // "0" | "auto"
	AudioCtx   int     `json:"audio_ctx"`
	Run        int     `json:"run"`
	MS         int64   `json:"ms"`
	Text       string  `json:"text"`
	Repetitive bool    `json:"repetitive"`
	Error      string  `json:"error,omitempty"`
}

func main() {
	server := flag.String("server", "whisper-server.exe", "whisper-server binary")
	model := flag.String("model", "", "model file")
	name := flag.String("name", "", "model label (default: file name)")
	threadList := flag.String("threads", "0", "comma-separated thread counts; 0 = all logical CPUs")
	ctxList := flag.String("ctx", "0,auto", "comma-separated audio_ctx modes: 0 | auto")
	runs := flag.Int("runs", 3, "requests per combination")
	dir := flag.String("dir", "bench", "directory with sentences.tsv and audio/")
	out := flag.String("out", "bench-out/results.jsonl", "JSON lines output (appended)")
	port := flag.Int("port", 18181, "whisper-server port")
	flag.Parse()
	if *model == "" {
		fail("-model is required")
	}
	if *name == "" {
		*name = strings.TrimSuffix(strings.TrimPrefix(filepath.Base(*model), "ggml-"), ".bin")
	}
	ids, _, err := benchutil.Sentences(filepath.Join(*dir, "sentences.tsv"))
	if err != nil {
		fail(err.Error())
	}
	if err := os.MkdirAll(filepath.Dir(*out), 0o755); err != nil {
		fail(err.Error())
	}
	f, err := os.OpenFile(*out, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		fail(err.Error())
	}
	defer f.Close()
	enc := json.NewEncoder(f)

	for _, threads := range threadCounts(*threadList) {
		cfg := core.DefaultConfig()
		cfg.Port = *port
		logPath := filepath.Join(filepath.Dir(*out), fmt.Sprintf("server-%s-t%d.log", *name, threads))
		stop, err := benchutil.StartServer(*server, core.ServerArgs(cfg, *model, threads), logPath)
		if err != nil {
			fail(err.Error())
		}
		base := core.BaseURL(*port)
		// the first request also loads things lazily; not measured
		if wav, err := os.ReadFile(filepath.Join(*dir, "audio", ids[0]+".wav")); err == nil {
			_, _ = core.Transcribe(context.Background(), base, wav, cfg.Prompt, false, 0)
		}
		for _, id := range ids {
			wav, err := os.ReadFile(filepath.Join(*dir, "audio", id+".wav"))
			if err != nil {
				stop()
				fail(err.Error())
			}
			sec := core.Seconds(benchutil.PCM(wav))
			for _, mode := range strings.Split(*ctxList, ",") {
				actx := 0
				if mode == "auto" {
					actx = core.AutoAudioCtx(sec)
				}
				for run := 1; run <= *runs; run++ {
					t0 := time.Now()
					text, err := core.Transcribe(context.Background(), base, wav, cfg.Prompt, false, actx)
					r := result{Model: *name, Threads: threads, Audio: id, Seconds: core.Round2(sec), CtxMode: mode, AudioCtx: actx,
						Run: run, MS: time.Since(t0).Milliseconds(), Text: text, Repetitive: core.IsRepetitive(text)}
					if err != nil {
						r.Error = err.Error()
					}
					_ = enc.Encode(r)
					fmt.Printf("%s t=%d %s ctx=%s(%d) run=%d %dms rep=%v %s %s\n", r.Model, threads, id, mode, actx, run, r.MS, r.Repetitive, r.Error, text)
				}
			}
		}
		stop()
	}
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "bench:", msg)
	os.Exit(1)
}

// threadCounts parses "2,4,0" (0 = all logical CPUs), dropping duplicates.
func threadCounts(list string) []int {
	seen := map[int]bool{}
	var out []int
	for _, s := range strings.Split(list, ",") {
		n, err := strconv.Atoi(strings.TrimSpace(s))
		if err != nil {
			continue
		}
		if n <= 0 {
			n = runtime.NumCPU()
		}
		if !seen[n] {
			seen[n] = true
			out = append(out, n)
		}
	}
	sort.Ints(out)
	return out
}
