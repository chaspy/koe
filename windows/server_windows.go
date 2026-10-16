//go:build windows

package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/chaspy/koe/windows/core"
	"golang.org/x/sys/windows"
)

const createNoWindow = 0x08000000

// statusDLLNotFound: whisper-server.exe could not load a DLL (usually the
// Visual C++ runtime: MSVCP140.dll / VCRUNTIME140.dll / VCOMP140.dll).
const statusDLLNotFound = 0xC0000135

// hideWindow makes child processes not flash a console window.
func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
}

type WhisperServer struct {
	app      *App
	mu       sync.Mutex
	cmd      *exec.Cmd
	job      windows.Handle
	exited   chan struct{}
	stopping bool // Stop was called: the exit is expected
	Threads  int
	Model    string
	Exe      string        // core.CPUServerExe (default) or core.VulkanServerExe
	Probe    core.GPUProbe // what the server said about the GPU
	OnGPU    bool          // the Vulkan build is running on a GPU (set by App.startServer)
}

func (s *WhisperServer) exeName() string {
	if s.Exe == "" {
		return core.CPUServerExe
	}
	return s.Exe
}

// logName is whisper-server.log for the CPU build, whisper-server-vulkan.log
// for the Vulkan build (so a GPU attempt's log survives the CPU fallback).
func (s *WhisperServer) logName() string {
	if s.exeName() == core.VulkanServerExe {
		return "whisper-server-vulkan.log"
	}
	return "whisper-server.log"
}

// Start launches whisper-server.exe (or reuses one already listening) and
// waits until it answers HTTP.
func (s *WhisperServer) Start(modelPath string) error {
	a := s.app
	base := core.BaseURL(a.cfg.Port)
	if core.IsAlive(base) {
		a.log.Printf("server_reuse %s (already running)", base)
		return nil
	}
	exe := filepath.Join(a.exeDir, s.exeName())
	if _, err := os.Stat(exe); err != nil {
		return fmt.Errorf("%s が見つかりません: %s", s.exeName(), exe)
	}
	threads := a.cfg.ThreadsFor(runtime.NumCPU())
	s.Threads, s.Model = threads, modelPath
	args := core.ServerArgs(a.cfg, modelPath, threads)
	logPath := filepath.Join(a.localDir, s.logName())
	lf, err := os.Create(logPath)
	if err != nil {
		return err
	}
	cmd := exec.Command(exe, args...)
	cmd.Dir = a.exeDir
	// everything goes to whisper-server.log; CPU features, thread count and
	// timings are also copied into koe.log
	filter := &core.LineFilter{Match: core.InterestingServerLine, Fn: func(line string) {
		a.log.Printf("whisper_server %s", line)
		s.Probe.Line(line)
	}}
	out := io.MultiWriter(lf, filter)
	cmd.Stdout, cmd.Stderr = out, out
	hideWindow(cmd)
	t0 := time.Now()
	if err := cmd.Start(); err != nil {
		lf.Close()
		return fmt.Errorf("whisper-server を起動できません: %w", err)
	}
	a.log.Printf("server_launched exe=%s pid=%d threads=%d model=%s args=%q log=%s", s.exeName(), cmd.Process.Pid, threads, modelPath, args[:len(args)-2], logPath)
	exited := make(chan struct{})
	s.mu.Lock()
	s.cmd, s.exited = cmd, exited
	s.mu.Unlock()
	s.assignJob(cmd.Process.Pid)
	go func() {
		err := cmd.Wait()
		lf.Close()
		code := -1
		if cmd.ProcessState != nil {
			code = cmd.ProcessState.ExitCode()
		}
		a.log.Printf("server_exited code=%d (0x%X) err=%v after_ms=%d", code, uint32(code), err, time.Since(t0).Milliseconds())
		s.mu.Lock()
		expected := s.stopping
		s.mu.Unlock()
		if a.ready.Swap(false) && !expected {
			a.setError("whisper-server が終了しました。Koe を再起動してください", true)
		}
		close(exited)
	}()

	deadline := time.Now().Add(300 * time.Second)
	for {
		if core.IsAlive(base) {
			a.log.Printf("server_ready ms=%d", time.Since(t0).Milliseconds())
			return nil
		}
		select {
		case <-exited:
			code := -1
			if cmd.ProcessState != nil {
				code = cmd.ProcessState.ExitCode()
			}
			if uint32(code) == statusDLLNotFound {
				return errors.New("whisper-server が DLL を読み込めませんでした。Microsoft Visual C++ 再頒布可能パッケージ (x64) をインストールしてから Koe を起動し直してください: https://aka.ms/vs/17/release/vc_redist.x64.exe")
			}
			return fmt.Errorf("whisper-server が起動直後に終了しました (code 0x%X)。%s を送ってください", uint32(code), logPath)
		case <-time.After(500 * time.Millisecond):
		}
		if time.Now().After(deadline) {
			return errors.New("whisper-server の起動がタイムアウトしました")
		}
	}
}

// assignJob puts the server in a kill-on-close job so it dies with Koe.
func (s *WhisperServer) assignJob(pid int) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		s.app.log.Printf("job_create_failed err=%v", err)
		return
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
		s.app.log.Printf("job_set_failed err=%v", err)
		windows.CloseHandle(job)
		return
	}
	ph, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(pid))
	if err != nil {
		s.app.log.Printf("job_open_process_failed err=%v", err)
		windows.CloseHandle(job)
		return
	}
	defer windows.CloseHandle(ph)
	if err := windows.AssignProcessToJobObject(job, ph); err != nil {
		s.app.log.Printf("job_assign_failed err=%v", err)
		windows.CloseHandle(job)
		return
	}
	s.mu.Lock()
	s.job = job
	s.mu.Unlock()
}

func (s *WhisperServer) Stop() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stopping = true
	if s.cmd != nil && s.cmd.Process != nil {
		_ = s.cmd.Process.Kill()
	}
	if s.job != 0 {
		windows.CloseHandle(s.job)
		s.job = 0
	}
}

// StopAndWait stops the server and waits (up to 10 s) until it has exited
// and the port no longer answers, so a new server can take the port.
func (s *WhisperServer) StopAndWait() {
	s.Stop()
	s.mu.Lock()
	exited := s.exited
	s.mu.Unlock()
	if exited != nil {
		select {
		case <-exited:
		case <-time.After(10 * time.Second):
		}
	}
	base := core.BaseURL(s.app.cfg.Port)
	for i := 0; i < 20 && core.IsAlive(base); i++ {
		time.Sleep(250 * time.Millisecond)
	}
}
