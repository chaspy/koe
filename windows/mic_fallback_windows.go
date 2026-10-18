//go:build windows

package main

import (
	"strings"
	"time"
	"unsafe"

	"github.com/chaspy/koe/windows/core"
	"golang.org/x/sys/windows"
)

var (
	fallbackWaveInGetID   = winmm.NewProc("waveInGetID")
	fallbackWaveInMessage = winmm.NewProc("waveInMessage")
)

// Query the interface rather than guessing transport from a user's device name.
// HDAUDIO identifies onboard audio (including its analog microphone jack).
func fallbackMicKind(id uintptr) core.MicKind {
	const querySize = 0x080c      // DRV_QUERYDEVICEINTERFACESIZE
	const queryInterface = 0x080d // DRV_QUERYDEVICEINTERFACE
	var size uint32
	if rc, _, _ := fallbackWaveInMessage.Call(id, querySize, uintptr(unsafe.Pointer(&size)), 0); rc != 0 || size < 2 || size > 65536 {
		return core.MicOther
	}
	buf := make([]uint16, (size+1)/2)
	if rc, _, _ := fallbackWaveInMessage.Call(id, queryInterface, uintptr(unsafe.Pointer(&buf[0])), uintptr(size)); rc != 0 {
		return core.MicOther
	}
	path := strings.ToUpper(windows.UTF16ToString(buf))
	if strings.Contains(path, `USB#`) {
		return core.MicUSB
	}
	if strings.Contains(path, `HDAUDIO#`) {
		return core.MicBuiltIn
	}
	return core.MicOther
}

func fallbackInputs() []core.FallbackMic {
	n, _, _ := procWaveInGetNumDevs.Call()
	var devices []core.FallbackMic
	for id := uintptr(0); id < n; id++ {
		var caps waveInCaps
		if rc, _, _ := procWaveInGetDevCapsW.Call(id, uintptr(unsafe.Pointer(&caps)), unsafe.Sizeof(caps)); rc == 0 {
			devices = append(devices, core.FallbackMic{ID: uint32(id), Name: windows.UTF16ToString(caps.Pname[:]), Kind: fallbackMicKind(id)})
		}
	}
	return devices
}

// One worker per recording owns the alternate recorder. Stop/Discard/Close
// join it before touching the primary recording's lifecycle. The primary stays
// open, so the next recording always starts on the selected/default device.
type micFallback struct {
	preferred string
	stop      chan struct{}
	done      chan struct{}
	pcm       []int16
	offset    int
	kind      core.MicKind // kind of the accepted alternate
}

func (r *Recorder) startFallbackLocked() {
	if r.fallback == nil {
		return
	}
	f := r.fallback
	f.stop, f.done = make(chan struct{}), make(chan struct{})
	f.pcm, f.kind = nil, ""
	r.usedKind = ""
	r.muted = core.MutedInput{}
	var primary uint32
	if rc, _, _ := fallbackWaveInGetID.Call(r.h, uintptr(unsafe.Pointer(&primary))); rc != 0 {
		// Without a reliable ID we cannot safely exclude the primary.
		close(f.done)
		return
	}
	go r.runFallback(f, primary)
}

func (r *Recorder) runFallback(f *micFallback, primary uint32) {
	defer close(f.done)
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	var candidate *Recorder
	var kind core.MicKind
	var opened time.Time
	accepted := false
	defer func() {
		if candidate == nil {
			return
		}
		candidate.Close()
		if accepted {
			f.pcm, f.kind = candidate.samples, kind
		}
	}()
	dead := map[uint32]bool{}
	var devices []core.FallbackMic
	for {
		select {
		case <-f.stop:
			return
		case <-ticker.C:
		}
		if accepted {
			continue
		}
		if candidate != nil {
			candidate.mu.Lock()
			peak := core.Peak(candidate.samples)
			candidate.mu.Unlock()
			if peak > core.MutedPeak {
				accepted = true
				r.log("mic_fallback kind=%s", kind)
				continue
			}
			if time.Since(opened) < time.Second {
				continue
			}
			candidate.Close()
			candidate = nil
		}
		r.mu.Lock()
		muted, offset := r.muted.Muted(), len(r.samples)
		r.mu.Unlock()
		if !muted {
			continue
		}
		if devices == nil {
			devices = fallbackInputs()
		}
		d, ok := core.ChooseFallbackMic(devices, primary, dead, f.preferred)
		if !ok {
			return
		}
		dead[d.ID] = true
		probe := NewRecorder(false, func(string, ...any) {})
		probe.deviceID = uintptr(d.ID)
		if err := probe.Start(); err != nil {
			probe.Close()
			continue
		}
		candidate, kind, opened, f.offset = probe, d.Kind, time.Now(), offset
	}
}

// finishFallback is called outside r.mu: the worker reads the primary state.
func (r *Recorder) finishFallback() {
	if f := r.fallback; f != nil && f.stop != nil {
		close(f.stop)
		<-f.done
		f.stop = nil
	}
}

func (r *Recorder) fallbackSamples(primary []int16) []int16 {
	if f := r.fallback; f != nil && len(f.pcm) > 0 && f.offset <= len(primary) {
		r.usedKind = f.kind
		return append(primary[:f.offset:f.offset], f.pcm...)
	}
	return primary
}

// FallbackKind reports the alternate microphone the last Stop() used, or ""
// when the recording came from the primary microphone. Call it right after
// Stop(), before the next Start().
func (r *Recorder) FallbackKind() core.MicKind {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.usedKind
}
