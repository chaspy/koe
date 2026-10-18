//go:build windows

package main

import (
	"time"

	"github.com/chaspy/koe/windows/core"
	"golang.org/x/sys/windows"
)

var (
	procIsWindow            = user32.NewProc("IsWindow")
	procIsIconic            = user32.NewProc("IsIconic")
	procShowWindow          = user32.NewProc("ShowWindow")
	procSetForegroundWindow = user32.NewProc("SetForegroundWindow")
	procBringWindowToTop    = user32.NewProc("BringWindowToTop")
	procAttachThreadInput   = user32.NewProc("AttachThreadInput")
)

const swRestore = 9

// restoreForeground brings hwnd (the foreground window at press time, of
// app) back to the front (BUG-FOCUS). Windows lets a process take the
// foreground only if it sent the last input, so Koe first taps its unassigned
// mask key; if that is not enough it briefly attaches to the input of the
// window in front. The window's own focused control comes back with it.
// reason is "" on success, else window_gone / app_gone / not_foreground.
func restoreForeground(hwnd windows.HWND, app string) (ms int64, reason string) {
	t0 := time.Now()
	if hwnd == 0 {
		return 0, "no_window"
	}
	if r, _, _ := procIsWindow.Call(uintptr(hwnd)); r == 0 {
		return 0, "window_gone"
	}
	if core.TargetChanged(app, core.ExeName(windowExe(hwnd))) {
		return 0, "app_gone" // the handle now belongs to another program
	}
	if r, _, _ := procIsIconic.Call(uintptr(hwnd)); r != 0 {
		procShowWindow.Call(uintptr(hwnd), swRestore)
	}
	_ = sendMaskKey()
	if r, _, _ := procSetForegroundWindow.Call(uintptr(hwnd)); r == 0 {
		fg := windows.GetForegroundWindow()
		fgThread, _ := windows.GetWindowThreadProcessId(fg, nil)
		me := windows.GetCurrentThreadId()
		if fgThread != 0 && fgThread != me {
			procAttachThreadInput.Call(uintptr(me), uintptr(fgThread), 1)
			procBringWindowToTop.Call(uintptr(hwnd))
			procSetForegroundWindow.Call(uintptr(hwnd))
			procAttachThreadInput.Call(uintptr(me), uintptr(fgThread), 0)
		}
	}
	for time.Since(t0) < 800*time.Millisecond {
		if windows.GetForegroundWindow() == hwnd {
			time.Sleep(60 * time.Millisecond) // let the window take the keyboard focus before Ctrl+V
			return time.Since(t0).Milliseconds(), ""
		}
		time.Sleep(20 * time.Millisecond)
	}
	return time.Since(t0).Milliseconds(), "not_foreground"
}

// windowExe is the image path of hwnd's process ("" if unknown).
func windowExe(hwnd windows.HWND) string {
	var pid uint32
	if _, err := windows.GetWindowThreadProcessId(hwnd, &pid); err != nil || pid == 0 {
		return ""
	}
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return ""
	}
	defer windows.CloseHandle(h)
	buf := make([]uint16, windows.MAX_LONG_PATH)
	n := uint32(len(buf))
	if err := windows.QueryFullProcessImageName(h, 0, &buf[0], &n); err != nil {
		return ""
	}
	return windows.UTF16ToString(buf[:n])
}
