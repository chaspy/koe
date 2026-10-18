//go:build windows

// Koe for Windows: hold Right Alt to record (or tap to start / tap to stop),
// release to transcribe with a local whisper-server and paste. See
// README-windows.md.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
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
	asr    *core.SherpaRecognizer // engine "parakeet": Parakeet-ja in this process (server stays nil)
	hold   core.HoldTracker
	hookID uint32
	menuID uint32 // thread of the tray-menu-opened hook

	ready      atomic.Bool
	holding    atomic.Bool
	hotkeyVK   atomic.Uint32 // current push-to-talk key; the event loop picks up changes
	hotkeyName atomic.Value  // string "ralt" | "rctrl"
	toggle     atomic.Bool   // press mode "toggle"; the event loop picks up changes
	model      atomic.Value  // string: model file name / path in use (or being switched to)
	switching  atomic.Bool   // a model switch is running
	audioCtx   atomic.Int64  // core.AudioCtx in use; the menu "速さ優先" switches auto / 0
	gpuOff     atomic.Bool   // config gpu "off"; the menu "GPU を使う" switches it
	keepDays   atomic.Int64  // historyKeepDays in use; the menu "履歴を残す期間" switches it
	lastUsed   atomic.Int64  // unix nano of the last press / paste (the update prompt waits until Koe is settled)
	lowLevel   lowLevelWarningState
	upPrompt   updatePromptState
	gpuOK      atomic.Bool // the GPU server has transcribed once (no more first-request fallback)
	keys       chan keyEvent
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
	usage     core.UsageCache    // recent use of each term; never computed on the transcription path
	avail     *core.Release      // newer release, if any
	gpuNote   string             // backend in use and why ("gpu Vulkan0" / "cpu: no_device")
	choice    core.BackendChoice // last GPU / CPU measurement (backend.json)
	busyMsg   string             // shown as the status while measuring
	gpuNames  []string           // display adapters from the registry
	checkedAt time.Time          // when the last update check started
	checkMu   sync.Mutex         // one update check at a time
	updateMsg string             // update progress shown as the status

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

// messageBoxResult shows a message box and returns the button pressed (IDYES = 6, IDNO = 7, ...).
func messageBoxResult(title, text string, flags uint32) int32 {
	t, _ := windows.UTF16PtrFromString(text)
	c, _ := windows.UTF16PtrFromString(title)
	r, _ := windows.MessageBox(0, t, c, flags)
	return r
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
	stopKeyboardHook(a.menuID)
	if a.server != nil {
		a.server.Stop()
	}
	if a.asr != nil {
		a.asr.Close()
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
	a.toggle.Store(cfg.PressMode == core.PressToggle)
	a.model.Store(cfg.Model)
	a.audioCtx.Store(int64(cfg.AudioCtx))
	a.gpuOff.Store(cfg.GPU == core.GPUOff)
	a.keepDays.Store(int64(cfg.HistoryKeepDays))
	a.gpuNames = readGPUAdapters()
	a.usage.Compute = a.computeUsage
	a.renderHotkey()
	a.renderPressMode()
	a.renderModel()
	a.renderSpeedFirst()
	a.renderGPU()
	a.renderHistoryKeep()
	a.log.Printf("start Koe %s rev=%s windows=%d.%d.%d cpus=%d exe=%s", version, rev, v.MajorVersion, v.MinorVersion, v.BuildNumber, runtime.NumCPU(), a.exeDir)
	si := readSysInfo()
	a.log.Printf("system cpu=%q logical_cpus=%d ram_mb=%d ram_free_mb=%d threads=%d (config threads=%d)",
		si.CPU, runtime.NumCPU(), si.RAMTotalMB, si.RAMFreeMB, cfg.ThreadsFor(runtime.NumCPU()), cfg.Threads)
	a.log.Printf("config engine=%s hotkey=%s pressMode=%s model=%s packs=%v packSources=%v autoEnter=%v enterDelayMs=%d warmMic=%v minHold=%.2f temperatureFallback=%v audioCtx=%s gpu=%s gpuAudioCtx=%s gpu_adapters=%q",
		cfg.Engine, cfg.Hotkey, cfg.PressMode, cfg.Model, cfg.EnabledPacks, cfg.PackSources, cfg.AutoEnter, cfg.EnterDelayMs, cfg.WarmMic, cfg.MinHoldSeconds, cfg.TemperatureFallback, cfg.AudioCtx, cfg.GPU, cfg.GPUAudioCtx, a.gpuNames)
	a.log.Printf("input_devices %q", inputDevices())

	if _, err := os.Stat(a.glossaryPath()); os.IsNotExist(err) {
		_ = os.WriteFile(a.glossaryPath(), []byte("# Koe 個人の辞書\r\n# 1 行 1 語。タブの後に、実際に起きた誤変換の形を ／ 区切りで書く（例: プルリク<TAB>プロリク／プロリック）\r\n"), 0o644)
	}
	_ = os.MkdirAll(a.userPacksDir(), 0o755)
	go a.historyPruneLoop()
	for _, p := range core.RecentPasted(a.historyDir(), 5) {
		a.recent = append(a.recent, p.Text)
	}

	vk := a.hotkeyVK.Load()
	a.hold = core.HoldTracker{HotkeyVK: vk, MinHold: time.Duration(cfg.MinHoldSeconds * float64(time.Second)), Toggle: a.toggle.Load()}
	a.rec = NewRecorder(cfg.WarmMic, a.log.Printf)
	a.rec.Warm()

	keys := make(chan keyEvent, 256)
	a.keys = keys
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

	// usage counts and the receiver notes off the startup and transcription
	// paths: the first utterance uses whatever is cached by then
	go func() {
		defer a.recoverLog("pack_sync")
		a.usage.Refresh()
		a.exportReceivers()
		a.syncPacks()
		a.exportReceivers()
	}()
	if firstRun {
		go messageBox("Koe", "Koe を起動しました。\n\n初回は音声認識モデル（約 190MB）をダウンロードします。進み具合はタスクバー右下（^ の中）の Koe アイコンにマウスを乗せると表示されます。\n\n準備ができたら、右 Alt を押している間だけ話してください。離すと文字起こしして貼り付けます。\n\n文字起こしが遅いと感じたら、アイコンのメニュー「モデル（速さ⇔精度）」で base に軽くしてください（誤変換は増えます）。", 0x40)
	}
	a.reportPreviousUpdate()
	go a.updateLoop()
	if a.updateCheckOn() {
		if tid, err := startMenuHook(func() { go a.checkUpdateOnMenu() }); err != nil {
			a.log.Printf("menu_hook_failed %v", err)
		} else {
			a.menuID = tid
		}
	}
	a.prepareModelAndServer()
}

// wakeEventLoop makes the event loop apply a hotkey / press mode change now
// instead of at the next real key event (cancelling a running recording).
func (a *App) wakeEventLoop() {
	if a.keys == nil {
		return
	}
	select {
	case a.keys <- keyEvent{injected: true, at: time.Now()}:
	default:
	}
}

func (a *App) pressMode() string {
	if a.toggle.Load() {
		return core.PressToggle
	}
	return core.PressHold
}

// changePressMode is the tray handler: saves config.json and applies at once.
func (a *App) changePressMode(mode string) {
	if mode == a.pressMode() {
		a.renderPressMode()
		return
	}
	if err := core.SetConfigValue(a.configPath(), "pressMode", mode); err != nil {
		a.log.Printf("press_mode_save_failed %v", err)
		a.setError("設定ファイルに保存できませんでした（今回の起動中だけ切り替えます）: "+err.Error(), false)
	}
	a.toggle.Store(mode == core.PressToggle)
	a.log.Printf("press_mode_changed %s", mode)
	a.wakeEventLoop()
	a.renderPressMode()
	a.render()
}

func (a *App) audioCtxSetting() core.AudioCtx { return core.AudioCtx(a.audioCtx.Load()) }

// changeSpeedFirst is the tray handler of "速さ優先": on = audioCtx "auto",
// off = 0 (whole window). Saves config.json and applies from the next utterance.
func (a *App) changeSpeedFirst() {
	v := core.AudioCtxAuto
	if a.audioCtxSetting() != 0 {
		v = 0
	}
	if err := core.SetConfigValue(a.configPath(), "audioCtx", v); err != nil {
		a.log.Printf("audio_ctx_save_failed %v", err)
		a.setError("設定ファイルに保存できませんでした（今回の起動中だけ切り替えます）: "+err.Error(), false)
	}
	a.audioCtx.Store(int64(v))
	a.log.Printf("audio_ctx_changed %s", v)
	a.renderSpeedFirst()
	a.render()
}

func (a *App) modelFile() string {
	if s, ok := a.model.Load().(string); ok {
		return s
	}
	return a.cfg.Model
}

func (a *App) modelPathFor(file string) string {
	c := a.cfg
	c.Model = file
	return c.ModelPath(a.modelsDir())
}

// changeModel is the tray handler: downloads the model if needed, saves
// config.json and restarts whisper-server with it.
func (a *App) changeModel(file string) {
	defer a.recoverLog("change_model")
	if a.engineLocked() {
		a.renderModel()
		return
	}
	if file == a.modelFile() && a.ready.Load() {
		a.renderModel()
		return
	}
	if a.recording.Load() || a.processing.Load() > 0 {
		a.renderModel()
		a.setError("録音中・文字起こし中はモデルを切り替えられません。終わってからもう一度選んでください", false)
		return
	}
	if !a.switching.CompareAndSwap(false, true) {
		a.renderModel()
		a.setError("モデルを準備中です。終わってからもう一度選んでください", false)
		return
	}
	defer a.switching.Store(false)
	prev := a.modelFile()
	a.log.Printf("model_change from=%s to=%s", prev, file)
	path := a.modelPathFor(file)
	if err := a.ensureModel(path, core.ModelFileURL(file)); err != nil {
		a.renderModel()
		return
	}
	if err := core.SetConfigValue(a.configPath(), "model", file); err != nil {
		a.log.Printf("model_save_failed %v", err)
		a.setError("設定ファイルに保存できませんでした（今回の起動中だけ切り替えます）: "+err.Error(), false)
	}
	a.model.Store(file)
	a.renderModel()
	a.ready.Store(false)
	a.render()
	if a.server != nil {
		a.server.StopAndWait()
	}
	a.startServer(path)
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
	a.wakeEventLoop()
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
	a.switching.Store(true)
	defer a.switching.Store(false)
	if a.parakeet() {
		a.prepareParakeet()
		return
	}
	model := a.cfg.ModelPath(a.modelsDir())
	if err := a.ensureModel(model, a.cfg.ModelDownloadURL()); err != nil {
		return
	}
	a.startServer(model)
}

func (a *App) parakeet() bool { return a.cfg.Engine == core.EngineParakeet }

// prepareParakeet downloads and unpacks Parakeet-ja on first use (through
// the same download as whisper's models, with the same progress), then loads
// it in this process with sherpa-onnx-c-api.dll. No whisper-server and no
// GPU measurement: Parakeet-ja runs on the CPU.
func (a *App) prepareParakeet() {
	dir := core.ParakeetDir(a.modelsDir())
	if !core.ParakeetReady(dir) {
		archive := dir + ".tar.bz2"
		if err := a.ensureModel(archive, core.ParakeetModelURL); err != nil {
			return
		}
		if err := core.CheckSHA256(archive, core.ParakeetModelSHA256); err != nil {
			a.log.Printf("parakeet_checksum_failed err=%v", err)
			_ = os.Remove(archive) // fetched again at the next start
			a.setError("Parakeet-ja のモデルが壊れているか、配布物と違います。消したので、Koe を再起動するともう一度取得します", true)
			return
		}
		a.setBusy("モデルを展開しています（初回だけ、1〜2 分）")
		t0 := time.Now()
		err := core.ExtractParakeet(archive, dir)
		a.setBusy("")
		if err != nil {
			a.log.Printf("parakeet_extract_failed err=%v after_ms=%d", err, time.Since(t0).Milliseconds())
			_ = os.Remove(archive) // broken download: fetch again next time
			a.setError("Parakeet-ja のモデルを展開できませんでした（Koe を再起動するともう一度取得します）: "+err.Error(), true)
			return
		}
		_ = os.Remove(archive)
		a.log.Printf("parakeet_extract_done ms=%d dir=%s", time.Since(t0).Milliseconds(), dir)
	}
	threads := a.cfg.ParakeetThreads(runtime.NumCPU())
	t0 := time.Now()
	r, err := core.NewSherpaRecognizer(filepath.Join(a.exeDir, core.SherpaDLL), dir, threads)
	if err != nil {
		a.log.Printf("parakeet_load_failed err=%v", err)
		msg := err.Error() + "。config.json の engine を \"whisper\" に戻すと、今までの文字起こしで動きます"
		a.setError(msg, true)
		go messageBox("Koe", msg, 0x10)
		return
	}
	a.asr = r
	a.log.Printf("parakeet_ready sherpa=%s threads=%d load_ms=%d model=%s", r.Version(), threads, time.Since(t0).Milliseconds(), dir)
	a.setGPUNote("cpu: parakeet")
	a.markReady("cpu", "parakeet")
}

// engineLocked: with engine "parakeet" the whisper model and GPU menus do
// nothing; say so instead of starting whisper-server.
func (a *App) engineLocked() bool {
	if !a.parakeet() {
		return false
	}
	a.setError("今は Parakeet-ja で文字起こししています（config.json の engine）。whisper のモデルと GPU の設定は、engine を \"whisper\" に戻すと使われます", false)
	return true
}

// ensureModel downloads the model to path (resuming a partial download)
// unless it is already there. Progress is shown in the tray tooltip.
func (a *App) ensureModel(model, url string) error {
	if _, err := os.Stat(model); err != nil {
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
			a.setError("モデルのダウンロードに失敗しました（Koe を再起動するか、もう一度選ぶと続きから再開します）: "+err.Error(), true)
			return err
		}
		a.log.Printf("model_download_done ms=%d", time.Since(t0).Milliseconds())
	}
	return nil
}

// startServer launches whisper-server with model and marks Koe ready.
//
// gpu "auto": the Vulkan build is kept only if it runs on a GPU and was
// faster than the CPU build on assets/probe.wav (small integrated GPUs can be
// slower). The measurement is saved in backend.json and reused until the
// version, the model or the display adapters change.
func (a *App) startServer(model string) {
	if fi, err := os.Stat(model); err == nil {
		a.log.Printf("model %s size_mb=%d", model, fi.Size()>>20)
	}
	a.setError("", false)
	a.gpuOK.Store(false)
	if a.gpuOff.Load() {
		a.serveCPU(model, "off")
		return
	}
	size := fileSize(model)
	if c, ok := core.LoadBackendChoice(a.backendChoicePath()); ok && c.Matches(version, model, size, a.gpuNames) {
		a.setChoice(c)
		a.log.Printf("backend_choice saved choice=%s reason=%s gpu_ms=%d cpu_ms=%d at=%s", c.Choice, c.Reason, c.GPUms, c.CPUms, c.At)
		if c.Choice == core.BackendCPU {
			a.serveCPU(model, c.Reason)
			return
		}
		s, reason := a.startGPU(model)
		if reason != "" {
			a.saveChoice(core.NewBackendChoice(version, model, size, a.gpuNames, core.BackendCPU, reason))
			a.serveCPU(model, reason)
			return
		}
		a.serve(s)
		return
	}
	a.measureAndServe(model, size)
}

// measureAndServe times probe.wav on the GPU build, then on the CPU build,
// and keeps the faster one running.
func (a *App) measureAndServe(model string, size int64) {
	s, reason := a.startGPU(model)
	if reason != "" {
		a.saveChoice(core.NewBackendChoice(version, model, size, a.gpuNames, core.BackendCPU, reason))
		a.serveCPU(model, reason)
		return
	}
	a.setBusy("GPU と CPU の速さを測っています（初回だけ）")
	defer a.setBusy("")
	wav, sec, err := a.probeWAV()
	if err != nil {
		a.log.Printf("backend_measure_skipped err=%v (using the GPU)", err)
		a.serve(s)
		return
	}
	gpuMS, gerr := core.MeasureTranscribe(context.Background(), core.BaseURL(a.cfg.Port), wav, a.cfg.Prompt, a.cfg.GPUAudioCtx.For(sec, model))
	s.StopAndWait()
	cpu := &WhisperServer{app: a}
	if err := cpu.Start(model); err != nil {
		a.log.Printf("server_failed err=%v", err)
		a.setError(err.Error(), true)
		go messageBox("Koe", err.Error(), 0x10)
		return
	}
	cpuMS, cerr := core.MeasureTranscribe(context.Background(), core.BaseURL(a.cfg.Port), wav, a.cfg.Prompt, a.audioCtxSetting().For(sec, model))
	if gerr != nil {
		gpuMS = 0
	}
	if cerr != nil {
		cpuMS = 0
	}
	pick := core.PickBackend(gpuMS, cpuMS)
	why := pick + "_faster"
	if gerr != nil {
		why = core.FallbackFirstFailed
	}
	c := core.NewBackendChoice(version, model, size, a.gpuNames, pick, why)
	c.GPUms, c.CPUms = gpuMS, cpuMS
	a.saveChoice(c)
	a.log.Printf("backend_measure probe_s=%.2f gpu_ms=%d gpu_err=%v cpu_ms=%d cpu_err=%v choice=%s adapters=%q", sec, gpuMS, gerr, cpuMS, cerr, pick, a.gpuNames)
	if pick == core.BackendCPU {
		a.server = cpu
		a.setGPUNote("cpu: " + why)
		a.markReady("cpu", why)
		return
	}
	cpu.StopAndWait()
	if s, reason = a.startGPU(model); reason != "" {
		a.saveChoice(core.NewBackendChoice(version, model, size, a.gpuNames, core.BackendCPU, reason))
		a.serveCPU(model, reason)
		return
	}
	a.serve(s)
}

// startGPU starts the Vulkan build and checks it runs on a GPU; on failure it
// is stopped and the reason returned. Koe is not marked ready.
func (a *App) startGPU(model string) (*WhisperServer, string) {
	if _, err := os.Stat(filepath.Join(a.exeDir, core.VulkanServerExe)); err != nil {
		return nil, core.FallbackNotBundled
	}
	s := &WhisperServer{app: a, Exe: core.VulkanServerExe}
	if err := s.Start(model); err != nil {
		a.log.Printf("gpu_server_failed err=%v", err)
		s.StopAndWait()
		return nil, core.FallbackStartFailed
	}
	if r := s.Probe.FallbackReason(); r != "" {
		s.StopAndWait()
		return nil, r
	}
	s.OnGPU = true
	return s, ""
}

// serve makes the running GPU server the one Koe uses.
func (a *App) serve(s *WhisperServer) {
	a.server = s
	a.setGPUNote("gpu " + s.Probe.Backend())
	a.log.Printf("server_backend=gpu backend=%s adapters=%q", s.Probe.Backend(), a.gpuNames)
	a.markReady("gpu", "")
}

// serveCPU starts the CPU build; reason says why not the GPU.
func (a *App) serveCPU(model, reason string) {
	if reason != "off" {
		a.log.Printf("gpu_fallback reason=%s adapters=%q -> cpu", reason, a.gpuNames)
	}
	a.setGPUNote("cpu: " + reason)
	a.renderGPU()
	a.server = &WhisperServer{app: a}
	if err := a.server.Start(model); err != nil {
		a.log.Printf("server_failed err=%v", err)
		a.setError(err.Error(), true)
		go messageBox("Koe", err.Error(), 0x10)
		return
	}
	a.markReady("cpu", reason)
}

func (a *App) markReady(backend, reason string) {
	if backend == "cpu" {
		a.log.Printf("server_backend=cpu reason=%s", reason)
	}
	a.ready.Store(true)
	a.log.Printf("ready")
	a.renderGPU()
	a.render()
}

func (a *App) backendChoicePath() string { return filepath.Join(a.localDir, "backend.json") }

func (a *App) saveChoice(c core.BackendChoice) {
	a.setChoice(c)
	if err := core.SaveBackendChoice(a.backendChoicePath(), c); err != nil {
		a.log.Printf("backend_choice_save_failed %v", err)
	}
}

func (a *App) setChoice(c core.BackendChoice) {
	a.mu.Lock()
	a.choice = c
	a.mu.Unlock()
}

func (a *App) backendChoice() core.BackendChoice {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.choice
}

func (a *App) setBusy(msg string) {
	a.mu.Lock()
	a.busyMsg = msg
	a.mu.Unlock()
	a.render()
}

// probeWAV is assets/probe.wav as Koe would send it (silence trimmed).
func (a *App) probeWAV() ([]byte, float64, error) {
	raw, err := os.ReadFile(filepath.Join(a.exeDir, "assets", core.ProbeWAV))
	if err != nil {
		return nil, 0, err
	}
	pcm := core.TrimSilence(core.WAVSamples(raw))
	if len(pcm) == 0 {
		return nil, 0, errors.New("probe.wav has no sound")
	}
	return core.EncodeWAV(pcm), core.Seconds(pcm), nil
}

func fileSize(path string) int64 {
	if fi, err := os.Stat(path); err == nil {
		return fi.Size()
	}
	return 0
}

func (a *App) onGPU() bool {
	s := a.server
	return s != nil && s.OnGPU
}

func (a *App) setGPUNote(s string) {
	a.mu.Lock()
	a.gpuNote = s
	a.mu.Unlock()
}

func (a *App) gpuStatus() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.gpuNote
}

// fallbackToCPU restarts on the CPU build after the GPU server failed a
// request; the caller retries the utterance.
func (a *App) fallbackToCPU(reason string) {
	if !a.switching.CompareAndSwap(false, true) {
		return
	}
	defer a.switching.Store(false)
	a.ready.Store(false)
	a.render()
	if a.server != nil {
		a.server.StopAndWait()
	}
	model := a.modelPathFor(a.modelFile())
	a.saveChoice(core.NewBackendChoice(version, model, fileSize(model), a.gpuNames, core.BackendCPU, reason))
	a.serveCPU(model, reason)
}

// changeGPU is the tray handler of "GPU を使う": saves config.json and
// restarts whisper-server on the chosen build.
func (a *App) changeGPU() {
	defer a.recoverLog("change_gpu")
	if a.engineLocked() {
		a.renderGPU()
		return
	}
	if a.recording.Load() || a.processing.Load() > 0 {
		a.renderGPU()
		a.setError("録音中・文字起こし中は切り替えられません。終わってからもう一度選んでください", false)
		return
	}
	if !a.switching.CompareAndSwap(false, true) {
		a.renderGPU()
		a.setError("準備中です。終わってからもう一度選んでください", false)
		return
	}
	defer a.switching.Store(false)
	off := !a.gpuOff.Load()
	v := core.GPUAuto
	if off {
		v = core.GPUOff
	}
	if err := core.SetConfigValue(a.configPath(), "gpu", v); err != nil {
		a.log.Printf("gpu_save_failed %v", err)
		a.setError("設定ファイルに保存できませんでした（今回の起動中だけ切り替えます）: "+err.Error(), false)
	}
	a.gpuOff.Store(off)
	if !off {
		_ = os.Remove(a.backendChoicePath()) // turned on again: measure again
	}
	a.log.Printf("gpu_changed %s", v)
	a.ready.Store(false)
	a.render()
	if a.server != nil {
		a.server.StopAndWait()
	}
	a.startServer(a.modelPathFor(a.modelFile()))
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
		if tg := a.toggle.Load(); tg != a.hold.Toggle {
			if a.cur != nil {
				a.cancel(ev.at)
			}
			a.holding.Store(false)
			a.hold.SetToggle(tg)
			a.log.Printf("press_mode_applied toggle=%v", tg)
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
			case core.ActNone:
				if ev.vk == a.hold.HotkeyVK && a.hold.Latched() {
					a.holding.Store(true) // stop tap: do not paste while the key is down
				}
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
			case core.ActLatch:
				a.holding.Store(false)
				if a.cur == nil {
					// recording did not start (not ready / mic error): the next tap starts again
					a.hold.Reset()
					break
				}
				a.log.Printf("toggle_latched (recording until the next tap)")
				a.render()
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
	a.lastUsed.Store(time.Now().UnixNano())
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
	defer a.lastUsed.Store(time.Now().UnixNano())
	rec := u.record
	t0 := time.Now()
	captured := u.pcm
	peak := core.Peak(captured)
	trimmed := core.TrimSilence(captured)
	tTrim := time.Now()
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
	tWAV := time.Now()

	if seconds >= 0.5 && peak <= core.MutedPeak {
		rec["outcome"] = "mic_silent"
		a.save(u, wav, nil)
		a.fail("マイクから音が来ていません。マイクがミュートか、Windows の設定（プライバシー → マイク → デスクトップ アプリにマイクへのアクセスを許可）がオフではありませんか？")
		a.rec.Reopen("digital_silence")
		return
	}
	quietWarning := a.warnLowLevel(captured)
	if len(trimmed) == 0 {
		rec["outcome"] = "no_voice"
		a.save(u, wav, nil)
		if quietWarning {
			return
		}
		if u.held >= time.Second {
			a.fail("声を検出できませんでした")
		} else {
			a.setError("声を検出できませんでした", false)
		}
		return
	}

	tPrep := time.Now()
	personal := core.ReadGlossaryFile(a.glossaryPath())
	tGlossary := time.Now()
	packs := core.LoadPackEntries(a.packs(), a.cfg.EnabledPacks)
	tPacks := time.Now()
	usage := a.usage.Get() // cached; refreshed after pastes, never here
	usageAge := a.usage.Age(time.Now())
	tUsage := time.Now()
	prompt := "" // Parakeet-ja takes no prompt; the terms still go to Autocorrect
	if !a.parakeet() {
		terms := core.WhisperTerms(personal, packs, usage, core.WhisperPromptTermLimit)
		prompt = core.BuildWhisperPrompt(a.cfg.Prompt, terms, a.previousText(u))
	}
	tPrompt := time.Now()
	rec["engine"] = a.cfg.Engine
	rec["whisper_model"] = filepath.Base(a.modelFile())
	if a.parakeet() {
		rec["whisper_model"] = core.ParakeetModelName
	}
	rec["prompt_ms"] = tPrompt.Sub(tPrep).Milliseconds()
	rec["prepare_ms"] = tPrompt.Sub(t0).Milliseconds()
	ms := func(a, b time.Time) float64 { return float64(b.Sub(a).Microseconds()) / 1000 }
	age := "none"
	if usage != nil {
		age = fmt.Sprintf("%.0fs", usageAge.Seconds())
	}
	a.log.Printf("prepare_ms total=%.1f trim=%.1f wav=%.1f glossary=%.1f packs=%.1f usage=%.1f prompt=%.1f usage_age=%s",
		ms(t0, tPrompt), ms(t0, tTrim), ms(tTrim, tWAV), ms(tPrep, tGlossary), ms(tGlossary, tPacks), ms(tPacks, tUsage), ms(tUsage, tPrompt), age)

	text, ok := a.transcribe(u, wav, prompt, voiced, personal, packs)
	if !ok {
		a.save(u, wav, nil)
		return
	}
	u.record["release_to_transcribed_ms"] = time.Since(u.releasedAt).Milliseconds()
	if err := a.paste(u, text); errors.Is(err, errTargetChanged) {
		// the user moved to another app while Koe was transcribing: do not
		// paste into it; the text is on the clipboard
		rec["outcome"] = "target_changed"
		rec["kept_on_clipboard"] = true
		a.save(u, wav, nil)
		a.fail("貼り先が変わったので貼りませんでした（Ctrl+V で貼れます）")
		return
	} else if err != nil {
		rec["outcome"] = "paste_failed"
		rec["error"] = err.Error()
		a.save(u, wav, nil)
		a.fail("貼り付けに失敗しました: " + err.Error())
		return
	}
	rec["outcome"] = "pasted"
	a.save(u, wav, &text)
	a.usage.RefreshIfStale(time.Now(), core.UsageMaxAge)
}

func (a *App) transcribe(u *utterance, wav []byte, prompt string, voiced float64, personal, packs []core.Entry) (string, bool) {
	rec := u.record
	model := a.modelFile()
	rec["whisper_prompt"] = prompt
	run := func() core.UtteranceResult {
		gpu := a.onGPU()
		setting := a.cfg.AudioCtxSetting(gpu, a.audioCtxSetting())
		req := core.UtteranceRequest{
			BaseURL: core.BaseURL(a.cfg.Port), WAV: wav, Prompt: prompt, Voiced: voiced, Model: model,
			AudioCtx: setting, Fallback: a.cfg.TemperatureFallback,
			Entries: append(append([]core.Entry{}, personal...), packs...),
		}
		key := "whisper"
		if a.asr != nil {
			key, model = "parakeet", core.ParakeetModelName
			req.Recognizer, req.SingleShot, req.Model = a.asr, true, model
			rec["whisper_backend"] = "cpu"
		} else {
			rec["whisper_backend"] = map[bool]string{true: "gpu", false: "cpu"}[gpu]
			rec["whisper_audio_ctx"] = setting.For(voiced, model)
		}
		req.OnPass = func(attempt int, p core.Pass) {
			if p.Err != nil {
				a.log.Printf("%s_error ms=%d audio_ctx=%d err=%v", key, p.MS, p.AudioCtx, p.Err)
				return
			}
			ratio := core.MsPerAudioSecond(p.MS, voiced)
			rec["ms_per_audio_second"] = int64(ratio)
			a.log.Printf("%s_ok ms=%d audio_sent=%.2fs ms_per_audio_s=%.0f audio_ctx=%d fallback=%v model=%s chars=%d prompt_chars=%d corrections=%d retry=%d",
				key, p.MS, voiced, ratio, p.AudioCtx, p.Fallback, filepath.Base(model), len([]rune(p.Text)), len([]rune(p.Prompt)), len(p.Applied), attempt)
			if !req.SingleShot && attempt == 0 && core.IsRepetitive(p.Text) {
				a.log.Printf("whisper_repetition chars=%d audio_ctx=%d fallback=%v -> retry audio_ctx=0 fallback=true", len([]rune(p.Text)), p.AudioCtx, p.Fallback)
			}
			if !req.SingleShot && attempt == 0 && core.HasStockPhrase(p.Text) {
				a.log.Printf("whisper_stock_phrase chars=%d audio_ctx=%d fallback=%v -> retry audio_ctx=0 fallback=true", len([]rune(p.Text)), p.AudioCtx, p.Fallback)
			}
		}
		return core.TranscribeUtterance(context.Background(), req)
	}
	gpu := a.onGPU()
	res := run()
	if gpu && !a.gpuOK.Load() {
		if res.Outcome == core.OutcomeError {
			// the GPU server started but cannot transcribe (driver, unsupported op): CPU from now on
			a.log.Printf("gpu_first_request_failed err=%v", res.Err)
			first := res.TotalMS
			a.fallbackToCPU(core.FallbackFirstFailed)
			if a.ready.Load() {
				rec["retried_on_cpu"] = true
				res = run()
				res.TotalMS += first
			}
		} else {
			a.gpuOK.Store(true)
		}
	}
	rec["transcribe_ms"] = res.TotalMS
	if last := res.Passes[len(res.Passes)-1]; last.Err == nil {
		rec["whisper_prompt"] = last.Prompt
		rec["raw"] = last.Text
		if last.Text != last.Raw {
			rec["raw_before_autocorrect"] = last.Raw
			rec["autocorrected"] = last.Applied
		}
	}
	if res.RetriedWithoutPrompt {
		rec["retried_without_prompt"] = true
	}
	if res.RetriedForRepetition {
		rec["retried_for_repetition"] = true
		rec["repetition_before_retry"] = res.RepetitionBeforeRetry
		rec["whisper_audio_ctx_retry"] = 0
	}
	if res.RetriedForStock {
		rec["retried_for_stock_phrase"] = true
		rec["stock_phrase_before_retry"] = res.StockBeforeRetry
		rec["whisper_audio_ctx_retry"] = 0
	}
	if res.StockRemoved != "" {
		rec["stock_phrase_removed"] = res.StockRemoved
	}
	switch res.Outcome {
	case core.OutcomeError:
		rec["outcome"] = "error"
		rec["error"] = res.Err.Error()
		a.fail("文字起こしに失敗: " + res.Err.Error())
		return "", false
	case core.OutcomeHallucination:
		rec["outcome"] = "hallucination"
		a.fail("うまく聞き取れませんでした。もう一度話してください")
		return "", false
	}
	if res.RepetitionCollapsed != "" {
		rec["repetition_collapsed"] = res.RepetitionCollapsed
	}
	return res.Text, true
}

// errTargetChanged: the foreground app at paste time is not the one at press
// time; the text was put on the clipboard but not pasted.
var errTargetChanged = errors.New("paste target changed")

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
	if core.TargetChanged(u.app, name) {
		a.log.Printf("paste_target_changed start_app=%s paste_app=%s chars=%d -> clipboard only", u.app, name, len([]rune(text)))
		if err := setClipboardText(text); err != nil {
			return err
		}
		a.mu.Lock()
		a.recent = append(a.recent, text)
		if len(a.recent) > 5 {
			a.recent = a.recent[len(a.recent)-5:]
		}
		a.mu.Unlock()
		a.render()
		return errTargetChanged
	}
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
	a.log.Printf("paste app=%s start_app=%s chars=%d clipboard_ms=%d release_to_paste_ms=%d", name, u.app, len([]rune(text)), time.Since(t0).Milliseconds(), ms)

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

// computeUsage counts, for every glossary and pack term, how often it was
// pasted recently (reads up to 600 history files; run off the transcription
// path via a.usage).
func (a *App) computeUsage() map[string]int {
	t0 := time.Now()
	entries := append(core.ReadGlossaryFile(a.glossaryPath()), core.LoadPackEntries(a.packs(), a.cfg.EnabledPacks)...)
	var texts []string
	for _, p := range core.RecentPasted(a.historyDir(), 300) {
		texts = append(texts, p.Text)
	}
	u := core.UsageCounts(entries, texts)
	a.log.Printf("usage_counted terms=%d texts=%d ms=%d", len(entries), len(texts), time.Since(t0).Milliseconds())
	return u
}

// historyPruneLoop applies the history retention at start and once a day, off
// the recording / transcription path.
func (a *App) historyPruneLoop() {
	defer a.recoverLog("history_prune")
	for {
		a.pruneHistory("start_or_daily")
		time.Sleep(core.HistoryPruneEvery)
	}
}

func (a *App) pruneHistory(reason string) {
	keep := int(a.keepDays.Load())
	t0 := time.Now()
	r := core.HistoryPrune(a.historyDir(), keep, core.HistoryCapBytes, time.Now())
	a.log.Printf("history_pruned reason=%s keep_days=%d text_days=%d removed_audio=%d removed_text=%d removed_dirs=%d freed_mb=%.1f size_mb=%.1f ms=%d",
		reason, keep, core.HistoryTextDays(keep), r.Audio, r.Text, r.Dirs, float64(r.Bytes)/(1<<20), float64(r.SizeAfter)/(1<<20), time.Since(t0).Milliseconds())
}

// changeHistoryKeep is the tray handler of "履歴を残す期間".
func (a *App) changeHistoryKeep(days int) {
	defer a.recoverLog("history_keep")
	if err := core.SetConfigValue(a.configPath(), "historyKeepDays", days); err != nil {
		a.log.Printf("history_keep_save_failed %v", err)
		a.setError("設定ファイルに保存できませんでした（今回の起動中だけ切り替えます）: "+err.Error(), false)
	}
	a.keepDays.Store(int64(days))
	a.log.Printf("history_keep_changed %d", days)
	a.renderHistoryKeep()
	a.pruneHistory("setting_changed")
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
	if a.usage.Get() == nil {
		a.usage.Refresh()
	}
	counts := a.usage.Get()
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
	case a.busyMsg != "":
		return a.busyMsg
	case a.download >= 0:
		return fmt.Sprintf("モデル取得中 %.0f%%", a.download)
	case a.recording.Load() && a.toggle.Load():
		return "録音中（もう一度 " + core.HotkeyLabel(a.hotkey()) + " を押すと終了）"
	case a.recording.Load():
		return "録音中"
	case a.processing.Load() > 0:
		return "文字起こし中"
	case !a.ready.Load():
		return "準備中（モデル読み込み）"
	}
	if a.toggle.Load() {
		return "待機中（" + core.HotkeyLabel(a.hotkey()) + " を押すと録音開始、もう一度で終了）"
	}
	return "待機中（" + core.HotkeyLabel(a.hotkey()) + " を押している間だけ録音）"
}
