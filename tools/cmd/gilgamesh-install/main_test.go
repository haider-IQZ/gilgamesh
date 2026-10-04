package main

import (
	"os"
	"strings"
	"testing"

	"github.com/haider-IQZ/gilgamesh/tools/internal/testkit"
)

func TestMainPanicReturnsFailure(t *testing.T) {
	f := testkit.FS(t)
	errout, e := os.Create(f.Path("/stderr"))
	if e != nil {
		t.Fatal(e)
	}
	defer errout.Close()
	args, stderr := os.Args, os.Stderr
	defer func() { os.Args, os.Stderr = args, stderr }()
	os.Args, os.Stderr = nil, errout // Force an early panic before any host commands.
	if code := mainCode(); code != 1 {
		t.Fatal("panic exit code", code)
	}
	b, e := os.ReadFile(errout.Name())
	if e != nil || !strings.Contains(string(b), "installer panicked:") {
		t.Fatal(string(b), e)
	}
}
