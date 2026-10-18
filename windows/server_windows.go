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
	port     int           // loopback port chosen at Start
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

// Start launches whisper-server.exe on a free loopback port chosen for this
// launch and waits until it is ready: the child is still running, it is the
// only process listening on its port, and GET /health answers 200. A server
// that is already listening somewhere is never reused, and config.json
// "port" is not used.
func (s *WhisperServer) Start(modelPath string) error {
	a := s.app
	exe := filepath.Join(a.exeDir, s.exeName())
	if _, err := os.Stat(exe); err != nil {
		return fmt.Errorf("%s が見つかりません: %s", s.exeName(), exe)
	}
	port, err := core.FreeLoopbackPort()
	if err != nil {
		return fmt.Errorf("whisper-server のポートを用意できません: %w", err)
	}
	threads := a.cfg.ThreadsFor(runtime.NumCPU())
	s.Threads, s.Model = threads, modelPath
	cfg := a.cfg
	cfg.Port = port
	args := core.ServerArgs(cfg, modelPath, threads)
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
	a.log.Printf("server_launched exe=%s pid=%d port=%d threads=%d model=%s args=%q log=%s", s.exeName(), cmd.Process.Pid, port, threads, modelPath, args[:len(args)-2], logPath)
	exited := make(chan struct{})
	s.mu.Lock()
	s.cmd, s.exited, s.port = cmd, exited, port
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

	base := core.BaseURL(port)
	deadline := time.Now().Add(300 * time.Second)
	for {
		switch st := s.state(); st {
		case core.ServerOwned:
			if core.IsHealthy(base) {
				a.log.Printf("server_ready ms=%d port=%d", time.Since(t0).Milliseconds(), port)
				return nil
			}
		case core.ServerForeign:
			a.log.Printf("server_port_shared port=%d -> stopping", port)
			s.Stop()
			return fmt.Errorf("whisper-server のポート %d を別のプログラムも使っています。Koe を再起動してください", port)
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
			s.Stop()
			return errors.New("whisper-server の起動がタイムアウトしました")
		}
	}
}

// BaseURL of this server (its port is chosen at each Start).
func (s *WhisperServer) BaseURL() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return core.BaseURL(s.port)
}

// Recognizer sends utterances to this server, checking before every request
// that it is still the child Koe started and still owns its port.
func (s *WhisperServer) Recognizer() core.Recognizer {
	return core.CheckedWhisper{BaseURL: s.BaseURL(), Check: s.Check}
}

// Check returns an error unless the child is running and is the only process
// listening on its port.
func (s *WhisperServer) Check() error {
	if st := s.state(); st != core.ServerOwned {
		return fmt.Errorf("server state %s", st)
	}
	return nil
}

// state looks up who listens on the server's port (IPv4 and IPv6 tables).
func (s *WhisperServer) state() core.ServerState {
	s.mu.Lock()
	cmd, exited, port := s.cmd, s.exited, s.port
	s.mu.Unlock()
	running := cmd != nil && cmd.Process != nil && exited != nil
	if running {
		select {
		case <-exited:
			running = false
		default:
		}
	}
	if !running {
		return core.ServerExited
	}
	table, err := listenerTable()
	if err != nil {
		s.app.log.Printf("listener_table_failed err=%v", err)
		return core.ServerForeign
	}
	return core.CheckServer(true, table, port, cmd.Process.Pid)
}

var (
	iphlpapi                = windows.NewLazySystemDLL("iphlpapi.dll")
	procGetExtendedTcpTable = iphlpapi.NewProc("GetExtendedTcpTable")
)

const tcpTableOwnerPIDListener = 3 // TCP_TABLE_OWNER_PID_LISTENER

// listenerTable returns every listening TCP socket (IPv4 and IPv6) with the
// id of its owning process.
func listenerTable() ([]core.Listener, error) {
	v4, err := ownerPIDTable(windows.AF_INET, core.TCPRowOwnerPIDSize)
	if err != nil {
		return nil, err
	}
	v6, err := ownerPIDTable(windows.AF_INET6, core.TCP6RowOwnerPIDSize)
	if err != nil {
		return nil, err
	}
	return append(v4, v6...), nil
}

func ownerPIDTable(family uint32, rowSize int) ([]core.Listener, error) {
	size := uint32(4 + 64*rowSize)
	for range 4 {
		buf := make([]byte, size)
		r, _, _ := procGetExtendedTcpTable.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&size)), 0,
			uintptr(family), tcpTableOwnerPIDListener, 0)
		switch windows.Errno(r) {
		case 0:
			return core.ParseOwnerPIDTable(buf, rowSize)
		case windows.ERROR_INSUFFICIENT_BUFFER:
			size += uint32(16 * rowSize) // the table can grow between calls
			continue
		default:
			return nil, fmt.Errorf("GetExtendedTcpTable: %w", windows.Errno(r))
		}
	}
	return nil, errors.New("GetExtendedTcpTable: table keeps growing")
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

// StopAndWait stops the server and waits (up to 10 s) until it has exited.
// The next Start picks a new port, so the old one need not be free.
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
}
