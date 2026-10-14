//go:build windows

package main

import (
	"golang.org/x/sys/windows"
)

var (
	user32   = windows.NewLazySystemDLL("user32.dll")
	kernel32 = windows.NewLazySystemDLL("kernel32.dll")
	winmm    = windows.NewLazySystemDLL("winmm.dll")

	procSetWindowsHookExW   = user32.NewProc("SetWindowsHookExW")
	procCallNextHookEx      = user32.NewProc("CallNextHookEx")
	procUnhookWindowsHookEx = user32.NewProc("UnhookWindowsHookEx")
	procSetWinEventHook     = user32.NewProc("SetWinEventHook")
	procUnhookWinEvent      = user32.NewProc("UnhookWinEvent")
	procGetMessageW         = user32.NewProc("GetMessageW")
	procPostThreadMessageW  = user32.NewProc("PostThreadMessageW")
	procSendInput           = user32.NewProc("SendInput")
	procOpenClipboard       = user32.NewProc("OpenClipboard")
	procCloseClipboard      = user32.NewProc("CloseClipboard")
	procEmptyClipboard      = user32.NewProc("EmptyClipboard")
	procGetClipboardData    = user32.NewProc("GetClipboardData")
	procSetClipboardData    = user32.NewProc("SetClipboardData")

	procGlobalAlloc   = kernel32.NewProc("GlobalAlloc")
	procGlobalFree    = kernel32.NewProc("GlobalFree")
	procGlobalLock    = kernel32.NewProc("GlobalLock")
	procGlobalUnlock  = kernel32.NewProc("GlobalUnlock")
	procGlobalSize    = kernel32.NewProc("GlobalSize")
	procRtlMoveMemory = kernel32.NewProc("RtlMoveMemory")

	procWaveInGetNumDevs    = winmm.NewProc("waveInGetNumDevs")
	procWaveInGetDevCapsW   = winmm.NewProc("waveInGetDevCapsW")
	procWaveInOpen          = winmm.NewProc("waveInOpen")
	procWaveInClose         = winmm.NewProc("waveInClose")
	procWaveInPrepareHeader = winmm.NewProc("waveInPrepareHeader")
	procWaveInUnprepareHdr  = winmm.NewProc("waveInUnprepareHeader")
	procWaveInAddBuffer     = winmm.NewProc("waveInAddBuffer")
	procWaveInStart         = winmm.NewProc("waveInStart")
	procWaveInReset         = winmm.NewProc("waveInReset")
	procWaveInGetErrorTextW = winmm.NewProc("waveInGetErrorTextW")
	procPlaySoundW          = winmm.NewProc("PlaySoundW")
)

const (
	whKeyboardLL = 13
	wmKeyDown    = 0x0100
	wmKeyUp      = 0x0101
	wmSysKeyDown = 0x0104
	wmSysKeyUp   = 0x0105
	wmQuit       = 0x0012

	eventSystemMenuPopupStart = 0x0006
	wineventOutOfContext      = 0x0000

	llkhfInjected = 0x10

	vkReturn   = 0x0D
	vkControl  = 0x11
	vkLControl = 0xA2
	vkRControl = 0xA3
	vkRMenu    = 0xA5
	vkV        = 0x56
	vkMaskKey  = 0xE8 // unassigned; used like AutoHotkey's menu mask key

	inputKeyboard  = 1
	keyeventfKeyUp = 0x0002

	cfUnicodeText = 13
	gmemMoveable  = 0x0002
)
