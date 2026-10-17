//go:build windows

package main

import "github.com/chaspy/koe/windows/core"

// newParakeet loads Parakeet-ja the way Koe does (engine "parakeet").
func newParakeet(dll, dir string, threads int) (core.Recognizer, func(), error) {
	r, err := core.NewSherpaRecognizer(dll, dir, threads)
	if err != nil {
		return nil, nil, err
	}
	return r, r.Close, nil
}
