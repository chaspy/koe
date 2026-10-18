package core

import (
	"context"
	"strings"
	"time"
)

// UtteranceRequest is one utterance to transcribe the way Koe does.
type UtteranceRequest struct {
	BaseURL string
	// Recognizer, if set, transcribes instead of the whisper-server at
	// BaseURL (Parakeet-ja; fixed answers in tests).
	Recognizer Recognizer
	// SingleShot: the recognizer ignores the prompt, the window and the
	// fallback, so a retry would give the same text and none is made
	// (Parakeet-ja). Repeats are still collapsed and stock phrases removed.
	SingleShot bool
	WAV        []byte
	Prompt     string
	Voiced     float64 // seconds of audio in WAV
	Model      string  // file name / path (large-v3 always uses the whole window)
	AudioCtx   AudioCtx
	Fallback   bool    // config temperatureFallback
	Entries    []Entry // glossary + packs, for Autocorrect
	// AudioCtxFor, if set, replaces AudioCtx.For for the first pass
	// (experiments with other window policies; Koe leaves it nil).
	AudioCtxFor func(seconds float64, model string) int
	// OnPass, if set, is called after each request (for logging).
	OnPass func(attempt int, p Pass)
}

// Pass is one request of an utterance.
type Pass struct {
	MS       int64
	AudioCtx int
	Fallback bool
	Prompt   string
	Raw      string   // the recognizer's text (trimmed)
	Text     string   // after Autocorrect
	Applied  []string // corrections
	Synced   bool     // a term from a synced pack was put in
	Err      error
}

// Outcomes of TranscribeUtterance.
const (
	OutcomeOK            = "ok"
	OutcomeCollapsed     = "collapsed"     // still repetitive after the retry; repeats pasted once
	OutcomeStripped      = "stripped"      // a stock phrase remained after the retry and was removed
	OutcomeHallucination = "hallucination" // nothing usable
	OutcomeError         = "error"
)

// UtteranceResult is what Koe pastes and how it got there.
type UtteranceResult struct {
	Text                  string
	Outcome               string
	Passes                []Pass
	TotalMS               int64
	RetriedWithoutPrompt  bool
	RetriedForRepetition  bool
	RepetitionBeforeRetry string
	RepetitionCollapsed   string
	RetriedForStock       bool   // a stock phrase such as (音楽) was inside the text
	StockBeforeRetry      string // the text that had it
	StockRemoved          string // the retry's text before the stock phrase was removed
	SyncedReplaced        bool   // the text has a term from a synced pack (no automatic Enter)
	Err                   error
}

// TranscribeUtterance runs Koe's transcription: whisper with the audio_ctx
// for the utterance and model, then Autocorrect. An empty or stock-phrase
// result with 1 s+ of voice is retried once without the prompt. A looping
// result, or one with a stock phrase such as (音楽) inside, is retried once
// over the whole window (audio_ctx=0) with the temperature fallback and
// without the prompt; if it still loops, each repeat is collapsed to one, and
// a remaining stock phrase is removed.
func TranscribeUtterance(ctx context.Context, r UtteranceRequest) UtteranceResult {
	var res UtteranceResult
	prompt := r.Prompt
	actx := r.AudioCtx.For(r.Voiced, r.Model)
	if r.AudioCtxFor != nil {
		actx = r.AudioCtxFor(r.Voiced, r.Model)
	}
	fallback := r.Fallback
	asr := r.Recognizer
	if asr == nil {
		asr = WhisperHTTP{BaseURL: r.BaseURL}
	}
	for attempt := 0; attempt < 2; attempt++ {
		retry := attempt == 0 && !r.SingleShot
		t0 := time.Now()
		raw, err := asr.Recognize(ctx, r.WAV, prompt, fallback, actx)
		p := Pass{MS: time.Since(t0).Milliseconds(), AudioCtx: actx, Fallback: fallback, Prompt: prompt, Err: err}
		res.TotalMS += p.MS
		if err == nil {
			p.Raw = strings.TrimSpace(raw)
			p.Text, p.Applied, p.Synced = AutocorrectSynced(p.Raw, r.Entries)
			res.SyncedReplaced = p.Synced // the last pass is the one whose text is used
		}
		res.Passes = append(res.Passes, p)
		if r.OnPass != nil {
			r.OnPass(attempt, p)
		}
		if err != nil {
			res.Outcome, res.Err = OutcomeError, err
			return res
		}
		t := p.Text
		if t == "" || Hallucinations[t] {
			if retry && r.Voiced >= 1.0 {
				res.RetriedWithoutPrompt = true
				prompt = ""
				continue
			}
			res.Outcome = OutcomeHallucination
			return res
		}
		loop, stock := IsRepetitive(t), HasStockPhrase(t)
		if (loop || stock) && retry {
			if loop {
				res.RetriedForRepetition, res.RepetitionBeforeRetry = true, t
			}
			if stock {
				res.RetriedForStock, res.StockBeforeRetry = true, t
			}
			if prompt != "" {
				res.RetriedWithoutPrompt = true
			}
			prompt, actx, fallback = "", 0, true
			continue
		}
		res.Text, res.Outcome = t, OutcomeOK
		if loop {
			res.RepetitionCollapsed = t
			res.Text, res.Outcome = CollapseRepeats(t), OutcomeCollapsed
		}
		if stock {
			res.StockRemoved = res.Text
			res.Text = RemoveStockPhrases(res.Text)
			if res.Outcome == OutcomeOK {
				res.Outcome = OutcomeStripped
			}
			if res.Text == "" {
				res.Outcome = OutcomeHallucination
			}
		}
		return res
	}
	res.Outcome = OutcomeHallucination
	return res
}
