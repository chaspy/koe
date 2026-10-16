package core

import (
	"strings"
	"sync"
)

// GPU settings (config "gpu").
const (
	GPUAuto = "auto" // use the Vulkan build when there is a usable GPU, else the CPU build
	GPUOff  = "off"
)

// Server builds shipped next to Koe.exe.
const (
	CPUServerExe    = "whisper-server.exe"
	VulkanServerExe = "whisper-server-vulkan.exe"
)

// Reasons for running the CPU build although gpu is "auto".
const (
	FallbackNotBundled  = "not_bundled"                // no whisper-server-vulkan.exe
	FallbackStartFailed = "start_failed"               // exited or timed out before answering
	FallbackNoDevice    = "no_device"                  // Vulkan found no GPU
	FallbackInitFailed  = "init_failed"                // a GPU was found but its backend did not start
	FallbackNoBackend   = "no_backend_line"            // the output never said which backend is used
	FallbackFirstFailed = "first_transcription_failed" // the GPU server answered, then failed a request
)

// GPUProbe reads whisper-server's output and tells whether it runs on a GPU.
// whisper.cpp v1.9.2 logs, while loading the model (before it listens):
//
//	whisper_backend_init_gpu: using Vulkan0 backend
//	whisper_backend_init_gpu: no GPU found        (and ggml_vulkan: No devices found.)
//	whisper_backend_init_gpu: failed to initialize Vulkan0 backend
type GPUProbe struct {
	mu       sync.Mutex
	backend  string
	noDevice bool
	failed   bool
}

// Line feeds one output line (use with LineFilter).
func (p *GPUProbe) Line(line string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	switch {
	case strings.Contains(line, "ggml_vulkan: No devices found"), strings.Contains(line, "whisper_backend_init_gpu: no GPU found"):
		p.noDevice = true
	case strings.Contains(line, "whisper_backend_init_gpu: failed to initialize"):
		p.failed = true
	case strings.Contains(line, "whisper_backend_init_gpu: using "):
		s := line[strings.Index(line, "whisper_backend_init_gpu: using ")+len("whisper_backend_init_gpu: using "):]
		p.backend = strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(s), "backend"))
	}
}

// Backend is the GPU backend in use ("Vulkan0"), or "" if none.
func (p *GPUProbe) Backend() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.noDevice || p.failed {
		return ""
	}
	return p.backend
}

// FallbackReason is why the server must not be used as the GPU server once it
// answers HTTP ("" = it runs on a GPU).
func (p *GPUProbe) FallbackReason() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	switch {
	case p.failed:
		return FallbackInitFailed
	case p.noDevice:
		return FallbackNoDevice
	case p.backend == "":
		return FallbackNoBackend
	}
	return ""
}

// AudioCtxSetting is the window setting for the backend in use: on a GPU the
// whole window is fast enough, so gpuAudioCtx (default 0) applies there.
func (c Config) AudioCtxSetting(onGPU bool, speedFirst AudioCtx) AudioCtx {
	if onGPU {
		return c.GPUAudioCtx
	}
	return speedFirst
}
