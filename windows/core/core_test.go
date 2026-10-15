package core

import (
	"context"
	"encoding/binary"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func devPack(t *testing.T) []Entry {
	b, err := os.ReadFile("../../packs/developer.txt")
	if err != nil {
		t.Fatal(err)
	}
	return ParseGlossary(string(b))
}

func TestParseGlossary(t *testing.T) {
	es := ParseGlossary("# c\n\nプルリク\tプロリク／プロリック/プロレクト\r\nGitHub\n  マージ\t~マジ／マジ>(され|し)  \n")
	want := []Entry{
		{"プルリク", []string{"プロリク", "プロリック", "プロレクト"}},
		{"GitHub", nil},
		{"マージ", []string{"~マジ", "マジ>(され|し)"}},
	}
	if !reflect.DeepEqual(es, want) {
		t.Fatalf("got %#v", es)
	}
	if got := Sure(want[2].Aliases); !reflect.DeepEqual(got, []string{"マジ>(され|し)"}) {
		t.Fatal(got)
	}
	if got := Ambiguous(want[2].Aliases); !reflect.DeepEqual(got, []string{"マジ"}) {
		t.Fatal(got)
	}
}

func TestAutocorrect(t *testing.T) {
	es := devPack(t)
	cases := []struct{ in, out string }{
		// CONTRIBUTING.md example
		{"プロリクを作ってマジでマージして", "プルリクを作ってマジでマージして"},
		{"マジされた", "マージされた"},
		{"マジで", "マジで"},
		{"ブランチをマジしました", "ブランチをマージしました"},
		{"プロリクエストを出す", "プルリクエストを出す"},
		{"リポジテルを見て", "リポジトリを見て"},
		{"Cloud Codeで", "Claude Codeで"},
		// inside a longer katakana word: not replaced
		{"プロリクルド", "プルリクエスト"},
		{"アプロリク", "アプロリク"},
		{"プロリクス", "プロリクス"},
		{"xCloud Code", "xCloud Code"},
	}
	for _, c := range cases {
		got, _ := Autocorrect(c.in, es)
		if got != c.out {
			t.Errorf("%q: got %q want %q", c.in, got, c.out)
		}
	}
	_, applied := Autocorrect("プロリクとプロリク", es)
	if !reflect.DeepEqual(applied, []string{"プロリク→プルリク"}) {
		t.Fatal(applied)
	}
}

func TestAutocorrectBoundaryKatakana(t *testing.T) {
	es := []Entry{{"WAF", []string{"フォール"}}}
	if got, _ := Autocorrect("フォールバックする", es); got != "フォールバックする" {
		t.Fatal(got)
	}
	if got, _ := Autocorrect("フォールを入れる", es); got != "WAFを入れる" {
		t.Fatal(got)
	}
	if got, _ := Autocorrect("フォールー", es); got != "フォールー" {
		t.Fatal(got)
	}
}

func TestWhisperTermsAndPrompt(t *testing.T) {
	personal := []Entry{{"Herdr", []string{"ハーダー"}}, {"PR", nil}}
	packs := devPack(t)
	counts := UsageCounts(append(personal, packs...), []string{"ハーダーを開く", "GitHubでマージ", "githubを見る"})
	if counts["Herdr"] != 1 || counts["GitHub"] != 2 {
		t.Fatalf("%v", counts)
	}
	terms := WhisperTerms(personal, packs, counts, WhisperPromptTermLimit)
	if terms[0] != "GitHub" || terms[1] != "Herdr" && terms[1] != "マージ" {
		t.Fatalf("%v", terms)
	}
	total := 0
	seen := map[string]bool{}
	for _, x := range terms {
		if seen[x] {
			t.Fatalf("dup %s", x)
		}
		seen[x] = true
		total += runeLen(x) + 1
	}
	if total-1 > WhisperPromptTermLimit {
		t.Fatalf("too long %d", total)
	}
	// unused personal before unused pack terms
	if idx(terms, "PR") < 0 {
		t.Fatalf("PR missing %v", terms)
	}
	p := BuildWhisperPrompt(DefaultPrompt, []string{"A", "B"}, "")
	if p != "A、B。"+DefaultPrompt {
		t.Fatal(p)
	}
	long := strings.Repeat("あ", 200)
	p = BuildWhisperPrompt(DefaultPrompt, nil, long)
	if p != strings.Repeat("あ", 150)+" "+DefaultPrompt {
		t.Fatal(p)
	}
}

func idx(l []string, s string) int {
	for i, x := range l {
		if x == s {
			return i
		}
	}
	return -1
}

func TestReceiverNotes(t *testing.T) {
	personal := []Entry{{"マージ", []string{"マジ>(して)"}}, {"Herdr", []string{"ハーダー", "~ハード"}}}
	short, full := ReceiverNotes(personal, devPack(t), map[string]int{"Herdr": 3}, `~\.claude\koe-voice-glossary.full.md`)
	if !strings.HasPrefix(short, "# 音声入力（Koe）の誤変換メモ\n\n") {
		t.Fatal(short)
	}
	if !strings.Contains(short, "## よく起きる誤変換（正しい表記 ← 化けた形）\n\n- Herdr ← ハーダー（文脈によっては「ハード」と化ける）\n") {
		t.Fatal(short)
	}
	if !strings.Contains(short, "- マージ ← マジ（直後が (して) のとき）、マジ（直後が (され|し|する|した|でき|済) のとき）（文脈によっては「マジ」と化ける）") {
		t.Fatal(short)
	}
	if !strings.Contains(short, "`~\\.claude\\koe-voice-glossary.full.md` を grep してから読み替える（6 語）") {
		t.Fatal(short)
	}
	if !strings.Contains(full, "## よく使う語（この表記が正しい）\n\nPR、コンフリクト") {
		t.Fatal(full)
	}
}

func TestListPacks(t *testing.T) {
	d1, d2 := t.TempDir(), t.TempDir()
	os.WriteFile(filepath.Join(d1, "developer.txt"), []byte("# Koe 用語パック: 開発者\nGitHub\n"), 0o644)
	os.WriteFile(filepath.Join(d2, "developer.txt"), []byte("Other\n"), 0o644)
	os.WriteFile(filepath.Join(d2, "company.txt"), []byte("会議室\tかいぎしつ\n"), 0o644)
	ps := ListPacks(d1, d2)
	if len(ps) != 2 || ps[0].Title != "開発者" || ps[1].ID != "company" {
		t.Fatalf("%+v", ps)
	}
	es := LoadPackEntries(ps, []string{"developer"})
	if len(es) != 1 || es[0].Term != "GitHub" {
		t.Fatalf("%+v", es)
	}
}

func TestTrimSilenceAndWAV(t *testing.T) {
	pcm := make([]int16, SampleRate*3)
	for i := SampleRate; i < SampleRate*2; i++ {
		pcm[i] = int16(3000 * ((i/8)%2*2 - 1))
	}
	tr := TrimSilence(pcm)
	sec := Seconds(tr)
	if sec < 1.5 || sec > 1.6 {
		t.Fatalf("trimmed %.3f s", sec)
	}
	if TrimSilence(make([]int16, SampleRate)) != nil {
		t.Fatal("silence should be nil")
	}
	if Peak(pcm) != 3000 || Peak([]int16{-32768}) != 32768 {
		t.Fatal("peak")
	}
	w := EncodeWAV([]int16{1, -2, 3})
	if len(w) != 44+6 || string(w[:4]) != "RIFF" || string(w[8:12]) != "WAVE" || string(w[36:40]) != "data" {
		t.Fatal("header")
	}
	if binary.LittleEndian.Uint32(w[24:]) != 16000 || binary.LittleEndian.Uint16(w[22:]) != 1 || binary.LittleEndian.Uint32(w[40:]) != 6 {
		t.Fatal("fmt")
	}
	if !reflect.DeepEqual(BytesToPCM(w[44:]), []int16{1, -2, 3}) {
		t.Fatal("roundtrip")
	}
}

func TestRepeats(t *testing.T) {
	r := "了解しました。了解しました。了解しました。"
	if !IsRepetitive(r) || IsRepetitive("了解しました。了解しました。") {
		t.Fatal("repetitive")
	}
	if got := CollapseRepeats(r); got != "了解しました。" {
		t.Fatal(got)
	}
	// shapes whisper actually produced (small, audio_ctx=384, no temperature fallback)
	kinyou := "来週のリリースに向けて、残っている課題を洗い出して、半島と起源を決めてから、" + strings.Repeat("金曜日間、", 31)
	loops := map[string]string{
		strings.Repeat("ドラフ、", 60) + "ドラフ":          "ドラフ",
		"えっと、" + strings.Repeat("ドラフ、", 8) + "ドラフ。": "えっと、ドラフ。",
		kinyou: "来週のリリースに向けて、残っている課題を洗い出して、半島と起源を決めてから、金曜日間、",
		"それは" + strings.Repeat("ミティ", 12) + "です":  "それはミティです",
		strings.Repeat("ドラフ ", 5):                 "ドラフ",
		"了解しました。了解しました。了解しました。":                   "了解しました。",
		"スモールを選びながら" + strings.Repeat("ドラフ、", 40): "スモールを選びながらドラフ、",
	}
	for in, want := range loops {
		if !IsRepetitive(in) {
			t.Errorf("not detected: %q", in)
		}
		if got := CollapseRepeats(in); got != want {
			t.Errorf("CollapseRepeats(%q) = %q, want %q", in, got, want)
		}
	}
	for _, ok := range []string{
		"はい、はい、わかりました。",
		"テスト、テスト、マイクのテストです。",
		"ミーティング、ミーティング、ミーティングの予定を入れてください。",
		"はい、はい、はい、はい、了解です。",
		"了解しました。了解しました。",
		"ははは、それは面白いですね。",
		"予算は1000000000000円です。",
		"ドラフト、ドラフト版のレビュー、それからマージ",
		"",
	} {
		if IsRepetitive(ok) {
			t.Errorf("false positive: %q", ok)
		}
		if got := CollapseRepeats(ok); got != strings.TrimSpace(ok) {
			t.Errorf("CollapseRepeats changed %q to %q", ok, got)
		}
	}
	stock := map[string]string{
		"今日の作業はここまでにして、残っているテストの収募 (音楽)": "今日の作業はここまでにして、残っているテストの収募",
		"了解です。ご視聴ありがとうございました。":           "了解です。",
		"[BLANK_AUDIO] テストです [音楽]":       "テストです",
		"（拍手）ありがとうございます":                 "ありがとうございます",
	}
	for in, want := range stock {
		if !HasStockPhrase(in) || RemoveStockPhrases(in) != want {
			t.Errorf("stock %q: has=%v removed=%q", in, HasStockPhrase(in), RemoveStockPhrases(in))
		}
	}
	for _, ok := range []string{"ありがとうございました、助かります。", "音楽をかけてください。", "拍手が起きました。", "BLANK のままでいいです"} {
		if HasStockPhrase(ok) {
			t.Errorf("not a stock phrase: %q", ok)
		}
	}
	if CleanServerText(" a \n\n b\r\n") != "a b" {
		t.Fatal("clean")
	}
	if !Hallucinations["ご視聴ありがとうございました"] {
		t.Fatal("hallucinations")
	}
}

func TestTerminal(t *testing.T) {
	apps := DefaultEnterApps
	for _, p := range []string{`C:\Program Files\WindowsApps\Microsoft.WindowsTerminal_1.2\WindowsTerminal.exe`, `C:\Windows\System32\cmd.exe`, "PWSH.EXE", "wezterm-gui.exe"} {
		if !IsTerminal(p, apps) {
			t.Error(p)
		}
	}
	for _, p := range []string{`C:\Program Files\Slack\slack.exe`, "Teams.exe", "", "chrome.exe"} {
		if IsTerminal(p, apps) {
			t.Error(p)
		}
	}
}

func TestConfig(t *testing.T) {
	c, err := ParseConfig([]byte(`{"hotkey":"RCtrl","enabledPacks":[],"port":0}`))
	if err != nil || c.Hotkey != "rctrl" || len(c.EnabledPacks) != 0 || c.Port != 18080 || !c.AutoEnter || c.MinHoldSeconds != 0.3 {
		t.Fatalf("%+v %v", c, err)
	}
	c, _ = ParseConfig([]byte(`{"hotkey":"x","autoEnter":false}`))
	if c.Hotkey != "ralt" || c.AutoEnter || c.Model != DefaultModel || c.EnabledPacks[0] != "developer" {
		t.Fatalf("%+v", c)
	}
	if c.ModelPath(`C:\m`) != filepath.Join(`C:\m`, DefaultModel) || !strings.HasSuffix(c.ModelDownloadURL(), "/ggml-small-q5_1.bin") {
		t.Fatal(c.ModelPath(`C:\m`), c.ModelDownloadURL())
	}
	c.Model = `D:\models\x.bin`
	if c.ModelPath(`C:\m`) != `D:\models\x.bin` {
		t.Fatal(c.ModelPath(`C:\m`))
	}
	p := filepath.Join(t.TempDir(), "k", "config.json")
	c, err = LoadConfig(p)
	if err != nil || c.Hotkey != "ralt" {
		t.Fatal(err)
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatal("default config not written")
	}
}

func TestHoldTracker(t *testing.T) {
	const ralt = 0xA5
	h := HoldTracker{HotkeyVK: ralt, MinHold: 300 * time.Millisecond}
	t0 := time.Now()
	if h.Down(ralt, t0) != ActStart || h.Down(ralt, t0.Add(50*time.Millisecond)) != ActNone {
		t.Fatal("start/repeat")
	}
	if a, _ := h.Up(ralt, t0.Add(200*time.Millisecond)); a != ActShort {
		t.Fatal("short", a)
	}
	h.Down(ralt, t0)
	if a, d := h.Up(ralt, t0.Add(time.Second)); a != ActFinish || d != time.Second {
		t.Fatal("finish", a)
	}
	h.Down(ralt, t0)
	if h.Down(0x56, t0) != ActCancel || h.Down(0x57, t0) != ActNone {
		t.Fatal("cancel")
	}
	if a, _ := h.Up(ralt, t0.Add(time.Second)); a != ActNone {
		t.Fatal("after cancel", a)
	}
	if h.Down(0x56, t0) != ActNone {
		t.Fatal("other key while idle")
	}
	if a, _ := h.Up(0x56, t0); a != ActNone {
		t.Fatal("other up")
	}
}

func TestTranscribe(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/inference" {
			w.WriteHeader(404)
			return
		}
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			t.Error(err)
		}
		if r.FormValue("response_format") != "text" || r.FormValue("prompt") != "プロンプト" || r.FormValue("temperature") != "0.0" || r.FormValue("temperature_inc") != "0.0" || r.FormValue("audio_ctx") != "384" {
			t.Error("fields", r.Form)
		}
		f, fh, err := r.FormFile("file")
		if err != nil || fh.Filename != "audio.wav" {
			t.Error(err)
		} else {
			b, _ := io.ReadAll(f)
			if string(b[:4]) != "RIFF" {
				t.Error("wav")
			}
		}
		io.WriteString(w, " こんにちは。\n\n 元気？\n")
	}))
	defer srv.Close()
	if !IsAlive(srv.URL) || IsAlive("http://127.0.0.1:1") {
		t.Fatal("alive")
	}
	got, err := Transcribe(context.Background(), srv.URL, EncodeWAV(make([]int16, 100)), "プロンプト", false, 384)
	if err != nil || got != "こんにちは。 元気？" {
		t.Fatal(got, err)
	}
	args := ServerArgs(DefaultConfig(), `C:\m.bin`, 4)
	if strings.Join(args, " ") != `-m C:\m.bin -l ja --host 127.0.0.1 --port 18080 -t 4 -bs 1 -bo 1 -fa --prompt `+DefaultPrompt {
		t.Fatal(args)
	}
	if AutoThreads(0) != 1 || AutoThreads(2) != 2 || AutoThreads(12) != 12 || AutoThreads(64) != 16 {
		t.Fatal("threads")
	}
	c := DefaultConfig()
	if c.ThreadsFor(8) != 8 {
		t.Fatal("auto threads")
	}
	c.Threads = 6
	if c.ThreadsFor(32) != 6 {
		t.Fatal("configured threads")
	}
	body, _, _ := BuildInferenceBody(nil, "", true, 0)
	if !strings.Contains(string(body), "name=\"temperature_inc\"\r\n\r\n0.2\r\n") {
		t.Fatal("fallback on must send temperature_inc=0.2")
	}
	if !strings.Contains(string(body), "name=\"audio_ctx\"\r\n\r\n0\r\n") {
		t.Fatal("audio_ctx=0 must be sent")
	}
}

func TestDownloadResume(t *testing.T) {
	data := []byte(strings.Repeat("0123456789", 1000))
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "m.bin", time.Now(), strings.NewReader(string(data)))
	}))
	defer srv.Close()
	dest := filepath.Join(t.TempDir(), "models", "m.bin")
	os.MkdirAll(filepath.Dir(dest), 0o755)
	os.WriteFile(dest+".part", data[:3000], 0o644)
	var last int64
	if err := Download(context.Background(), srv.URL, dest, func(d, tot int64) { last = d }); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(dest)
	if string(b) != string(data) || last != int64(len(data)) {
		t.Fatal("content", len(b), last)
	}
}

func TestHistory(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 10, 13, 19, 32, 0, 123e6, time.Local)
	id := NewHistoryID(now)
	if id != "2026-10-13T19-32-00-123" {
		t.Fatal(id)
	}
	if err := SaveHistory(dir, id, EncodeWAV([]int16{1}), map[string]any{"pasted": "こんにちは", "app": "cmd.exe"}); err != nil {
		t.Fatal(err)
	}
	SaveHistory(dir, NewHistoryID(now.Add(time.Second)), nil, map[string]any{"pasted": nil})
	old := NewHistoryID(now.AddDate(0, 0, -7))
	SaveHistory(dir, old, nil, map[string]any{"pasted": "古い"})
	if rp := RecentPasted(dir, 5); len(rp) != 2 || rp[0].Text != "古い" {
		t.Fatalf("%+v", rp)
	}
	removed := PruneHistory(dir, 7, now)
	if !reflect.DeepEqual(removed, []string{"2026-10-06"}) {
		t.Fatal(removed)
	}
	rp := RecentPasted(dir, 5)
	if len(rp) != 1 || rp[0].Text != "こんにちは" || rp[0].App != "cmd.exe" || !rp[0].Time.Equal(now) {
		t.Fatalf("%+v", rp)
	}
	if _, err := os.Stat(filepath.Join(dir, "2026-10-13", id+".wav")); err != nil {
		t.Fatal(err)
	}
}

func TestPackSync(t *testing.T) {
	g, ok := ParseGhSource("gh:example/glossary/voice/company.txt")
	if !ok || g.Path != "voice/company.txt" {
		t.Fatal(g)
	}
	if strings.Join(g.GhArgs(), " ") != "api repos/example/glossary/contents/voice/company.txt -H Accept: application/vnd.github.raw" {
		t.Fatal(g.GhArgs())
	}
	if _, ok := ParseGhSource("gh:a/b"); ok {
		t.Fatal("short")
	}
	dir := t.TempDir()
	var logs []string
	logf := func(f string, a ...any) { logs = append(logs, f) }
	calls := 0
	run := func(args []string) ([]byte, error) {
		calls++
		if strings.Contains(args[1], "bad") {
			return []byte(`{"message":"Not Found"}`), nil
		}
		return []byte("議事録\tぎじろく\n"), nil
	}
	srcs := []string{"gh:o/r/voice/company.txt", "gh:o/r/bad.txt", "https://x/y.txt"}
	SyncPackSources(srcs, dir, time.Now(), run, logf)
	if calls != 2 {
		t.Fatal(calls)
	}
	if _, err := os.Stat(filepath.Join(dir, "company.txt")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "bad.txt")); err == nil {
		t.Fatal("bad written")
	}
	SyncPackSources(srcs[:1], dir, time.Now(), run, logf)
	if calls != 2 {
		t.Fatal("should skip within a day")
	}
}

func TestIcon(t *testing.T) {
	ic := MakeIcon(255, 0, 0, true)
	if binary.LittleEndian.Uint16(ic[2:]) != 1 || binary.LittleEndian.Uint32(ic[14:]) != uint32(len(ic)-22) {
		t.Fatal("ico header")
	}
}

func TestLogger(t *testing.T) {
	p := filepath.Join(t.TempDir(), "Koe", "koe.log")
	l := NewLogger(p)
	l.Printf("key_down vk=0x%X", 0xA5)
	l.Close()
	b, _ := os.ReadFile(p)
	if !strings.Contains(string(b), "key_down vk=0xA5\r\n") {
		t.Fatal(string(b))
	}
}
