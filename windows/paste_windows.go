//go:build windows

package main

import (
	"errors"
	"fmt"
	"runtime"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

type keyboardInput struct {
	Type  uint32
	_     uint32
	Vk    uint16
	Scan  uint16
	Flags uint32
	Time  uint32
	Extra uintptr
	_     [8]byte
}

// INPUT is 40 bytes on amd64
var _ [40 - unsafe.Sizeof(keyboardInput{})]byte
var _ [unsafe.Sizeof(keyboardInput{}) - 40]byte

func key(vk uint16, up bool) keyboardInput {
	k := keyboardInput{Type: inputKeyboard, Vk: vk}
	if up {
		k.Flags = keyeventfKeyUp
	}
	return k
}

func sendInputs(in []keyboardInput) error {
	n, _, err := procSendInput.Call(uintptr(len(in)), uintptr(unsafe.Pointer(&in[0])), unsafe.Sizeof(in[0]))
	if int(n) != len(in) {
		return fmt.Errorf("SendInput sent %d/%d: %v", n, len(in), err)
	}
	return nil
}

func sendCtrlV() error {
	return sendInputs([]keyboardInput{key(vkControl, false), key(vkV, false), key(vkV, true), key(vkControl, true)})
}

func sendEnter() error {
	return sendInputs([]keyboardInput{key(vkReturn, false), key(vkReturn, true)})
}

// sendMaskKey taps an unassigned key so that releasing Alt alone does not
// activate the menu bar of the focused app.
func sendMaskKey() error {
	return sendInputs([]keyboardInput{key(vkMaskKey, false), key(vkMaskKey, true)})
}

func openClipboard() error {
	var last error
	for i := 0; i < 20; i++ {
		r, _, err := procOpenClipboard.Call(0)
		if r != 0 {
			return nil
		}
		last = err
		time.Sleep(15 * time.Millisecond)
	}
	return fmt.Errorf("OpenClipboard: %v", last)
}

// getClipboardText returns the current CF_UNICODETEXT (ok=false if none).
func getClipboardText() (string, bool, error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if err := openClipboard(); err != nil {
		return "", false, err
	}
	defer procCloseClipboard.Call()
	h, _, _ := procGetClipboardData.Call(cfUnicodeText)
	if h == 0 {
		return "", false, nil
	}
	p, _, err := procGlobalLock.Call(h)
	if p == 0 {
		return "", false, fmt.Errorf("GlobalLock: %v", err)
	}
	defer procGlobalUnlock.Call(h)
	size, _, _ := procGlobalSize.Call(h)
	n := int(size / 2)
	if n == 0 {
		return "", true, nil
	}
	buf := make([]uint16, n)
	procRtlMoveMemory.Call(uintptr(unsafe.Pointer(&buf[0])), p, uintptr(n*2))
	return windows.UTF16ToString(buf), true, nil
}

func setClipboardText(s string) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	u, err := windows.UTF16FromString(s)
	if err != nil {
		return err
	}
	if err := openClipboard(); err != nil {
		return err
	}
	defer procCloseClipboard.Call()
	if r, _, err := procEmptyClipboard.Call(); r == 0 {
		return fmt.Errorf("EmptyClipboard: %v", err)
	}
	size := uintptr(len(u) * 2)
	h, _, err := procGlobalAlloc.Call(gmemMoveable, size)
	if h == 0 {
		return fmt.Errorf("GlobalAlloc: %v", err)
	}
	p, _, err := procGlobalLock.Call(h)
	if p == 0 {
		procGlobalFree.Call(h)
		return fmt.Errorf("GlobalLock: %v", err)
	}
	procRtlMoveMemory.Call(p, uintptr(unsafe.Pointer(&u[0])), size)
	procGlobalUnlock.Call(h)
	if r, _, err := procSetClipboardData.Call(cfUnicodeText, h); r == 0 {
		procGlobalFree.Call(h)
		return fmt.Errorf("SetClipboardData: %v", err)
	}
	return nil
}

// foregroundExe returns the full image path of the foreground window's process.
func foregroundExe() (string, error) {
	hwnd := windows.GetForegroundWindow()
	if hwnd == 0 {
		return "", errors.New("no foreground window")
	}
	var pid uint32
	if _, err := windows.GetWindowThreadProcessId(hwnd, &pid); err != nil || pid == 0 {
		return "", fmt.Errorf("GetWindowThreadProcessId: %v", err)
	}
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return "", fmt.Errorf("OpenProcess(%d): %v", pid, err)
	}
	defer windows.CloseHandle(h)
	buf := make([]uint16, windows.MAX_LONG_PATH)
	n := uint32(len(buf))
	if err := windows.QueryFullProcessImageName(h, 0, &buf[0], &n); err != nil {
		return "", fmt.Errorf("QueryFullProcessImageName: %v", err)
	}
	return windows.UTF16ToString(buf[:n]), nil
}
