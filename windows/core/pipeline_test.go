package core

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type seenReq struct{ prompt, actx, inc string }

// fakeWhisper answers /inference with replies in order and records the fields.
func fakeWhisper(t *testing.T, replies ...string) (*httptest.Server, *[]seenReq) {
	var seen []seenReq
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			t.Error(err)
		}
		seen = append(seen, seenReq{r.FormValue("prompt"), r.FormValue("audio_ctx"), r.FormValue("temperature_inc")})
		i := len(seen) - 1
		if i >= len(replies) {
			i = len(replies) - 1
		}
		io.WriteString(w, replies[i])
	}))
	t.Cleanup(srv.Close)
	return srv, &seen
}

func TestTranscribeUtterance(t *testing.T) {
	loop := "スモールを選びながら" + strings.Repeat("ドラフ、", 40)
	good := "スモールを選びながら速さ優先を選んでやってみています。"
	wav := EncodeWAV(make([]int16, 16000*3))
	req := func(url string) UtteranceRequest {
		return UtteranceRequest{BaseURL: url, WAV: wav, Prompt: "用語。", Voiced: 3, Model: DefaultModel, AudioCtx: AudioCtxAuto,
			Entries: []Entry{{Term: "スモール", Aliases: []string{"スモオル"}}}}
	}

	srv, seen := fakeWhisper(t, loop, good)
	res := TranscribeUtterance(context.Background(), req(srv.URL))
	if res.Outcome != OutcomeOK || res.Text != good || !res.RetriedForRepetition || res.RepetitionBeforeRetry != loop || len(res.Passes) != 2 {
		t.Fatalf("loop then good: %+v", res)
	}
	if (*seen)[0] != (seenReq{"用語。", "768", "0.0"}) || (*seen)[1] != (seenReq{"", "0", "0.2"}) {
		t.Fatalf("retry must use audio_ctx=0, temperature_inc=0.2, no prompt: %+v", *seen)
	}

	srv, _ = fakeWhisper(t, loop)
	res = TranscribeUtterance(context.Background(), req(srv.URL))
	if res.Outcome != OutcomeCollapsed || res.Text != "スモールを選びながらドラフ、" || res.RepetitionCollapsed != loop {
		t.Fatalf("still looping: %+v", res)
	}

	srv, seen = fakeWhisper(t, "ご視聴ありがとうございました", "スモオルです")
	res = TranscribeUtterance(context.Background(), req(srv.URL))
	if res.Outcome != OutcomeOK || res.Text != "スモールです" || !res.RetriedWithoutPrompt || res.RetriedForRepetition || (*seen)[1].prompt != "" || (*seen)[1].actx != "768" {
		t.Fatalf("hallucination retry: %+v %+v", res, *seen)
	}

	srv, _ = fakeWhisper(t, "")
	short := req(srv.URL)
	short.Voiced = 0.5
	if res = TranscribeUtterance(context.Background(), short); res.Outcome != OutcomeHallucination || len(res.Passes) != 1 {
		t.Fatalf("short and empty: %+v", res)
	}

	srv, seen = fakeWhisper(t, good)
	turbo := req(srv.URL)
	turbo.Model = "ggml-large-v3-turbo-q5_0.bin"
	if res = TranscribeUtterance(context.Background(), turbo); res.Outcome != OutcomeOK || (*seen)[0].actx != "0" {
		t.Fatalf("turbo must use the whole window: %+v %+v", res, *seen)
	}

	// a stock phrase inside the text (seen on Windows with small-q5_1)
	broken := "今日の作業はここまでにして、残っているテストの収募 (音楽)"
	fixed := "今日の作業はここまでにして、残っているテストの修正とドキュメントの更新は明日やります。"
	srv, seen = fakeWhisper(t, broken, fixed)
	res = TranscribeUtterance(context.Background(), req(srv.URL))
	if res.Outcome != OutcomeOK || res.Text != fixed || !res.RetriedForStock || res.StockBeforeRetry != broken || res.RetriedForRepetition {
		t.Fatalf("stock then good: %+v", res)
	}
	if (*seen)[1] != (seenReq{"", "0", "0.2"}) {
		t.Fatalf("stock retry must use audio_ctx=0, temperature_inc=0.2, no prompt: %+v", *seen)
	}
	srv, _ = fakeWhisper(t, broken, "残っているテストの修正です。ご視聴ありがとうございました。")
	if res = TranscribeUtterance(context.Background(), req(srv.URL)); res.Outcome != OutcomeStripped || res.Text != "残っているテストの修正です。" {
		t.Fatalf("stock left after the retry is removed: %+v", res)
	}
	srv, _ = fakeWhisper(t, broken, "[BLANK_AUDIO]")
	if res = TranscribeUtterance(context.Background(), req(srv.URL)); res.Outcome != OutcomeHallucination {
		t.Fatalf("nothing but a stock phrase after the retry: %+v", res)
	}
	srv, _ = fakeWhisper(t, broken, "テスト"+strings.Repeat("ドラフ、", 10)+"(拍手)")
	if res = TranscribeUtterance(context.Background(), req(srv.URL)); res.Outcome != OutcomeCollapsed || res.Text != "テストドラフ、" {
		t.Fatalf("loop and stock after the retry: %+v", res)
	}

	srv, seen = fakeWhisper(t, good)
	over := req(srv.URL)
	over.AudioCtxFor = func(sec float64, model string) int { return 999 }
	if res = TranscribeUtterance(context.Background(), over); res.Outcome != OutcomeOK || (*seen)[0].actx != "999" {
		t.Fatalf("AudioCtxFor override: %+v %+v", res, *seen)
	}

	res = TranscribeUtterance(context.Background(), req("http://127.0.0.1:1"))
	if res.Outcome != OutcomeError || res.Err == nil {
		t.Fatalf("server down: %+v", res)
	}
}
