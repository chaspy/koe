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
	mLog := systray.AddMenuItem("ログのフォルダを開く", a.localDir)
	mCfg := systray.AddMenuItem("設定ファイルを開く", a.configPath())
	systray.AddSeparator()
	mVer := systray.AddMenuItem(a.versionLabel(), "")
	mVer.Disable()
	mQuit := systray.AddMenuItem("終了", "")
	go func() {
		for {
			select {
			case <-mLog.ClickedCh:
				_ = exec.Command("explorer.exe", a.localDir).Start()
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
