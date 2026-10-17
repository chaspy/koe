//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/chaspy/koe/windows/core"
	"github.com/getlantern/systray"
	"golang.org/x/sys/windows"
)

const updateInterval = 24 * time.Hour

func (a *App) versionLabel() string {
	if rev == "" {
		return "Koe " + version
	}
	return fmt.Sprintf("Koe %s (%s)", version, rev)
}

func (a *App) updatePendingPath() string { return filepath.Join(a.localDir, "update-pending.json") }

// reportPreviousUpdate tells whether an update started by the previous run
// took effect.
func (a *App) reportPreviousUpdate() {
	p, ok := core.TakeUpdatePending(a.updatePendingPath())
	if !ok {
		return
	}
	if p.To == version {
		a.log.Printf("update_done from=%s to=%s", p.From, p.To)
		return
	}
	a.log.Printf("update_failed from=%s to=%s running=%s (see update.log)", p.From, p.To, version)
	go a.updateFailedNotice(fmt.Sprintf("v%s への更新が完了しませんでした（いまは %s のままです）。", p.To, version), p.Page)
}

// updateCheckOn: automatic checks (start, daily, menu opened) are enabled.
func (a *App) updateCheckOn() bool { return a.cfg.UpdateCheck && version != "dev" }

// updateLoop checks for a newer release at start and once a day.
func (a *App) updateLoop() {
	defer a.recoverLog("update_check")
	if !a.cfg.UpdateCheck {
		a.log.Printf("update_check_disabled")
		return
	}
	if version == "dev" {
		a.log.Printf("update_check_skipped (dev build)")
		return
	}
	for reason := "start"; ; reason = "daily" {
		a.checkMu.Lock()
		_, _ = a.checkUpdate(reason)
		a.checkMu.Unlock()
		time.Sleep(updateInterval)
	}
}

// checkUpdateOnMenu runs when the tray menu opens: checks again if the last
// check is MenuCheckInterval old, skipping if a check is already running.
func (a *App) checkUpdateOnMenu() {
	defer a.recoverLog("update_check")
	if !a.checkMu.TryLock() {
		return
	}
	defer a.checkMu.Unlock()
	a.mu.Lock()
	due := core.CheckDue(a.checkedAt, time.Now(), core.MenuCheckInterval)
	a.mu.Unlock()
	if due {
		_, _ = a.checkUpdate("menu")
	}
}

// checkUpdateNow is the "更新を確認" handler. It works even with updateCheck off.
func (a *App) checkUpdateNow() {
	defer a.recoverLog("update_check")
	const mbInfo, mbWarn, mbForeground = 0x40, 0x30, 0x10000
	if version == "dev" {
		messageBox("Koe", "開発版のため更新を確認できません", mbInfo|mbForeground)
		return
	}
	a.checkMu.Lock()
	r, err := a.checkUpdate("manual")
	a.checkMu.Unlock()
	switch {
	case err != nil:
		messageBox("Koe", "更新を確認できませんでした: "+err.Error(), mbWarn|mbForeground)
	case r != nil:
		messageBox("Koe", fmt.Sprintf("新しい版 v%s があります（いまは v%s）。\n\nメニューの「新しい版 v%s があります（クリックで更新）」を押すと更新します。", r.Version, version, r.Version), mbInfo|mbForeground)
	default:
		messageBox("Koe", fmt.Sprintf("最新です（v%s）", version), mbInfo|mbForeground)
	}
}

// checkUpdate asks GitHub for the latest release and, if it is newer, shows
// the update item. It returns that release (nil when up to date). The caller
// holds checkMu.
func (a *App) checkUpdate(reason string) (*core.Release, error) {
	a.mu.Lock()
	a.checkedAt = time.Now()
	a.mu.Unlock()
	ua := "Koe-windows/" + version
	r, err := core.LatestRelease(context.Background(), core.GitHubWeb, a.cfg.UpdateRepo, ua)
	switch {
	case err != nil:
		a.log.Printf("update_check_failed reason=%s repo=%s err=%v", reason, a.cfg.UpdateRepo, err)
		return nil, err
	case r.Tag == "":
		a.log.Printf("update_check reason=%s repo=%s has no releases", reason, a.cfg.UpdateRepo)
		return nil, nil
	}
	if !core.NewerVersion(r.Version, version) {
		a.log.Printf("update_check reason=%s latest=%s current=%s (up to date)", reason, r.Version, version)
		return nil, nil
	}
	a.mu.Lock()
	prev := a.avail
	a.mu.Unlock()
	if prev != nil && prev.Version == r.Version {
		return prev, nil // already offered; the zip was checked then
	}
	// the tag can be published before the Windows zip is uploaded
	switch err := core.WindowsAssetExists(context.Background(), r, ua); {
	case errors.Is(err, core.ErrNoWindowsAsset):
		a.log.Printf("update_check reason=%s latest=%s (no windows asset %s)", reason, r.Tag, r.Asset)
		return nil, nil
	case err != nil:
		a.log.Printf("update_check_failed reason=%s asset=%s err=%v", reason, r.AssetURL, err)
		return nil, err
	}
	a.mu.Lock()
	a.avail = &r
	a.mu.Unlock()
	a.log.Printf("update_available current=%s latest=%s asset=%s", version, r.Version, r.Asset)
	go a.prepareUpdatePrompt(r)
	t := &a.tray
	t.mu.Lock()
	if t.update != nil {
		t.update.SetTitle(fmt.Sprintf("新しい版 v%s があります（クリックで更新）", r.Version))
		t.update.Show()
	}
	t.mu.Unlock()
	return &r, nil
}

// startUpdate is the tray click handler.
func (a *App) startUpdate() {
	defer a.recoverLog("update")
	a.mu.Lock()
	r := a.avail
	a.mu.Unlock()
	if r == nil {
		return
	}
	if a.recording.Load() || a.processing.Load() > 0 {
		a.fail("録音・文字起こし中は更新できません。終わってからもう一度押してください")
		return
	}
	if !a.updating.CompareAndSwap(false, true) {
		return
	}
	if err := a.installUpdate(*r); err != nil {
		a.updating.Store(false)
		a.setUpdateStatus("")
		a.log.Printf("update_error to=%s err=%v", r.Version, err)
		a.updateFailedNotice(fmt.Sprintf("v%s への更新に失敗しました: %v", r.Version, err), r.Page)
	}
}

func (a *App) updateFailedNotice(msg, page string) {
	if page == "" {
		page = core.ReleasePageURL(a.cfg.UpdateRepo)
	}
	a.setError(msg, false)
	messageBox("Koe", msg+"\n\nリリースのページを開きます。zip をダウンロードして、いまの Koe のフォルダに上書きで展開してください。", 0x30)
	openURL(page)
}

func openURL(u string) {
	verb, _ := windows.UTF16PtrFromString("open")
	file, _ := windows.UTF16PtrFromString(u)
	_ = windows.ShellExecute(0, verb, file, nil, nil, windows.SW_SHOWNORMAL)
}

func (a *App) installUpdate(r core.Release) error {
	if _, err := os.Stat(filepath.Join(a.exeDir, "whisper-server.exe")); err != nil {
		return fmt.Errorf("Koe のフォルダ（%s）が展開したままの形ではないので自動更新できません", a.exeDir)
	}
	work, err := os.MkdirTemp("", "koe-update-")
	if err != nil {
		return err
	}
	cleanup := func() { _ = os.RemoveAll(work) }
	zipPath := filepath.Join(work, filepath.Base(r.Asset))
	a.log.Printf("update_download_start to=%s url=%s dest=%s", r.Version, r.AssetURL, zipPath)
	a.setUpdateStatus("更新をダウンロード中")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	t0 := time.Now()
	err = core.Download(ctx, r.AssetURL, zipPath, func(done, total int64) {
		if total > 0 {
			a.setUpdateStatus(fmt.Sprintf("更新をダウンロード中 %.0f%%", float64(done)/float64(total)*100))
		}
	})
	if err != nil {
		cleanup()
		return fmt.Errorf("ダウンロード: %w", err)
	}
	a.log.Printf("update_download_done ms=%d", time.Since(t0).Milliseconds())
	a.setUpdateStatus("更新を展開中")
	stage := filepath.Join(work, "stage")
	if err := core.ExtractZip(zipPath, stage); err != nil {
		cleanup()
		return fmt.Errorf("展開: %w", err)
	}
	src, err := core.FindAppRoot(stage, "Koe.exe")
	if err != nil {
		cleanup()
		return err
	}
	_ = os.Remove(zipPath)

	// wait for the current utterance so nothing is lost
	for i := 0; (a.recording.Load() || a.processing.Load() > 0) && i < 240; i++ {
		time.Sleep(500 * time.Millisecond)
	}
	if a.recording.Load() || a.processing.Load() > 0 {
		cleanup()
		return errors.New("録音・文字起こしが終わらないため中止しました")
	}

	script := filepath.Join(os.TempDir(), fmt.Sprintf("koe-update-%d.cmd", time.Now().UnixNano()))
	if err := os.WriteFile(script, core.UpdateScriptCRLF(), 0o644); err != nil {
		cleanup()
		return err
	}
	if err := core.WriteUpdatePending(a.updatePendingPath(), core.UpdatePending{
		From: version, To: r.Version, Page: r.Page, At: time.Now().Format(time.RFC3339),
	}); err != nil {
		a.log.Printf("update_pending_write_failed %v", err)
	}
	env := append(os.Environ(),
		fmt.Sprintf("KOE_PID=%d", os.Getpid()),
		"KOE_SRC="+src,
		"KOE_DST="+a.exeDir,
		"KOE_WORK="+work,
		"KOE_LOG="+filepath.Join(a.localDir, "update.log"),
	)
	cmdExe := filepath.Join(os.Getenv("SystemRoot"), "System32", "cmd.exe")
	// the script runs from %TEMP%, not the install dir, so that dir is not held open
	cmd, err := startDetached(cmdExe, []string{"/d", "/c", script}, os.TempDir(), env)
	if err != nil {
		_ = os.Remove(script)
		_ = os.Remove(a.updatePendingPath())
		cleanup()
		return fmt.Errorf("入れ替え用のスクリプトを起動できません: %w", err)
	}
	a.log.Printf("update_installing from=%s to=%s script_pid=%d src=%s dst=%s", version, r.Version, cmd.Process.Pid, src, a.exeDir)
	_ = cmd.Process.Release()
	a.setUpdateStatus(fmt.Sprintf("v%s に更新します（Koe を再起動します）", r.Version))
	time.Sleep(300 * time.Millisecond)
	systray.Quit() // onExit stops whisper-server and the hook
	return nil
}

// startDetached starts a process in its own hidden console, outside Koe's job
// if Koe itself was started in one (falls back when breakaway is not allowed).
func startDetached(exe string, args []string, dir string, env []string) (*exec.Cmd, error) {
	base := uint32(createNoWindow | windows.CREATE_NEW_PROCESS_GROUP)
	var err error
	for _, flags := range []uint32{base | windows.CREATE_BREAKAWAY_FROM_JOB, base} {
		cmd := exec.Command(exe, args...)
		cmd.Dir, cmd.Env = dir, env
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: flags}
		if err = cmd.Start(); err == nil {
			return cmd, nil
		}
	}
	return nil, err
}

func (a *App) setUpdateStatus(s string) {
	a.mu.Lock()
	a.updateMsg = s
	a.mu.Unlock()
	a.render()
}

// ---- consent-based update prompt (core.ShouldPromptUpdate) ----

type updatePromptState struct {
	mu        sync.Mutex
	version   string // summary below is for this version
	line      string
	noChanges bool
	snoozed   time.Time // "later": quiet until then (this run only)
	loop      bool
}

// prepareUpdatePrompt fetches the release's one-line summary and starts the
// check that asks once Koe is settled.
func (a *App) prepareUpdatePrompt(r core.Release) {
	defer a.recoverLog("update_prompt")
	p := &a.upPrompt
	p.mu.Lock()
	known := p.version == r.Version
	start := !p.loop
	p.loop = true
	p.mu.Unlock()
	if !known {
		line, no := "", false
		if md, err := core.FetchChangelog(context.Background(), core.RawBase, a.cfg.UpdateRepo, r.Tag, "Koe-windows/"+version); err != nil {
			a.log.Printf("update_summary_failed %v", err)
		} else {
			line, no = core.ChangelogSummary(md, r.Version, "Windows", 100)
		}
		p.mu.Lock()
		p.version, p.line, p.noChanges = r.Version, line, no
		p.mu.Unlock()
	}
	if start {
		for {
			a.maybePromptUpdate()
			time.Sleep(15 * time.Second)
		}
	}
}

func (a *App) maybePromptUpdate() {
	a.mu.Lock()
	r := a.avail
	a.mu.Unlock()
	if r == nil || a.updating.Load() {
		return
	}
	p := &a.upPrompt
	p.mu.Lock()
	if p.version != r.Version {
		p.mu.Unlock()
		return
	}
	busy := a.recording.Load() || a.processing.Load() > 0
	var last time.Time
	if n := a.lastUsed.Load(); n > 0 {
		last = time.Unix(0, n)
	}
	now := time.Now()
	if !core.ShouldPromptUpdate(now, r.Version, busy, last, p.snoozed, p.noChanges) {
		p.mu.Unlock()
		return
	}
	p.snoozed = now.Add(core.UpdateSnooze) // asked: quiet for 24 h of this run whatever the answer
	line := p.line
	p.mu.Unlock()
	a.log.Printf("update_prompt version=%s", r.Version)
	text := fmt.Sprintf("新しい版 v%s があります。", r.Version)
	if line != "" {
		text += "\n\n" + line
	}
	text += "\n\n今すぐ更新しますか？（Enter は「いいえ」）\n「はい」: Koe が数十秒止まって、入れ替えて起動し直します。\n「いいえ」: あとで（24 時間後か次の起動でもう一度お知らせします。トレイの「新しい版」からいつでも更新できます）"
	if messageBoxResult("Koe", text, core.UpdatePromptBoxFlags) == core.IDYes {
		a.log.Printf("update_prompt_answer now")
		a.startUpdate()
		return
	}
	a.log.Printf("update_prompt_answer later")
}
