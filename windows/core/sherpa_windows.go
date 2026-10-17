//go:build windows

package core

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"runtime"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

// SherpaRecognizer runs Parakeet-ja in Koe's process through
// sherpa-onnx-c-api.dll (loaded at run time, no cgo: Koe.exe still starts
// when the DLLs are missing, and whisper users never load them).
type SherpaRecognizer struct {
	mu   sync.Mutex
	dll  *windows.DLL
	rec  uintptr
	proc map[string]*windows.Proc
}

var sherpaProcs = []string{
	"SherpaOnnxGetVersionStr",
	"SherpaOnnxCreateOfflineRecognizer",
	"SherpaOnnxDestroyOfflineRecognizer",
	"SherpaOnnxCreateOfflineStream",
	"SherpaOnnxDestroyOfflineStream",
	"SherpaOnnxAcceptWaveformOffline",
	"SherpaOnnxDecodeOfflineStream",
	"SherpaOnnxGetOfflineStreamResultAsJson",
	"SherpaOnnxDestroyOfflineStreamResultJson",
}

// NewSherpaRecognizer loads dllPath (onnxruntime.dll must be next to it or
// next to Koe.exe) and the model in modelDir. Loading takes a few seconds.
func NewSherpaRecognizer(dllPath, modelDir string, threads int) (*SherpaRecognizer, error) {
	// LOAD_WITH_ALTERED_SEARCH_PATH: find onnxruntime.dll next to the C API
	// DLL first. Windows has its own older onnxruntime.dll in System32
	// (1.17, Windows ML), which crashes sherpa-onnx when it is picked instead.
	abs, err := filepath.Abs(dllPath)
	if err != nil {
		return nil, err
	}
	h, err := windows.LoadLibraryEx(abs, 0, windows.LOAD_WITH_ALTERED_SEARCH_PATH)
	if err != nil {
		return nil, fmt.Errorf("%s を読み込めません: %w", SherpaDLL, err)
	}
	dll := &windows.DLL{Name: abs, Handle: h}
	s := &SherpaRecognizer{dll: dll, proc: map[string]*windows.Proc{}}
	for _, name := range sherpaProcs {
		p, err := dll.FindProc(name)
		if err != nil {
			dll.Release()
			return nil, fmt.Errorf("%s: %w", SherpaDLL, err)
		}
		s.proc[name] = p
	}
	str := func(v string) *byte { b, _ := windows.BytePtrFromString(v); return b }
	cfg := &sherpaRecognizerConfig{
		SampleRate:     SampleRate,
		FeatureDim:     80,
		NemoCtcModel:   str(modelDir + `\` + ParakeetModelFile),
		Tokens:         str(modelDir + `\` + ParakeetTokensFile),
		NumThreads:     int32(threads),
		Provider:       str("cpu"),
		DecodingMethod: str("greedy_search"),
	}
	r, _, _ := s.proc["SherpaOnnxCreateOfflineRecognizer"].Call(uintptr(unsafe.Pointer(cfg)))
	runtime.KeepAlive(cfg)
	if r == 0 {
		dll.Release()
		return nil, errors.New("Parakeet-ja のモデルを読み込めませんでした（" + modelDir + "）")
	}
	s.rec = r
	return s, nil
}

// Version is the DLL's sherpa-onnx version, e.g. "1.13.8".
func (s *SherpaRecognizer) Version() string {
	r, _, _ := s.proc["SherpaOnnxGetVersionStr"].Call()
	return cString(r)
}

// Recognize decodes wav (16 kHz mono); the whisper-only arguments are ignored.
func (s *SherpaRecognizer) Recognize(ctx context.Context, wav []byte, _ string, _ bool, _ int) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	samples := FloatSamples(wav)
	if len(samples) == 0 {
		return "", nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.rec == 0 {
		return "", errors.New("Parakeet-ja は終了済みです")
	}
	st, _, _ := s.proc["SherpaOnnxCreateOfflineStream"].Call(s.rec)
	if st == 0 {
		return "", errors.New("sherpa-onnx: stream を作れませんでした")
	}
	defer s.proc["SherpaOnnxDestroyOfflineStream"].Call(st)
	s.proc["SherpaOnnxAcceptWaveformOffline"].Call(st, uintptr(SampleRate), uintptr(unsafe.Pointer(&samples[0])), uintptr(len(samples)))
	runtime.KeepAlive(samples)
	s.proc["SherpaOnnxDecodeOfflineStream"].Call(s.rec, st)
	js, _, _ := s.proc["SherpaOnnxGetOfflineStreamResultAsJson"].Call(st)
	if js == 0 {
		return "", errors.New("sherpa-onnx: 結果がありません")
	}
	defer s.proc["SherpaOnnxDestroyOfflineStreamResultJson"].Call(js)
	return SherpaResultText(cString(js))
}

// Close frees the model. The DLL stays loaded until Koe exits.
func (s *SherpaRecognizer) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.rec != 0 {
		s.proc["SherpaOnnxDestroyOfflineRecognizer"].Call(s.rec)
		s.rec = 0
	}
}

// cString copies the NUL-terminated string at p (C memory).
func cString(p uintptr) string {
	if p == 0 {
		return ""
	}
	return windows.BytePtrToString(*(**byte)(unsafe.Pointer(&p)))
}
