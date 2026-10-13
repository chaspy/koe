//go:build windows

// Koe for Windows: hold Right Alt to record, release to transcribe with a
// local whisper-server and paste. See README-windows.md.
package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/chaspy/koe/windows/core"
	"github.com/getlantern/systray"
	"golang.org/x/sys/windows"
)

// set by build.sh: -X main.version=<CFBundleShortVersionString> -X main.rev=<git short hash>
var (
	version = "dev"
	rev     = ""
)

type pastedText struct {
	at   time.Time
	text string
}

type utterance struct {
	pressedAt  time.Time
	releasedAt time.Time
	app        string // exe name of the foreground app at press time
	held       time.Duration
	pcm        []int16
	record     map[string]any
}

type App struct {
	cfg      core.Config
	log      *core.Logger
	exeDir   string
	roamDir  string // %APPDATA%\Koe
	localDir string // %LOCALAPPDATA%\Koe

	rec    *Recorder
	server *WhisperServer
	hold   core.HoldTracker
	hookID uint32

	ready      atomic.Bool
	holding    atomic.Bool
	hotkeyVK   atomic.Uint32 // current push-to-talk key; the event loop picks up changes
	hotkeyName atomic.Value  // string "ralt" | "rctrl"
	updating   atomic.Bool
	tail       sync.WaitGroup
	queue      chan *utterance
	cur        *utterance // event loop only
	recording  atomic.Bool
	processing atomic.Int32

	mu        sync.Mutex
	errMsg    string
	errUntil  time.Time
	download  float64 // <0 = not downloading
	recent    []string
	prevByApp map[string]pastedText
	usage     map[string]int
	usageAt   time.Time
	avail     *core.Release // newer release, if any
	updateMsg string        // update progress shown as the status

	tray trayItems
}

func (a *App) configPath() string   { return filepath.Join(a.roamDir, "config.json") }
func (a *App) glossaryPath() string { return filepath.Join(a.roamDir, "glossary.txt") }
func (a *App) userPacksDir() string { return filepath.Join(a.roamDir, "packs") }
func (a *App) modelsDir() string    { return filepath.Join(a.localDir, "models") }
func (a *App) historyDir() string   { return filepath.Join(a.localDir, "history") }

func main() {
	runtime.LockOSThread() // systray's message loop runs on this thread
	name, _ := windows.UTF16PtrFromString(`Local\Koe-voice-input-single-instance`)
	if _, err := windows.CreateMutex(nil, false, name); err == windows.ERROR_ALREADY_EXISTS {
		messageBox("Koe", "Koe はすでに起動しています（タスクバー右下の通知領域にアイコンがあります）。", 0x40)
		return
	}
	a := &App{download: -1, prevByApp: map[string]pastedText{}, queue: make(chan *utterance, 16)}
	exe, _ := os.Executable()
	a.exeDir = filepath.Dir(exe)
	a.roamDir = filepath.Join(os.Getenv("APPDATA"), "Koe")
	a.localDir = filepath.Join(os.Getenv("LOCALAPPDATA"), "Koe")
	_ = os.MkdirAll(a.roamDir, 0o755)
	_ = os.MkdirAll(a.localDir, 0o755)
	a.log = core.NewLogger(filepath.Join(a.localDir, "koe.log"))
	defer func() {
		if r := recover(); r != nil {
			a.log.Printf("PANIC %v", r)
			messageBox("Koe", fmt.Sprintf("Koe が異常終了しました: %v\nログ: %s", r, filepath.Join(a.localDir, "koe.log")), 0x10)
		}
	}()
	systray.Run(a.onReady, a.onExit)
}

func messageBox(title, text string, flags uint32) {
	t, _ := windows.UTF16PtrFromString(text)
	c, _ := windows.UTF16PtrFromString(title)
	windows.MessageBox(0, t, c, flags)
}

func (a *App) onReady() {
	a.setupTray()
	go a.startup()
}

func (a *App) onExit() {
	a.log.Printf("exit")
	stopKeyboardHook(a.hookID)
	if a.server != nil {
		a.server.Stop()
	}
	if a.rec != nil {
		a.rec.Close()
	}
	a.log.Close()
}

func (a *App) startup() {
	defer a.recoverLog("startup")
	_, statErr := os.Stat(a.configPath())
	firstRun := os.IsNotExist(statErr)
	cfg, err := core.LoadConfig(a.configPath())
	if err != nil {
		a.log.Printf("config_error %v (using defaults where invalid)", err)
	}
	a.cfg = cfg
	v := windows.RtlGetVersion()
	a.setHotkey(cfg.Hotkey)
	a.renderHotkey()
	a.log.Printf("start Koe %s rev=%s windows=%d.%d.%d cpus=%d exe=%s", version, rev, v.MajorVersion, v.MinorVersion, v.BuildNumber, runtime.NumCPU(), a.exeDir)
	a.log.Printf("config hotkey=%s model=%s packs=%v packSources=%v autoEnter=%v enterDelayMs=%d warmMic=%v minHold=%.2f",
		cfg.Hotkey, cfg.Model, cfg.EnabledPacks, cfg.PackSources, cfg.AutoEnter, cfg.EnterDelayMs, cfg.WarmMic, cfg.MinHoldSeconds)
	a.log.Printf("input_devices %q", inputDevices())

	if _, err := os.Stat(a.glossaryPath()); os.IsNotExist(err) {
		_ = os.WriteFile(a.glossaryPath(), []byte("# Koe 個人の辞書\r\n# 1 行 1 語。タブの後に、実際に起きた誤変換の形を ／ 区切りで書く（例: プルリク<TAB>プロリク／プロリック）\r\n"), 0o644)
	}
	_ = os.MkdirAll(a.userPacksDir(), 0o755)
	if removed := core.PruneHistory(a.historyDir(), cfg.HistoryDays, time.Now()); len(removed) > 0 {
		a.log.Printf("history_pruned %v", removed)
	}
	for _, p := range core.RecentPasted(a.historyDir(), 5) {
		a.recent = append(a.recent, p.Text)
	}

	vk := a.hotkeyVK.Load()
	a.hold = core.HoldTracker{HotkeyVK: vk, MinHold: time.Duration(cfg.MinHoldSeconds * float64(time.Second))}
	a.rec = NewRecorder(cfg.WarmMic, a.log.Printf)
	a.rec.Warm()

	keys := make(chan keyEvent, 256)
	tid, err := startKeyboardHook(keys)
	if err != nil {
		a.log.Printf("hook_failed %v", err)
		a.setError("キーボードフックを設定できませんでした: "+err.Error(), true)
		go messageBox("Koe", "キーボードフックを設定できませんでした: "+err.Error(), 0x10)
		return
	}
	a.hookID = tid
	a.log.Printf("hook_installed thread=%d hotkey_vk=0x%X", tid, vk)
	go a.eventLoop(keys)
	go a.worker()

	a.exportReceivers()
	go func() {
		defer a.recoverLog("pack_sync")
		a.syncPacks()
		a.exportReceivers()
	}()
	if firstRun {
		go messageBox("Koe", "Koe を起動しました。\n\n初回は音声認識モデル（約 550MB）をダウンロードします。進み具合はタスクバー右下（^ の中）の Koe アイコンにマウスを乗せると表示されます。\n\n準備ができたら、右 Alt を押している間だけ話してください。離すと文字起こしして貼り付けます。", 0x40)
	}
	a.reportPreviousUpdate()
	go a.updateLoop()
	a.prepareModelAndServer()
}

// setHotkey makes name ("ralt" | "rctrl") the push-to-talk key. The event
// loop picks the new key up at the next key event, so no restart is needed.
func (a *App) setHotkey(name string) {
	if name != "rctrl" {
		name = "ralt"
	}
	a.hotkeyName.Store(name)
	a.hotkeyVK.Store(core.HotkeyVK(name))
}

func (a *App) hotkey() string {
	if s, ok := a.hotkeyName.Load().(string); ok {
		return s
	}
	return "ralt"
}

// changeHotkey is the tray handler: saves config.json and applies at once.
func (a *App) changeHotkey(name string) {
	if name == a.hotkey() {
		a.renderHotkey()
		return
	}
	if err := core.SetConfigValue(a.configPath(), "hotkey", name); err != nil {
		a.log.Printf("hotkey_save_failed %v", err)
		a.setError("設定ファイルに保存できませんでした（今回の起動中だけ切り替えます）: "+err.Error(), false)
	}
	a.setHotkey(name)
	a.log.Printf("hotkey_changed %s vk=0x%X", name, core.HotkeyVK(name))
	a.renderHotkey()
	a.render()
}

func (a *App) recoverLog(where string) {
	if r := recover(); r != nil {
		a.log.Printf("PANIC in %s: %v", where, r)
		a.setError(fmt.Sprintf("内部エラー（%s）: %v", where, r), true)
	}
}

func (a *App) prepareModelAndServer() {
	model := a.cfg.ModelPath(a.modelsDir())
	if _, err := os.Stat(model); err != nil {
		url := a.cfg.ModelDownloadURL()
		a.log.Printf("model_download_start url=%s dest=%s", url, model)
		a.setDownload(0)
		t0 := time.Now()
		var lastLogged int
		err := core.Download(context.Background(), url, model, func(done, total int64) {
			if total > 0 {
				pct := float64(done) / float64(total) * 100
				a.setDownload(pct)
				if int(pct)/10 > lastLogged {
					lastLogged = int(pct) / 10
					a.log.Printf("model_download %.0f%% (%d/%d MB)", pct, done>>20, total>>20)
				}
			}
		})
		a.setDownload(-1)
		if err != nil {
			a.log.Printf("model_download_failed err=%v after_ms=%d", err, time.Since(t0).Milliseconds())
			a.setError("モデルのダウンロードに失敗しました（Koe を再起動すると続きから再開します）: "+err.Error(), true)
			return
		}
		a.log.Printf("model_download_done ms=%d", time.Since(t0).Milliseconds())
	}
	if fi, err := os.Stat(model); err == nil {
		a.log.Printf("model %s size_mb=%d", model, fi.Size()>>20)
	}
	a.server = &WhisperServer{app: a}
	if err := a.server.Start(model); err != nil {
		a.log.Printf("server_failed err=%v", err)
		a.setError(err.Error(), true)
		go messageBox("Koe", err.Error(), 0x10)
		return
	}
	a.ready.Store(true)
	a.log.Printf("ready")
	a.render()
}

// ---- key handling (single goroutine) ----

func (a *App) eventLoop(keys <-chan keyEvent) {
	defer a.recoverLog("eventLoop")
	for ev := range keys {
		if vk := a.hotkeyVK.Load(); vk != a.hold.HotkeyVK {
			if a.cur != nil {
				a.cancel(ev.at)
			}
			a.holding.Store(false)
			a.hold.SetHotkey(vk)
			a.log.Printf("hotkey_applied vk=0x%X", vk)
		}
		if ev.injected {
			continue
		}
		// AltGr layouts send a fake LCtrl (scan 0x21D) with Right Alt
		if ev.vk == vkLControl && ev.scan == 0x21D {
			continue
		}
		if ev.down {
			wasHolding := a.hold.Holding()
			switch a.hold.Down(ev.vk, ev.at) {
			case core.ActStart:
				a.log.Printf("key_down hotkey vk=0x%X", ev.vk)
				a.begin(ev)
			case core.ActCancel:
				if wasHolding {
					a.log.Printf("other_key_while_holding vk=0x%X -> cancel", ev.vk)
					a.cancel(ev.at)
				}
			}
		} else {
			act, held := a.hold.Up(ev.vk, ev.at)
			if ev.vk == a.hold.HotkeyVK {
				a.log.Printf("key_up hotkey held=%.2fs action=%s", held.Seconds(), act)
			}
			switch act {
			case core.ActShort:
				a.holding.Store(false)
				a.discard("too_short", held)
			case core.ActFinish:
				a.holding.Store(false)
				a.end(ev.at, held)
			case core.ActNone:
				if ev.vk == a.hold.HotkeyVK {
					a.holding.Store(false)
				}
			}
		}
	}
}

func (a *App) begin(ev keyEvent) {
	a.holding.Store(true)
	if a.hotkey() == "ralt" && a.cfg.MenuMaskKey {
		if err := sendMaskKey(); err != nil {
			a.log.Printf("mask_key_failed %v", err)
		}
	}
	if !a.ready.Load() {
		a.log.Printf("not_ready")
		a.fail("モデルを準備中です。少し待ってから話してください")
		return
	}
	// previous utterance still recording its tail
	a.tail.Wait()
	exe, err := foregroundExe()
	if err != nil {
		a.log.Printf("foreground_exe_failed %v", err)
	}
	u := &utterance{pressedAt: ev.at, app: core.ExeName(exe), record: map[string]any{}}
	t0 := time.Now()
	if err := a.rec.Start(); err != nil {
		a.log.Printf("record_start_failed err=%v", err)
		a.fail("録音を開始できませんでした（マイクを確認してください）: " + err.Error())
		return
	}
	a.log.Printf("record_start app=%s start_ms=%d key_to_start_ms=%d", u.app, time.Since(t0).Milliseconds(), time.Since(ev.at).Milliseconds())
	a.playSound("start")
	a.cur = u
	a.recording.Store(true)
	a.render()
}

func (a *App) cancel(at time.Time) {
	u := a.cur
	a.cur = nil
	if u == nil {
		return
	}
	a.rec.Discard()
	a.recording.Store(false)
	held := at.Sub(u.pressedAt)
	a.log.Printf("cancelled held=%.2fs", held.Seconds())
	if held >= time.Second {
		a.fail("他のキーに触れたので録音を取り消しました")
	}
	a.render()
}

func (a *App) discard(reason string, held time.Duration) {
	u := a.cur
	a.cur = nil
	if u == nil {
		return
	}
	a.rec.Discard()
	a.recording.Store(false)
	a.log.Printf("%s held=%.2fs (ignored)", reason, held.Seconds())
	a.render()
}

func (a *App) end(at time.Time, held time.Duration) {
	u := a.cur
	a.cur = nil
	if u == nil {
		return
	}
	u.releasedAt = at
	u.held = held
	a.processing.Add(1)
	a.tail.Add(1)
	go func() {
		defer a.recoverLog("stop")
		u.pcm = a.rec.Stop()
		a.recording.Store(false)
		a.tail.Done()
		u.record["stop_ms"] = time.Since(u.releasedAt).Milliseconds()
		a.playSound("stop")
		a.render()
		a.queue <- u
	}()
}

// ---- transcription pipeline (single worker, keeps order) ----

func (a *App) worker() {
	for u := range a.queue {
		func() {
			defer a.recoverLog("worker")
			defer a.processing.Add(-1)
			a.process(u)
		}()
		a.render()
	}
}

func (a *App) process(u *utterance) {
	rec := u.record
	captured := u.pcm
	peak := core.Peak(captured)
	trimmed := core.TrimSilence(captured)
	seconds, voiced := core.Seconds(captured), core.Seconds(trimmed)
	rec["app"] = u.app
	rec["hold_seconds"] = core.Round2(u.held.Seconds())
	rec["audio_seconds"] = core.Round2(seconds)
	rec["voiced_seconds"] = core.Round2(voiced)
	rec["peak"] = peak
	rec["packs"] = a.cfg.EnabledPacks
	a.log.Printf("record_stop audio=%.2fs voiced=%.2fs peak=%d hold=%.2fs", seconds, voiced, peak, u.held.Seconds())

	wavPCM := trimmed
	if len(wavPCM) == 0 {
		wavPCM = captured
	}
	wav := core.EncodeWAV(wavPCM)

	if seconds >= 0.5 && peak <= core.MutedPeak {
		rec["outcome"] = "mic_silent"
		a.save(u, wav, nil)
		a.fail("マイクから音が来ていません。マイクがミュートか、Windows の設定（プライバシー → マイク → デスクトップ アプリにマイクへのアクセスを許可）がオフではありませんか？")
		a.rec.Reopen("digital_silence")
		return
	}
	if len(trimmed) == 0 {
		rec["outcome"] = "no_voice"
		a.save(u, wav, nil)
		if u.held >= time.Second {
			a.fail("声を検出できませんでした")
		} else {
			a.setError("声を検出できませんでした", false)
		}
		return
	}

	personal := core.ReadGlossaryFile(a.glossaryPath())
	packs := core.LoadPackEntries(a.packs(), a.cfg.EnabledPacks)
	terms := core.WhisperTerms(personal, packs, a.usageCounts(append(append([]core.Entry{}, personal...), packs...)), core.WhisperPromptTermLimit)
	prompt := core.BuildWhisperPrompt(a.cfg.Prompt, terms, a.previousText(u))
	rec["whisper_model"] = filepath.Base(a.cfg.Model)

	text, ok := a.transcribe(u, wav, prompt, voiced, personal, packs)
	if !ok {
		a.save(u, wav, nil)
		return
	}
	u.record["release_to_transcribed_ms"] = time.Since(u.releasedAt).Milliseconds()
	if err := a.paste(u, text); err != nil {
		rec["outcome"] = "paste_failed"
		rec["error"] = err.Error()
		a.save(u, wav, nil)
		a.fail("貼り付けに失敗しました: " + err.Error())
		return
	}
	rec["outcome"] = "pasted"
	a.save(u, wav, &text)
}

func (a *App) transcribe(u *utterance, wav []byte, prompt string, voiced float64, personal, packs []core.Entry) (string, bool) {
	rec := u.record
	base := core.BaseURL(a.cfg.Port)
	totalMS := int64(0)
	entries := append(append([]core.Entry{}, personal...), packs...)
	for attempt := 0; attempt < 2; attempt++ {
		rec["whisper_prompt"] = prompt
		t0 := time.Now()
		raw, err := core.Transcribe(context.Background(), base, wav, prompt)
		ms := time.Since(t0).Milliseconds()
		totalMS += ms
		rec["transcribe_ms"] = totalMS
		if err != nil {
			a.log.Printf("whisper_error ms=%d err=%v", ms, err)
			rec["outcome"] = "error"
			rec["error"] = err.Error()
			a.fail("文字起こしに失敗: " + err.Error())
			return "", false
		}
		raw = strings.TrimSpace(raw)
		t, applied := core.Autocorrect(raw, entries)
		a.log.Printf("whisper_ok ms=%d chars=%d prompt_chars=%d autocorrected=%v retry=%d", ms, len([]rune(t)), len([]rune(prompt)), applied, attempt)
		rec["raw"] = t
		if t != raw {
			rec["raw_before_autocorrect"] = raw
			rec["autocorrected"] = applied
		}
		if t == "" || core.Hallucinations[t] {
			if attempt == 0 && voiced >= 1.0 {
				rec["retried_without_prompt"] = true
				prompt = ""
				continue
			}
			rec["outcome"] = "hallucination"
			a.fail("うまく聞き取れませんでした。もう一度話してください")
			return "", false
		}
		if core.IsRepetitive(t) {
			if attempt == 0 && prompt != "" {
				rec["retried_without_prompt"] = true
				rec["repetition_before_retry"] = t
				prompt = ""
				continue
			}
			rec["repetition_collapsed"] = t
			return core.CollapseRepeats(t), true
		}
		return t, true
	}
	return "", false
}

func (a *App) paste(u *utterance, text string) error {
	// do not send Ctrl+V while the hotkey is held for the next utterance (it would become Ctrl+Alt+V)
	for i := 0; a.holding.Load() && i < 300; i++ {
		time.Sleep(50 * time.Millisecond)
	}
	exe, err := foregroundExe()
	if err != nil {
		a.log.Printf("foreground_exe_failed %v", err)
	}
	name := core.ExeName(exe)
	u.record["paste_app"] = name
	prev, hadPrev, perr := getClipboardText()
	if perr != nil {
		a.log.Printf("clipboard_read_failed %v", perr)
	}
	t0 := time.Now()
	if err := setClipboardText(text); err != nil {
		return err
	}
	time.Sleep(30 * time.Millisecond)
	if err := sendCtrlV(); err != nil {
		return err
	}
	ms := time.Since(u.releasedAt).Milliseconds()
	u.record["release_to_paste_ms"] = ms
	a.log.Printf("paste app=%s chars=%d clipboard_ms=%d release_to_paste_ms=%d", name, len([]rune(text)), time.Since(t0).Milliseconds(), ms)

	entered := false
	if a.cfg.AutoEnter && core.IsTerminal(exe, a.cfg.EnterApps) {
		time.Sleep(time.Duration(a.cfg.EnterDelayMs) * time.Millisecond)
		now, _ := foregroundExe()
		if core.ExeName(now) != name {
			a.log.Printf("enter_skipped foreground changed %s -> %s", name, core.ExeName(now))
		} else if err := sendEnter(); err != nil {
			a.log.Printf("enter_failed %v", err)
		} else {
			entered = true
			a.log.Printf("enter_sent app=%s delay_ms=%d", name, a.cfg.EnterDelayMs)
		}
	}
	u.record["entered"] = entered

	if a.cfg.RestoreClipboard && hadPrev {
		go func() {
			time.Sleep(800 * time.Millisecond)
			if cur, ok, _ := getClipboardText(); ok && cur == text {
				_ = setClipboardText(prev)
			}
		}()
	}

	a.mu.Lock()
	a.prevByApp[u.app] = pastedText{time.Now(), text}
	a.recent = append(a.recent, text)
	if len(a.recent) > 5 {
		a.recent = a.recent[len(a.recent)-5:]
	}
	a.mu.Unlock()
	return nil
}

func (a *App) previousText(u *utterance) string {
	if !a.cfg.ContextPrompt {
		return ""
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	p, ok := a.prevByApp[u.app]
	if !ok || u.pressedAt.Sub(p.at) >= 3*time.Minute {
		return ""
	}
	return p.text
}

func (a *App) save(u *utterance, wav []byte, pasted *string) {
	if !a.cfg.SaveHistory {
		return
	}
	if pasted != nil {
		u.record["pasted"] = *pasted
	} else {
		u.record["pasted"] = nil
	}
	id := core.NewHistoryID(u.pressedAt)
	if err := core.SaveHistory(a.historyDir(), id, wav, u.record); err != nil {
		a.log.Printf("history_save_failed %v", err)
	}
}

// ---- glossary ----

func (a *App) packs() []core.Pack {
	return core.ListPacks(filepath.Join(a.exeDir, "packs"), a.userPacksDir())
}

func (a *App) usageCounts(entries []core.Entry) map[string]int {
	a.mu.Lock()
	if a.usage != nil && time.Since(a.usageAt) < 10*time.Minute {
		u := a.usage
		a.mu.Unlock()
		return u
	}
	a.mu.Unlock()
	var texts []string
	for _, p := range core.RecentPasted(a.historyDir(), 300) {
		texts = append(texts, p.Text)
	}
	u := core.UsageCounts(entries, texts)
	a.mu.Lock()
	a.usage, a.usageAt = u, time.Now()
	a.mu.Unlock()
	return u
}

func (a *App) syncPacks() {
	if len(a.cfg.PackSources) == 0 {
		return
	}
	gh, err := exec.LookPath("gh")
	if err != nil {
		a.log.Printf("pack_sync_failed gh not found in PATH (%v)", err)
		return
	}
	core.SyncPackSources(a.cfg.PackSources, a.userPacksDir(), time.Now(), func(args []string) ([]byte, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, gh, args...)
		hideWindow(cmd)
		return cmd.Output()
	}, a.log.Printf)
}

func (a *App) exportReceivers() {
	home := os.Getenv("USERPROFILE")
	dir := filepath.Join(home, ".claude")
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		a.log.Printf("receiver_export_skipped (%s not found)", dir)
		return
	}
	personal := core.ReadGlossaryFile(a.glossaryPath())
	packs := core.LoadPackEntries(a.packs(), a.cfg.EnabledPacks)
	var withAliases []core.Entry
	for _, e := range append(append([]core.Entry{}, personal...), packs...) {
		if len(e.Aliases) > 0 {
			withAliases = append(withAliases, e)
		}
	}
	counts := a.usageCounts(withAliases)
	short, full := core.ReceiverNotes(personal, packs, counts, `~\.claude\koe-voice-glossary.full.md`)
	if err := os.WriteFile(filepath.Join(dir, "koe-voice-glossary.md"), []byte(short), 0o644); err != nil {
		a.log.Printf("receiver_export_failed %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "koe-voice-glossary.full.md"), []byte(full), 0o644); err != nil {
		a.log.Printf("receiver_export_failed %v", err)
	}
	a.log.Printf("receiver_exported %s", dir)
}

// ---- feedback ----

func (a *App) fail(msg string) {
	a.log.Printf("fail_notice %q", msg)
	a.playSound("fail")
	a.setError(msg, false)
}

func (a *App) setError(msg string, sticky bool) {
	a.mu.Lock()
	a.errMsg = msg
	if sticky {
		a.errUntil = time.Now().Add(100 * 365 * 24 * time.Hour)
	} else {
		a.errUntil = time.Now().Add(4 * time.Second)
		go func() {
			time.Sleep(4100 * time.Millisecond)
			a.render()
		}()
	}
	a.mu.Unlock()
	a.render()
}

func (a *App) setDownload(pct float64) {
	a.mu.Lock()
	a.download = pct
	a.mu.Unlock()
	a.render()
}

func (a *App) statusText() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.errMsg != "" && time.Now().Before(a.errUntil) {
		return "⚠ " + a.errMsg
	}
	switch {
	case a.updateMsg != "":
		return a.updateMsg
	case a.download >= 0:
		return fmt.Sprintf("モデル取得中 %.0f%%", a.download)
	case a.recording.Load():
		return "録音中"
	case a.processing.Load() > 0:
		return "文字起こし中"
	case !a.ready.Load():
		return "準備中（モデル読み込み）"
	}
	return "待機中（" + core.HotkeyLabel(a.hotkey()) + " を押している間だけ録音）"
}
