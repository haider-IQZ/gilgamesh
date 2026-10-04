package exec

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/haider-IQZ/gilgamesh/tools/internal/testkit"
)

func helperArgs() []string {
	for n, a := range os.Args {
		if a == "--" {
			return os.Args[n+1:]
		}
	}
	return nil
}
func TestExecHelper(t *testing.T) {
	a := helperArgs()
	if len(a) == 0 {
		return
	}
	switch a[0] {
	case "echo":
		b, _ := io.ReadAll(os.Stdin)
		fmt.Fprint(os.Stdout, string(b))
		fmt.Fprint(os.Stderr, string(b))
		os.Exit(42)
	case "argv":
		fmt.Fprint(os.Stdout, strings.Join(a[1:], "\n"))
		os.Exit(0)
	case "group":
		fmt.Fprintf(os.Stdout, "%d %d", os.Getpid(), syscall.Getpgrp())
		os.Exit(0)
	case "stubborn":
		signal.Ignore(syscall.SIGTERM)
		_ = os.WriteFile(a[1], []byte(strconv.Itoa(os.Getpid())), 0600)
		for {
			time.Sleep(time.Second)
		}
	}
}
func TestSecretNeverLogged(t *testing.T) {
	var log bytes.Buffer
	r := Real{Log: &log}
	c := C(os.Args[0], "-test.run=^TestExecHelper$", "--", "echo")
	c.Secret = true
	c.Stdin = strings.NewReader("enkidu:secret password\n")
	out, e := r.Run(context.Background(), c)
	if out != "" || Code(e) != 42 || strings.Contains(log.String(), "secret password") || strings.Contains(e.Error(), "secret password") {
		t.Fatal("secret leaked or exit lost", out, e, log.String())
	}
}
func TestFailureIncludesBoundedStderr(t *testing.T) {
	for _, redirected := range []bool{false, true} {
		for _, input := range []string{"  preflight failed\n", strings.Repeat("x", 4096) + " final failure\n", " \n"} {
			c := C(os.Args[0], "-test.run=^TestExecHelper$", "--", "echo")
			c.Stdin = strings.NewReader(input)
			var stderr bytes.Buffer
			if redirected {
				c.Stderr = &stderr
			}
			out, e := (&Real{}).Run(context.Background(), c)
			if Code(e) != 42 || out != input {
				t.Fatal(out, e)
			}
			want := strings.TrimSpace(input)
			want = want[max(0, len(want)-2048):]
			message := c.Name + ": exit status 42"
			if want != "" {
				message += ": " + want
			}
			if e.Error() != message || (redirected && stderr.String() != input) {
				t.Fatal("stderr missing or unbounded", e)
			}
		}
	}
}
func TestExplicitArgv(t *testing.T) {
	want := []string{"$(touch /not-allowed)", "a; b", "*", "space separated", "quote'\""}
	out, e := (&Real{}).Run(context.Background(), C(os.Args[0], append([]string{"-test.run=^TestExecHelper$", "--", "argv"}, want...)...))
	if e != nil || out != strings.Join(want, "\n") {
		t.Fatal(out, e)
	}
}
func TestEveryChildHasProcessGroup(t *testing.T) {
	out, e := (&Real{}).Run(context.Background(), C(os.Args[0], "-test.run=^TestExecHelper$", "--", "group"))
	v := strings.Fields(out)
	if e != nil || len(v) != 2 || v[0] != v[1] || v[1] == strconv.Itoa(syscall.Getpgrp()) {
		t.Fatal(out, e)
	}
}
func TestCancellationEscalatesToKill(t *testing.T) {
	f := testkit.FS(t)
	ready := f.Path("/ready")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, e := (&Real{Grace: 100 * time.Millisecond}).Run(ctx, C(os.Args[0], "-test.run=^TestExecHelper$", "--", "stubborn", ready))
		done <- e
	}()
	deadline := time.Now().Add(5 * time.Second)
	var pid int
	for time.Now().Before(deadline) {
		b, e := os.ReadFile(ready)
		if e == nil {
			pid, _ = strconv.Atoi(string(b))
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if pid == 0 {
		cancel()
		<-done
		t.Fatal("helper never ready")
	}
	start := time.Now()
	cancel()
	select {
	case e := <-done:
		if !errors.Is(e, context.Canceled) {
			t.Fatal(e)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("runner failed to kill child")
	}
	if time.Since(start) < 90*time.Millisecond {
		t.Fatal("did not grant grace")
	}
	if syscall.Kill(pid, 0) != syscall.ESRCH {
		t.Fatal("child survived")
	}
}
func TestCanceledBeforeStart(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, e := (&Real{}).Run(ctx, C("must-not-execute")); !errors.Is(e, context.Canceled) {
		t.Fatal(e)
	}
}

func TestMissingCommandStatus(t *testing.T) {
	_, e := (&Real{}).Run(context.Background(), C("/gilgamesh-test-nonexistent-command"))
	if Code(e) != 127 {
		t.Fatal("missing-command exit status", e, Code(e))
	}
}

func TestMissingFileIsNotMissingCommand(t *testing.T) {
	e := &os.PathError{Op: "open", Path: "/fixture/missing", Err: os.ErrNotExist}
	if Code(e) != 1 {
		t.Fatal("filesystem error got command-not-found status")
	}
}
