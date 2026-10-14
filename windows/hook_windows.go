//go:build windows

package main

import (
	"fmt"
	"runtime"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

type kbdllhookstruct struct {
	VkCode      uint32
	ScanCode    uint32
	Flags       uint32
	Time        uint32
	DwExtraInfo uintptr
}

type keyEvent struct {
	vk       uint32
	scan     uint32
	flags    uint32
	down     bool
	injected bool
	at       time.Time
}

type msg struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	pt      struct{ x, y int32 }
	private uint32
}

// startKeyboardHook installs WH_KEYBOARD_LL on a dedicated locked OS thread
// with its own message loop. Events are pushed (non-blocking) to ch; the key
// is never swallowed. Returns the hook thread id (for stop) once installed.
func startKeyboardHook(ch chan<- keyEvent) (uint32, error) {
	type result struct {
		tid uint32
		err error
	}
	res := make(chan result, 1)
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		var hook uintptr
		cb := windows.NewCallback(func(nCode uintptr, wParam uintptr, k *kbdllhookstruct) uintptr {
			// nCode is a 32-bit int: only the low 32 bits of the register are defined
			if int32(nCode) == 0 && k != nil {
				ev := keyEvent{
					vk: k.VkCode, scan: k.ScanCode, flags: k.Flags,
					down:     wParam == wmKeyDown || wParam == wmSysKeyDown,
					injected: k.Flags&llkhfInjected != 0,
					at:       time.Now(),
				}
				select {
				case ch <- ev:
				default: // never block the hook (Windows drops slow hooks)
				}
			}
			r, _, _ := procCallNextHookEx.Call(hook, nCode, wParam, uintptr(unsafe.Pointer(k)))
			return r
		})
		h, _, err := procSetWindowsHookExW.Call(whKeyboardLL, cb, 0, 0)
		if h == 0 {
			res <- result{0, fmt.Errorf("SetWindowsHookExW: %v", err)}
			return
		}
		hook = h
		res <- result{windows.GetCurrentThreadId(), nil}
		var m msg
		for {
			r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
			if int32(r) <= 0 {
				break
			}
		}
		procUnhookWindowsHookEx.Call(hook)
	}()
	r := <-res
	return r.tid, r.err
}

func stopKeyboardHook(tid uint32) {
	if tid != 0 {
		procPostThreadMessageW.Call(uintptr(tid), wmQuit, 0, 0)
	}
}

// startMenuHook calls fn whenever a popup menu opens in this process: the tray
// menu, which systray opens with TrackPopupMenu without telling us. The hook is
// out of context, so fn runs on the hook's own thread after the menu is up and
// never delays it; fn must return quickly. Returns the hook thread id.
func startMenuHook(fn func()) (uint32, error) {
	type result struct {
		tid uint32
		err error
	}
	res := make(chan result, 1)
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		cb := windows.NewCallback(func(hook, event, hwnd, idObject, idChild, thread, at uintptr) uintptr {
			fn()
			return 0
		})
		h, _, err := procSetWinEventHook.Call(eventSystemMenuPopupStart, eventSystemMenuPopupStart, 0, cb,
			uintptr(windows.GetCurrentProcessId()), 0, wineventOutOfContext)
		if h == 0 {
			res <- result{0, fmt.Errorf("SetWinEventHook: %v", err)}
			return
		}
		res <- result{windows.GetCurrentThreadId(), nil}
		var m msg
		for {
			r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
			if int32(r) <= 0 {
				break
			}
		}
		procUnhookWinEvent.Call(h)
	}()
	r := <-res
	return r.tid, r.err
}
