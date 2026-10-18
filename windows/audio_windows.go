//go:build windows

package main

import (
	"fmt"
	"runtime"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"github.com/chaspy/koe/windows/core"
	"golang.org/x/sys/windows"
)

const (
	waveMapper     = 0xFFFFFFFF
	callbackEvent  = 0x00050000
	whdrDone       = 0x00000001
	waveFormatPCM  = 1
	bufferSamples  = core.SampleRate / 20 // 50 ms
	numBuffers     = 10
	waveInCapsSize = 80
)

type waveFormatEx struct {
	FormatTag      uint16
	Channels       uint16
	SamplesPerSec  uint32
	AvgBytesPerSec uint32
	BlockAlign     uint16
	BitsPerSample  uint16
	CbSize         uint16
}

type waveHdr struct {
	Data          *byte
	BufferLength  uint32
	BytesRecorded uint32
	User          uintptr
	Flags         uint32
	Loops         uint32
	Next          uintptr
	Reserved      uintptr
}

// compile-time size checks for amd64 (WAVEHDR is 48 bytes)
var _ [48 - unsafe.Sizeof(waveHdr{})]byte
var _ [unsafe.Sizeof(waveHdr{}) - 48]byte

type waveInCaps struct {
	Mid           uint16
	Pid           uint16
	DriverVersion uint32
	Pname         [32]uint16
	Formats       uint32
	Channels      uint16
	Reserved1     uint16
}

func mmErr(code uintptr) error {
	if code == 0 {
		return nil
	}
	buf := make([]uint16, 256)
	procWaveInGetErrorTextW.Call(code, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	return fmt.Errorf("MMRESULT %d: %s", code, windows.UTF16ToString(buf))
}

// inputDevices lists waveIn device names; callers must not log the names.
func inputDevices() []string {
	n, _, _ := procWaveInGetNumDevs.Call()
	var out []string
	for i := uintptr(0); i < n; i++ {
		var c waveInCaps
		if r, _, _ := procWaveInGetDevCapsW.Call(i, uintptr(unsafe.Pointer(&c)), unsafe.Sizeof(c)); r == 0 {
			out = append(out, windows.UTF16ToString(c.Pname[:]))
		}
	}
	return out
}

// Recorder captures 16 kHz mono 16-bit from the default input (WAVE_MAPPER).
// In warm mode the device stays open and the last PreRollSeconds are kept, so
// the start of speech right after pressing the key is not cut off.
type Recorder struct {
	log  func(string, ...any)
	warm bool

	lifecycle sync.Mutex // serializes operations while closeLocked releases mu
	deviceID  uintptr
	fallback  *micFallback
	muted     core.MutedInput
	usedKind  core.MicKind // alternate used by the last Stop ("" = primary microphone)

	mu           sync.Mutex
	open         bool
	h            uintptr
	event        windows.Handle
	hdrs         []*waveHdr
	bufs         [][]byte
	pinner       runtime.Pinner
	stop         chan struct{}
	done         chan struct{}
	recording    bool
	samples      []int16
	preRoll      []int16
	lastBufferAt time.Time
	openedAt     time.Time
}

func NewRecorder(warm bool, log func(string, ...any)) *Recorder {
	return &Recorder{warm: warm, log: log, deviceID: waveMapper}
}

// Warm opens the device at startup in warm mode.
func (r *Recorder) Warm() {
	r.lifecycle.Lock()
	defer r.lifecycle.Unlock()
	if !r.warm {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.openLocked(); err != nil {
		r.log("mic_open_failed (warm) err=%v", err)
	}
}

func (r *Recorder) openLocked() error {
	if r.open {
		return nil
	}
	t0 := time.Now()
	ev, err := windows.CreateEvent(nil, 0, 0, nil)
	if err != nil {
		return fmt.Errorf("CreateEvent: %w", err)
	}
	wfx := waveFormatEx{
		FormatTag: waveFormatPCM, Channels: 1, SamplesPerSec: core.SampleRate,
		AvgBytesPerSec: core.SampleRate * 2, BlockAlign: 2, BitsPerSample: 16,
	}
	var h uintptr
	if rc, _, _ := procWaveInOpen.Call(uintptr(unsafe.Pointer(&h)), r.deviceID, uintptr(unsafe.Pointer(&wfx)), uintptr(ev), 0, callbackEvent); rc != 0 {
		windows.CloseHandle(ev)
		return fmt.Errorf("waveInOpen: %w", mmErr(rc))
	}
	r.h, r.event = h, ev
	r.hdrs = make([]*waveHdr, numBuffers)
	r.bufs = make([][]byte, numBuffers)
	for i := range r.hdrs {
		b := make([]byte, bufferSamples*2)
		hd := &waveHdr{Data: &b[0], BufferLength: uint32(len(b))}
		r.pinner.Pin(&b[0])
		r.pinner.Pin(hd)
		r.bufs[i], r.hdrs[i] = b, hd
		if rc, _, _ := procWaveInPrepareHeader.Call(h, uintptr(unsafe.Pointer(hd)), unsafe.Sizeof(*hd)); rc != 0 {
			r.closeLocked()
			return fmt.Errorf("waveInPrepareHeader: %w", mmErr(rc))
		}
		if rc, _, _ := procWaveInAddBuffer.Call(h, uintptr(unsafe.Pointer(hd)), unsafe.Sizeof(*hd)); rc != 0 {
			r.closeLocked()
			return fmt.Errorf("waveInAddBuffer: %w", mmErr(rc))
		}
	}
	if rc, _, _ := procWaveInStart.Call(h); rc != 0 {
		r.closeLocked()
		return fmt.Errorf("waveInStart: %w", mmErr(rc))
	}
	r.open = true
	r.openedAt = time.Now()
	r.lastBufferAt = time.Now()
	r.stop = make(chan struct{})
	r.done = make(chan struct{})
	go r.reader(h, ev, r.hdrs, r.bufs, r.stop, r.done)
	r.log("mic_opened warm=%v ms=%d", r.warm, time.Since(t0).Milliseconds())
	return nil
}

// closeLocked stops and frees the device. Must hold r.mu; temporarily
// releases it while waiting for the reader goroutine.
func (r *Recorder) closeLocked() {
	if r.h == 0 {
		return
	}
	if r.stop != nil {
		close(r.stop)
		done := r.done
		r.mu.Unlock()
		<-done
		r.mu.Lock()
	}
	procWaveInReset.Call(r.h)
	for _, hd := range r.hdrs {
		if hd != nil {
			procWaveInUnprepareHdr.Call(r.h, uintptr(unsafe.Pointer(hd)), unsafe.Sizeof(*hd))
		}
	}
	procWaveInClose.Call(r.h)
	windows.CloseHandle(r.event)
	r.pinner.Unpin()
	r.h, r.event, r.hdrs, r.bufs, r.stop, r.done = 0, 0, nil, nil, nil, nil
	r.open = false
	r.preRoll = nil
}

func (r *Recorder) reader(h uintptr, ev windows.Handle, hdrs []*waveHdr, bufs [][]byte, stop, done chan struct{}) {
	defer close(done)
	next := 0
	for {
		select {
		case <-stop:
			return
		default:
		}
		windows.WaitForSingleObject(ev, 100)
		for i := 0; i < len(hdrs); i++ {
			hd := hdrs[next]
			if atomic.LoadUint32(&hd.Flags)&whdrDone == 0 {
				break
			}
			n := int(atomic.LoadUint32(&hd.BytesRecorded))
			chunk := core.BytesToPCM(bufs[next][:n])
			r.append(chunk)
			atomic.StoreUint32(&hd.Flags, atomic.LoadUint32(&hd.Flags)&^whdrDone)
			select {
			case <-stop:
				return
			default:
			}
			procWaveInAddBuffer.Call(h, uintptr(unsafe.Pointer(hd)), unsafe.Sizeof(*hd))
			next = (next + 1) % len(hdrs)
		}
	}
}

func (r *Recorder) append(chunk []int16) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(chunk) > 0 {
		r.lastBufferAt = time.Now()
	}
	if r.recording {
		r.muted.Add(chunk)
		r.samples = append(r.samples, chunk...)
		return
	}
	if r.warm {
		r.preRoll = append(r.preRoll, chunk...)
		max := int(core.PreRollSeconds * core.SampleRate)
		if len(r.preRoll) > max {
			r.preRoll = append(r.preRoll[:0:0], r.preRoll[len(r.preRoll)-max:]...)
		}
	}
}

// Start begins capturing. In warm mode the pre-roll is included.
func (r *Recorder) Start() error {
	r.lifecycle.Lock()
	defer r.lifecycle.Unlock()
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.recording {
		return nil
	}
	if r.open && time.Since(r.lastBufferAt) > time.Second {
		r.log("mic_stalled last_buffer_ago_ms=%d -> reopen", time.Since(r.lastBufferAt).Milliseconds())
		r.closeLocked()
	}
	if err := r.openLocked(); err != nil {
		return err
	}
	if r.warm {
		r.samples = append([]int16{}, r.preRoll...)
	} else {
		r.samples = nil
	}
	r.preRoll = nil
	r.recording = true
	r.startFallbackLocked()
	return nil
}

// Stop keeps recording TailSeconds more, then returns the captured samples.
func (r *Recorder) Stop() []int16 {
	r.lifecycle.Lock()
	defer r.lifecycle.Unlock()
	// The tail is captured while holding lifecycle on purpose: a Start() from
	// a quick re-press waits at most TailSeconds, and in warm mode that audio
	// lands in its pre-roll, so nothing is lost.
	time.Sleep(time.Duration(core.TailSeconds * float64(time.Second)))
	r.finishFallback()
	r.mu.Lock()
	defer r.mu.Unlock()
	r.recording = false
	s := r.fallbackSamples(r.samples)
	r.samples = nil
	if !r.warm {
		r.closeLocked()
	}
	return s
}

// Discard drops the current recording.
func (r *Recorder) Discard() {
	r.lifecycle.Lock()
	defer r.lifecycle.Unlock()
	r.finishFallback()
	r.mu.Lock()
	defer r.mu.Unlock()
	r.recording = false
	r.samples = nil
	if !r.warm {
		r.closeLocked()
	}
}

// Reopen closes and reopens the device (e.g. after digital silence).
func (r *Recorder) Reopen(reason string) {
	r.lifecycle.Lock()
	defer r.lifecycle.Unlock()
	r.mu.Lock()
	defer r.mu.Unlock()
	// A previous utterance can finish processing after the next one starts.
	// Do not interrupt that recording or its fallback worker.
	if r.recording {
		return
	}
	r.log("mic_reopen reason=%s", reason)
	r.closeLocked()
	if r.warm {
		if err := r.openLocked(); err != nil {
			r.log("mic_open_failed err=%v", err)
		}
	}
}

func (r *Recorder) Close() {
	r.lifecycle.Lock()
	defer r.lifecycle.Unlock()
	r.finishFallback()
	r.mu.Lock()
	defer r.mu.Unlock()
	r.closeLocked()
}
