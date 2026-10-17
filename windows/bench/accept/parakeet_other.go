//go:build !windows

package main

import (
	"errors"

	"github.com/chaspy/koe/windows/core"
)

func newParakeet(string, string, int) (core.Recognizer, func(), error) {
	return nil, nil, errors.New("-engine parakeet runs only on Windows (sherpa-onnx-c-api.dll)")
}
