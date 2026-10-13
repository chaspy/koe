//go:build windows

package main

import (
	"os"
	"path/filepath"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	sndAsync     = 0x0001
	sndNoDefault = 0x0002
	sndFilename  = 0x00020000
)

// playSound plays assets\<name>.wav asynchronously (start / stop / fail).
func (a *App) playSound(name string) {
	if !a.cfg.Sounds {
		return
	}
	p := filepath.Join(a.exeDir, "assets", name+".wav")
	if _, err := os.Stat(p); err != nil {
		a.log.Printf("sound_missing %s", p)
		return
	}
	u, err := windows.UTF16PtrFromString(p)
	if err != nil {
		return
	}
	if r, _, err := procPlaySoundW.Call(uintptr(unsafe.Pointer(u)), 0, sndAsync|sndFilename|sndNoDefault); r == 0 {
		a.log.Printf("sound_failed %s err=%v", name, err)
	}
}
