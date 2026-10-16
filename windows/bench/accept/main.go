// Command accept transcribes bench/accept/audio the way Koe does — silence
// trimming, the whisper prompt with the default term packs, the audio_ctx for
// the utterance and model, autocorrect, and the hallucination / repetition
// retries (core.TranscribeUtterance) — and appends one JSON line per
// utterance to -out. summary.py checks the pass conditions.
//
// -prompts koe,short also runs each utterance with the short prompt (Koe's
// default sentence only, no pack terms) to show what the terms cost.
// -audioctx auto,0 compares Koe's speed-first window with the whole window.
// -quiet keeps transcripts off stdout (for private recordings: the text stays
// only in -out, on the machine). Used by
// .github/workflows/windows-bench.yml (suite: accept).
//
//	go run ./bench/accept -server whisper-server.exe -model models/ggml-small-q5_1.bin -runs 3
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/chaspy/koe/windows/bench/internal/benchutil"
	"github.com/chaspy/koe/windows/core"
)

type pass struct {
	MS         int64  `json:"ms"`
	AudioCtx   int    `json:"audio_ctx"`
	Fallback   bool   `json:"fallback"`
	Text       string `json:"text"`
	Repetitive bool   `json:"repetitive"`
	Stock      bool   `json:"stock"`
}

type result struct {
	Model                string  `json:"model"`
	Threads              int     `json:"threads"`
	ID                   string  `json:"id"`
	Expected             string  `json:"expected"`
	Backend              string  `json:"backend"`           // "gpu" | "cpu"
	GPUFallback          string  `json:"gpu_fallback"`      // why not the GPU build ("" = on a GPU)
	Prompt               string  `json:"prompt"`            // "koe" | "short"
	AudioCtxSetting      string  `json:"audio_ctx_setting"` // "auto" | "0" | frames
	Seconds              float64 `json:"seconds"`           // sent to whisper, after silence trimming
	Run                  int     `json:"run"`
	MS                   int64   `json:"ms"` // all passes
	Outcome              string  `json:"outcome"`
	Text                 string  `json:"text"` // what Koe would paste
	RetriedForRepetition bool    `json:"retried_for_repetition"`
	RetriedWithoutPrompt bool    `json:"retried_without_prompt"`
	RetriedForStock      bool    `json:"retried_for_stock"`
	Passes               []pass  `json:"passes"`
	Error                string  `json:"error,omitempty"`
}

func main() {
	server := flag.String("server", "whisper-server.exe", "whisper-server binary (the CPU build)")
	serverGPU := flag.String("server-gpu", "", "Vulkan build to try first, as Koe does with gpu \"auto\" (falls back to -server)")
	limit := flag.Int("limit", 0, "only the first N sentences (0 = all)")
	model := flag.String("model", "", "model file")
	threads := flag.Int("threads", 0, "whisper threads; 0 = Koe's automatic count")
	runs := flag.Int("runs", 3, "transcriptions per sentence")
	dir := flag.String("dir", "bench/accept", "directory with sentences.tsv and audio/")
	packsDir := flag.String("packs", "../packs", "term packs (Koe ships ../packs)")
	out := flag.String("out", "bench-out/accept.jsonl", "JSON lines output (appended)")
	port := flag.Int("port", 18182, "whisper-server port")
	ctxList := flag.String("audioctx", "auto", "comma-separated window policies: auto | 0 | frames | auto:MIN (auto with another minimum) | full<S (whole window under S seconds, else auto) | full<S+auto:MIN")
	quiet := flag.Bool("quiet", false, "do not print transcripts (numbers only)")
	promptList := flag.String("prompts", "koe", "comma-separated: koe (Koe's prompt with the default packs) | short (the default sentence only)")
	flag.Parse()
	if *model == "" {
		fail("-model is required")
	}
	ids, expected, err := benchutil.Sentences(filepath.Join(*dir, "sentences.tsv"))
	if err != nil {
		fail(err.Error())
	}

	if *limit > 0 && *limit < len(ids) {
		ids = ids[:*limit]
	}
	cfg := core.DefaultConfig()
	cfg.Port = *port
	if *threads <= 0 {
		*threads = cfg.ThreadsFor(runtime.NumCPU())
	}
	// Koe's prompt for a first utterance with no personal glossary
	packs := core.LoadPackEntries(core.ListPacks(*packsDir), cfg.EnabledPacks)
	prompts := map[string]string{
		"koe":   core.BuildWhisperPrompt(cfg.Prompt, core.WhisperTerms(nil, packs, nil, core.WhisperPromptTermLimit), ""),
		"short": core.BuildWhisperPrompt(cfg.Prompt, nil, ""),
	}
	var modes []string
	for _, m := range strings.Split(*promptList, ",") {
		if _, ok := prompts[strings.TrimSpace(m)]; !ok {
			fail("unknown prompt " + m)
		}
		modes = append(modes, strings.TrimSpace(m))
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

	name := filepath.Base(*model)
	// like App.startServer: the Vulkan build first, kept only if it runs on a GPU
	backend, fallback := "cpu", "off"
	var stop func()
	if *serverGPU != "" {
		var probe core.GPUProbe
		s, err := benchutil.StartServerLines(*serverGPU, core.ServerArgs(cfg, *model, *threads), filepath.Join(filepath.Dir(*out), "server-accept-vulkan.log"), probe.Line)
		switch {
		case err != nil:
			fallback = core.FallbackStartFailed + ": " + err.Error()
		case probe.FallbackReason() != "":
			fallback = probe.FallbackReason()
			s()
		default:
			backend, fallback, stop = "gpu", "", s
			fmt.Printf("gpu backend=%s\n", probe.Backend())
		}
		if fallback != "" {
			fmt.Printf("gpu_fallback reason=%s -> cpu\n", fallback)
		}
	}
	if stop == nil {
		s, err := benchutil.StartServer(*server, core.ServerArgs(cfg, *model, *threads), filepath.Join(filepath.Dir(*out), "server-accept.log"))
		if err != nil {
			fail(err.Error())
		}
		stop = s
	}
	defer stop()
	base := core.BaseURL(*port)
	var ctxs []policy
	for _, c := range strings.Split(*ctxList, ",") {
		p, err := parsePolicy(strings.TrimSpace(c))
		if err != nil {
			fail(err.Error())
		}
		ctxs = append(ctxs, p)
	}
	for _, m := range modes {
		fmt.Printf("model=%s threads=%d prompt=%s chars=%d audioctx=%v\n", name, *threads, m, len([]rune(prompts[m])), ctxs)
	}

	type clip struct {
		wav    []byte
		voiced float64
	}
	clips := map[string]clip{}
	for _, id := range ids {
		raw, err := os.ReadFile(filepath.Join(*dir, "audio", id+".wav"))
		if err != nil {
			fail(err.Error())
		}
		trimmed := core.TrimSilence(benchutil.PCM(raw))
		clips[id] = clip{core.EncodeWAV(trimmed), core.Seconds(trimmed)}
	}
	// the first request after start is slower; not measured
	_, _ = core.Transcribe(context.Background(), base, clips[ids[0]].wav, prompts[modes[0]], false, 0)

	// prompts alternate per utterance so a slow patch of the runner hits both
	for run := 1; run <= *runs; run++ {
		for _, id := range ids {
			for _, m := range modes {
				for _, actx := range ctxs {
					c := clips[id]
					res := core.TranscribeUtterance(context.Background(), core.UtteranceRequest{
						BaseURL: base, WAV: c.wav, Prompt: prompts[m], Voiced: c.voiced, Model: name,
						AudioCtx: cfg.AudioCtx, AudioCtxFor: actx.fn, Fallback: cfg.TemperatureFallback, Entries: packs,
					})
					r := result{Model: name, Threads: *threads, ID: id, Expected: expected[id], Backend: backend, GPUFallback: fallback, Prompt: m, AudioCtxSetting: actx.name, Seconds: core.Round2(c.voiced), Run: run,
						MS: res.TotalMS, Outcome: res.Outcome, Text: res.Text,
						RetriedForRepetition: res.RetriedForRepetition, RetriedWithoutPrompt: res.RetriedWithoutPrompt, RetriedForStock: res.RetriedForStock}
					for _, p := range res.Passes {
						r.Passes = append(r.Passes, pass{p.MS, p.AudioCtx, p.Fallback, p.Text, core.IsRepetitive(p.Text), core.HasStockPhrase(p.Text)})
					}
					if res.Err != nil {
						r.Error = res.Err.Error()
					}
					_ = enc.Encode(r)
					shown := r.Text
					if *quiet {
						shown = fmt.Sprintf("(%d chars)", len([]rune(r.Text)))
					}
					fmt.Printf("run=%d %s %s ctx=%s(%d) %.1fs %dms passes=%d outcome=%s %s\n", run, id, m, r.AudioCtxSetting, r.Passes[0].AudioCtx, c.voiced, r.MS, len(r.Passes), r.Outcome, shown)
				}
			}
		}
	}
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "accept:", msg)
	os.Exit(1)
}

// policy is a window policy under test: how the first pass picks audio_ctx.
type policy struct {
	name string
	fn   func(seconds float64, model string) int
}

func (p policy) String() string { return p.name }

// parsePolicy reads auto | 0 | frames | auto:MIN | full<S | full<S+auto:MIN.
// large-v3 models always get the whole window, as in Koe.
func parsePolicy(s string) (policy, error) {
	bad := fmt.Errorf("bad -audioctx %q", s)
	full, min := 0.0, core.MinAudioCtx
	rest := s
	if strings.HasPrefix(rest, "full<") {
		head, tail, _ := strings.Cut(strings.TrimPrefix(rest, "full<"), "+")
		v, err := strconv.ParseFloat(head, 64)
		if err != nil || v <= 0 {
			return policy{}, bad
		}
		full, rest = v, tail
		if rest == "" {
			rest = "auto"
		}
	}
	switch {
	case rest == "auto":
	case strings.HasPrefix(rest, "auto:"):
		v, err := strconv.Atoi(strings.TrimPrefix(rest, "auto:"))
		if err != nil || v <= 0 || v > core.MaxAudioCtx {
			return policy{}, bad
		}
		min = v
	default:
		n, err := strconv.Atoi(rest)
		if err != nil || n < 0 || full > 0 {
			return policy{}, bad
		}
		var c core.AudioCtx
		_ = c.UnmarshalJSON([]byte(rest))
		return policy{s, func(sec float64, model string) int { return c.For(sec, model) }}, nil
	}
	return policy{s, func(sec float64, model string) int {
		if core.FullWindowOnly(model) || sec < full {
			return 0
		}
		return core.AutoAudioCtxMin(sec, min)
	}}, nil
}
