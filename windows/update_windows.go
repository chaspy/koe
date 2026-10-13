//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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
	for {
		a.checkUpdate()
		time.Sleep(updateInterval)
	}
}

func (a *App) checkUpdate() {
	r, err := core.LatestRelease(context.Background(), core.GitHubAPI, a.cfg.UpdateRepo, "Koe-windows/"+version)
	switch {
	case errors.Is(err, core.ErrNoWindowsAsset):
		a.log.Printf("update_check latest=%s (no windows asset)", r.Tag)
		return
	case err != nil:
		a.log.Printf("update_check_failed repo=%s err=%v", a.cfg.UpdateRepo, err)
		return
	case r.Tag == "":
		a.log.Printf("update_check repo=%s has no releases", a.cfg.UpdateRepo)
		return
	}
	if !core.NewerVersion(r.Version, version) {
		a.log.Printf("update_check latest=%s current=%s (up to date)", r.Version, version)
		return
	}
	a.mu.Lock()
	prev := a.avail
	a.avail = &r
	a.mu.Unlock()
	if prev == nil || prev.Version != r.Version {
		a.log.Printf("update_available current=%s latest=%s asset=%s", version, r.Version, r.Asset)
	}
	t := &a.tray
	t.mu.Lock()
	if t.update != nil {
		t.update.SetTitle(fmt.Sprintf("新しい版 v%s があります（クリックで更新）", r.Version))
		t.update.Show()
	}
	t.mu.Unlock()
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
