//go:build !windows

// Koe for Windows only builds on Windows. The platform-independent logic is
// in ./core and is tested with `go test ./core` on any OS.
package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "Koe for Windows: build with GOOS=windows (see build.sh)")
	os.Exit(1)
}
