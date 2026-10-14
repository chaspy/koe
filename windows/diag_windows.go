//go:build windows

package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/chaspy/koe/windows/core"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

type sysInfo struct {
	CPU        string
	RAMTotalMB uint64
	RAMFreeMB  uint64
}

// memoryStatusEx is MEMORYSTATUSEX.
type memoryStatusEx struct {
	Length               uint32
	MemoryLoad           uint32
	TotalPhys            uint64
	AvailPhys            uint64
	TotalPageFile        uint64
	AvailPageFile        uint64
	TotalVirtual         uint64
	AvailVirtual         uint64
	AvailExtendedVirtual uint64
}

var procGlobalMemoryStatusEx = kernel32.NewProc("GlobalMemoryStatusEx")

func readSysInfo() sysInfo {
	var si sysInfo
	if k, err := registry.OpenKey(registry.LOCAL_MACHINE, `HARDWARE\DESCRIPTION\System\CentralProcessor\0`, registry.QUERY_VALUE); err == nil {
		if s, _, err := k.GetStringValue("ProcessorNameString"); err == nil {
			si.CPU = strings.TrimSpace(s)
		}
		k.Close()
	}
	if si.CPU == "" {
		si.CPU = "unknown"
	}
	m := memoryStatusEx{}
	m.Length = uint32(unsafe.Sizeof(m))
	if r, _, _ := procGlobalMemoryStatusEx.Call(uintptr(unsafe.Pointer(&m))); r != 0 {
		si.RAMTotalMB = m.TotalPhys >> 20
		si.RAMFreeMB = m.AvailPhys >> 20
	}
	return si
}

func desktopDir() string {
	if p, err := windows.KnownFolderPath(windows.FOLDERID_Desktop, 0); err == nil && p != "" {
		return p
	}
	return filepath.Join(os.Getenv("USERPROFILE"), "Desktop")
}

// diagnosticsText is diagnostics.txt: environment and settings, no text
// the user spoke and no secrets.
func (a *App) diagnosticsText() []byte {
	var b bytes.Buffer
	w := func(format string, args ...any) { fmt.Fprintf(&b, format+"\r\n", args...) }
	v := windows.RtlGetVersion()
	si := readSysInfo()
	w("Koe diagnostics %s", time.Now().Format("2006-01-02 15:04:05 -0700"))
	w("koe_version = %s", version)
	w("koe_rev = %s", rev)
	w("windows = %d.%d.%d", v.MajorVersion, v.MinorVersion, v.BuildNumber)
	w("cpu = %s", si.CPU)
	w("logical_cpus = %d", runtime.NumCPU())
	w("ram_total_mb = %d", si.RAMTotalMB)
	w("ram_free_mb = %d", si.RAMFreeMB)
	model := a.modelPathFor(a.modelFile())
	if fi, err := os.Stat(model); err == nil {
		w("model = %s (%d MB)", model, fi.Size()>>20)
	} else {
		w("model = %s (missing)", model)
	}
	threads := a.cfg.ThreadsFor(runtime.NumCPU())
	if a.server != nil && a.server.Threads > 0 {
		threads = a.server.Threads
	}
	w("threads = %d (config threads=%d)", threads, a.cfg.Threads)
	w("pressMode = %s", a.pressMode())
	w("audioCtx = %s (speed first %s)", a.audioCtxSetting(), onOff(a.audioCtxSetting() != 0))
	w("hotkey = %s", a.hotkey())
	w("enabledPacks = %v", a.cfg.EnabledPacks)
	w("packSources = %v", a.cfg.PackSources)
	w("ready = %v", a.ready.Load())
	w("")
	w("[config.json, other keys]")
	cfgRaw, err := os.ReadFile(a.configPath())
	if err != nil {
		w("(could not read: %v)", err)
	} else if lines, err := core.RedactedConfigLines(cfgRaw, "model", "pressMode", "hotkey", "enabledPacks", "packSources", "threads", "audioCtx"); err != nil {
		w("(invalid JSON: %v)", err)
	} else {
		for _, l := range lines {
			w("%s", l)
		}
	}
	return b.Bytes()
}

// exportDiagnostics writes Koe-diagnostics-<time>.zip on the desktop and
// shows it in Explorer. It contains no audio and no transcribed text.
func (a *App) exportDiagnostics() {
	defer a.recoverLog("diagnostics")
	now := time.Now()
	files := []core.ZipFile{
		{Name: "diagnostics.txt", Data: a.diagnosticsText()},
		{Name: "koe.log", Data: core.ReadTail(2000, filepath.Join(a.localDir, "koe.log.1"), filepath.Join(a.localDir, "koe.log"))},
		{Name: "whisper-server.log", Data: core.ReadTail(500, filepath.Join(a.localDir, "whisper-server.log"))},
	}
	if _, err := os.Stat(filepath.Join(a.localDir, "update.log")); err == nil {
		files = append(files, core.ZipFile{Name: "update.log", Data: core.ReadTail(1000, filepath.Join(a.localDir, "update.log"))})
	}
	dir := desktopDir()
	_ = os.MkdirAll(dir, 0o755)
	path := filepath.Join(dir, core.DiagnosticsName(now))
	f, err := os.Create(path)
	if err == nil {
		err = core.WriteZip(f, files, now)
		if cerr := f.Close(); err == nil {
			err = cerr
		}
	}
	if err != nil {
		a.log.Printf("diagnostics_failed %v", err)
		a.setError("診断情報を書き出せませんでした: "+err.Error(), false)
		return
	}
	a.log.Printf("diagnostics_exported %s", path)
	cmd := exec.Command("explorer.exe")
	cmd.SysProcAttr = &syscall.SysProcAttr{CmdLine: `explorer.exe /select,"` + path + `"`}
	if err := cmd.Start(); err != nil {
		a.log.Printf("diagnostics_explorer_failed %v", err)
	}
}

func onOff(b bool) string {
	if b {
		return "on"
	}
	return "off"
}
