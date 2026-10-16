//go:build windows

package main

import (
	"os/exec"
	"strings"
	"sync"

	"github.com/chaspy/koe/windows/core"
	"github.com/getlantern/systray"
)

type trayItems struct {
	mu        sync.Mutex
	status    *systray.MenuItem
	recent    []*systray.MenuItem
	recentAll *systray.MenuItem
	update    *systray.MenuItem
	hotkeys   map[string]*systray.MenuItem
	modes     map[string]*systray.MenuItem
	models    map[string]*systray.MenuItem
	speed     *systray.MenuItem
	gpu       *systray.MenuItem
	keep      map[int]*systray.MenuItem
	lastTip   string
	lastIcon  int
}

var (
	iconIdle = core.MakeIcon(0x3B, 0x82, 0xF6, false)
	iconRec  = core.MakeIcon(0xE5, 0x39, 0x35, true)
	iconBusy = core.MakeIcon(0xF5, 0x9E, 0x0B, true)
)

func (a *App) setupTray() {
	systray.SetIcon(iconIdle)
	a.tray.lastIcon = 1
	systray.SetTooltip("Koe — 起動中")
	t := &a.tray
	t.status = systray.AddMenuItem("起動中", "")
	t.status.Disable()
	t.update = systray.AddMenuItem("新しい版があります", "クリックすると更新して Koe を再起動します")
	t.update.Hide()
	go func() {
		for range t.update.ClickedCh {
			go a.startUpdate()
		}
	}()
	systray.AddSeparator()
	parent := systray.AddMenuItem("最近の文字起こし", "クリックでクリップボードにコピー")
	for i := 0; i < 5; i++ {
		mi := parent.AddSubMenuItem("（なし）", "")
		mi.Hide()
		t.recent = append(t.recent, mi)
		idx := i
		go func() {
			for range mi.ClickedCh {
				a.copyRecent(idx)
			}
		}()
	}
	t.recentAll = parent.AddSubMenuItem("5 件まとめてコピー", "")
	go func() {
		for range t.recentAll.ClickedCh {
			a.copyRecent(-1)
		}
	}()
	hk := systray.AddMenuItem("押して話すキー", "")
	t.hotkeys = map[string]*systray.MenuItem{}
	for _, name := range []string{"ralt", "rctrl"} {
		mi := hk.AddSubMenuItemCheckbox(core.HotkeyLabel(name), "", false)
		t.hotkeys[name] = mi
		n := name
		go func() {
			for range mi.ClickedCh {
				a.changeHotkey(n)
			}
		}()
	}
	pm := systray.AddMenuItem("押し方", "")
	t.modes = map[string]*systray.MenuItem{}
	for _, m := range []struct{ mode, label string }{
		{core.PressHold, "押している間だけ録音"},
		{core.PressToggle, "押すたびに開始・終了"},
	} {
		mi := pm.AddSubMenuItemCheckbox(m.label, "", false)
		t.modes[m.mode] = mi
		mode := m.mode
		go func() {
			for range mi.ClickedCh {
				a.changePressMode(mode)
			}
		}()
	}
	mm := systray.AddMenuItem("モデル（速さ⇔精度）", "既定は small。精度が欲しいときは large-v3-turbo（遅い）、遅いと感じたら base")
	t.models = map[string]*systray.MenuItem{}
	for _, c := range core.ModelChoices {
		mi := mm.AddSubMenuItemCheckbox(c.Label, "", false)
		t.models[c.File] = mi
		file := c.File
		go func() {
			for range mi.ClickedCh {
				go a.changeModel(file)
			}
		}()
	}
	t.speed = systray.AddMenuItemCheckbox("速さ優先（短い発話を速く。精度が少し落ちることがある。turbo では効きません）", "オフにすると毎回 30 秒ぶんの枠で文字起こしします（遅いが元の精度）。large-v3-turbo は枠を縮めると文字が出なくなるため、オンでも常に全体で処理します。GPU で動いているときも精度を優先して全体で処理します（config の gpuAudioCtx で変更可）", false)
	go func() {
		for range t.speed.ClickedCh {
			a.changeSpeedFirst()
		}
	}()
	t.gpu = systray.AddMenuItemCheckbox("GPU を使う", "対応する GPU（Intel Arc / Iris Xe など）があれば、そちらで文字起こしします。使えないときは自動で CPU に戻ります", false)
	go func() {
		for range t.gpu.ClickedCh {
			go a.changeGPU()
		}
	}()
	hk2 := systray.AddMenuItem("履歴を残す期間", "録音と文字起こしの履歴（%LOCALAPPDATA%\\Koe\\history）を残す日数。文字は録音の約 2 倍残し、全体で 1GB を超えたら古い録音から消します")
	t.keep = map[int]*systray.MenuItem{}
	for _, d := range core.HistoryKeepChoices {
		mi := hk2.AddSubMenuItemCheckbox(core.HistoryKeepLabel(d), "", false)
		t.keep[d] = mi
		days := d
		go func() {
			for range mi.ClickedCh {
				go a.changeHistoryKeep(days)
			}
		}()
	}
	mDiag := systray.AddMenuItem("診断情報を書き出す（送る用）", "デスクトップに zip を作ります（録音・文字起こしの中身は入りません）")
	go func() {
		for range mDiag.ClickedCh {
			go a.exportDiagnostics()
		}
	}()
	mLog := systray.AddMenuItem("ログのフォルダを開く", a.localDir)
	mCfg := systray.AddMenuItem("設定ファイルを開く", a.configPath())
	mCheck := systray.AddMenuItem("更新を確認", "新しい版が出ていないか、いま確かめます")
	systray.AddSeparator()
	mVer := systray.AddMenuItem(a.versionLabel(), "")
	mVer.Disable()
	mQuit := systray.AddMenuItem("終了", "")
	go func() {
		for {
			select {
			case <-mLog.ClickedCh:
				_ = exec.Command("explorer.exe", a.localDir).Start()
			case <-mCheck.ClickedCh:
				go a.checkUpdateNow()
			case <-mCfg.ClickedCh:
				_ = exec.Command("notepad.exe", a.configPath()).Start()
			case <-mQuit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()
}

// renderHotkey puts the check mark on the current push-to-talk key.
func (a *App) renderHotkey() {
	t := &a.tray
	cur := a.hotkey()
	t.mu.Lock()
	defer t.mu.Unlock()
	for name, mi := range t.hotkeys {
		if name == cur {
			mi.Check()
		} else {
			mi.Uncheck()
		}
	}
}

// renderPressMode puts the check mark on the current press mode.
func (a *App) renderPressMode() {
	t := &a.tray
	cur := a.pressMode()
	t.mu.Lock()
	defer t.mu.Unlock()
	for mode, mi := range t.modes {
		if mode == cur {
			mi.Check()
		} else {
			mi.Uncheck()
		}
	}
}

// renderModel puts the check mark on the model in use (none for a custom model).
func (a *App) renderModel() {
	t := &a.tray
	cur := a.modelFile()
	t.mu.Lock()
	defer t.mu.Unlock()
	for file, mi := range t.models {
		if file == cur {
			mi.Check()
		} else {
			mi.Uncheck()
		}
	}
}

// renderSpeedFirst checks "速さ優先" unless audioCtx is 0 (whole window).
func (a *App) renderSpeedFirst() {
	t := &a.tray
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.speed == nil {
		return
	}
	if a.audioCtxSetting() != 0 {
		t.speed.Check()
	} else {
		t.speed.Uncheck()
	}
}

// renderGPU checks "GPU を使う" unless gpu is "off", and says what runs now.
func (a *App) renderGPU() {
	t := &a.tray
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.gpu == nil {
		return
	}
	title := "GPU を使う"
	switch note := a.gpuStatus(); {
	case strings.HasPrefix(note, "gpu"):
		title += "（いまは GPU で動作中）"
	case a.gpuOff.Load(), note == "":
	case strings.HasSuffix(note, core.FallbackNotBundled):
		title += "（この版には GPU 用が入っていません）"
	default:
		title += "（GPU が使えないため CPU で動作中）"
	}
	t.gpu.SetTitle(title)
	if a.gpuOff.Load() {
		t.gpu.Uncheck()
	} else {
		t.gpu.Check()
	}
}

// renderHistoryKeep checks the history retention in use.
func (a *App) renderHistoryKeep() {
	t := &a.tray
	cur := int(a.keepDays.Load())
	t.mu.Lock()
	defer t.mu.Unlock()
	for d, mi := range t.keep {
		if d == cur {
			mi.Check()
		} else {
			mi.Uncheck()
		}
	}
}

// recentNewestFirst returns up to 5 pasted texts, newest first.
func (a *App) recentNewestFirst() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	var out []string
	for i := len(a.recent) - 1; i >= 0 && len(out) < 5; i-- {
		out = append(out, a.recent[i])
	}
	return out
}

func (a *App) copyRecent(idx int) {
	list := a.recentNewestFirst()
	var text string
	if idx < 0 {
		rev := make([]string, len(list))
		for i, s := range list {
			rev[len(list)-1-i] = s
		}
		text = strings.Join(rev, "\r\n")
	} else if idx < len(list) {
		text = list[idx]
	}
	if text == "" {
		return
	}
	if err := setClipboardText(text); err != nil {
		a.log.Printf("copy_recent_failed %v", err)
		return
	}
	a.log.Printf("copy_recent idx=%d chars=%d", idx, len([]rune(text)))
}

func shorten(s string, n int) string {
	s = strings.ReplaceAll(strings.ReplaceAll(s, "\r", " "), "\n", " ")
	r := []rune(s)
	if len(r) > n {
		return string(r[:n-1]) + "…"
	}
	return s
}

// render updates the tray tooltip, status line, icon and recent items.
func (a *App) render() {
	t := &a.tray
	if t.status == nil {
		return
	}
	status := a.statusText()
	rec := a.recording.Load()
	busy := a.processing.Load() > 0
	t.mu.Lock()
	defer t.mu.Unlock()
	tip := shorten("Koe — "+status, 100) // NOTIFYICONDATA tip is 128 UTF-16 units
	if tip != t.lastTip {
		systray.SetTooltip(tip)
		t.status.SetTitle(shorten(status, 60))
		t.lastTip = tip
	}
	icon := 1
	switch {
	case rec:
		icon = 2
	case busy:
		icon = 3
	}
	if icon != t.lastIcon {
		systray.SetIcon([][]byte{nil, iconIdle, iconRec, iconBusy}[icon])
		t.lastIcon = icon
	}
	list := a.recentNewestFirst()
	for i, mi := range t.recent {
		if i < len(list) {
			mi.SetTitle(shorten(list[i], 40))
			mi.Show()
		} else {
			mi.Hide()
		}
	}
}
