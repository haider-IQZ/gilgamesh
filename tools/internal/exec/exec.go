// Package exec owns process creation. Commands never pass through a shell.
package exec

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	osexec "os/exec"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type Command struct {
	Name           string
	Args           []string
	Stdin          io.Reader
	Stdout, Stderr io.Writer
	Secret         bool
	Replace        bool
}

func C(name string, args ...string) Command { return Command{Name: name, Args: args} }

type Runner interface {
	Run(context.Context, Command) (string, error)
}
type ExitError struct{ Code int }

func (e ExitError) Error() string { return fmt.Sprintf("exit status %d", e.Code) }
func Code(err error) int {
	if err == nil {
		return 0
	}
	var lookup *osexec.Error
	var pathError *os.PathError
	if errors.As(err, &lookup) || (errors.As(err, &pathError) && (pathError.Op == "fork/exec" || pathError.Op == "exec")) {
		if errors.Is(err, osexec.ErrNotFound) || errors.Is(err, os.ErrNotExist) {
			return 127
		}
		if errors.Is(err, os.ErrPermission) {
			return 126
		}
	}
	var e *osexec.ExitError
	if errors.As(err, &e) {
		if status, ok := e.Sys().(syscall.WaitStatus); ok && status.Signaled() {
			return 128 + int(status.Signal())
		}
		return e.ExitCode()
	}
	var f ExitError
	if errors.As(err, &f) {
		return f.Code
	}
	return 1
}
func Show(c Command) string {
	a := append([]string{c.Name}, c.Args...)
	for i := range a {
		a[i] = fmt.Sprintf("%q", a[i])
	}
	return strings.Join(a, " ")
}

type Real struct {
	Log   io.Writer
	Grace time.Duration
}

func (r *Real) Run(ctx context.Context, c Command) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if r.Log != nil {
		fmt.Fprintln(r.Log, "$ "+Show(c))
	}
	if c.Replace {
		path, err := osexec.LookPath(c.Name)
		if err != nil {
			return "", err
		}
		err = syscall.Exec(path, append([]string{c.Name}, c.Args...), os.Environ())
		if err != nil {
			return "", &os.PathError{Op: "exec", Path: path, Err: err}
		}
		return "", nil
	}
	cmd := osexec.Command(c.Name, c.Args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Stdin = c.Stdin
	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	// Suppress ALL child output for secret input, even if a failing helper echoes it.
	if r.Log != nil && !c.Secret {
		cmd.Stdout = io.MultiWriter(&out, r.Log)
		cmd.Stderr = io.MultiWriter(&stderr, r.Log)
	}
	if !c.Secret {
		if c.Stdout != nil {
			cmd.Stdout = c.Stdout
		}
		if c.Stderr != nil {
			cmd.Stderr = io.MultiWriter(&stderr, c.Stderr)
		}
	}
	if err := cmd.Start(); err != nil {
		return "", err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	var err error
	select {
	case err = <-done:
	case <-ctx.Done():
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		grace := r.Grace
		if grace == 0 {
			grace = 10 * time.Second
		}
		deadline := time.NewTimer(grace)
		ticker := time.NewTicker(20 * time.Millisecond)
		reaped := false
	waitGroup:
		for {
			select {
			case <-done:
				reaped = true
				done = nil
			case <-ticker.C:
				if syscall.Kill(-cmd.Process.Pid, 0) == syscall.ESRCH {
					break waitGroup
				}
			case <-deadline.C:
				_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
				break waitGroup
			}
		}
		ticker.Stop()
		deadline.Stop()
		if !reaped {
			<-done
		}
		err = ctx.Err()
	}
	if c.Secret {
		return "", err
	}
	if err != nil {
		detail := strings.TrimSpace(stderr.String())
		if len(detail) > 2048 {
			detail = detail[len(detail)-2048:]
		}
		if detail != "" {
			return out.String(), fmt.Errorf("%s: %w: %s", c.Name, err, detail)
		}
		return out.String(), fmt.Errorf("%s: %w", c.Name, err)
	}
	return out.String(), nil
}

// Fake is deliberately opt-in through dependency injection, never a CLI flag.
// Secrets are not retained in Calls; handlers may consume stdin to verify chpasswd.
type Fake struct {
	Calls  []Command
	Handle func(context.Context, Command) (string, error)
	mu     sync.Mutex
}

func (f *Fake) Run(ctx context.Context, c Command) (string, error) {
	copy := c
	copy.Args = append([]string(nil), c.Args...)
	copy.Stdin = nil
	copy.Stdout = nil
	copy.Stderr = nil
	f.mu.Lock()
	f.Calls = append(f.Calls, copy)
	f.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if f.Handle != nil {
		return f.Handle(ctx, c)
	}
	return "", nil
}

// Signals consumes subsequent signals throughout cleanup. Ignore must be called
// before cleanup begins on ordinary failures too. Stop only after cleanup finishes.
type Signals struct {
	Context context.Context
	cancel  context.CancelFunc
	ch      chan os.Signal
	done    chan struct{}
	code    atomic.Int32
	once    sync.Once
}

func WatchSignals() *Signals {
	ctx, cancel := context.WithCancel(context.Background())
	s := &Signals{Context: ctx, cancel: cancel, ch: make(chan os.Signal, 8), done: make(chan struct{})}
	signal.Notify(s.ch, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGQUIT)
	go func() {
		for {
			select {
			case sig := <-s.ch:
				if s.code.CompareAndSwap(0, int32(128+int(sig.(syscall.Signal)))) {
					s.cancel()
				}
			case <-s.done:
				return
			}
		}
	}()
	return s
}
func (s *Signals) Ignore() {
	signal.Ignore(syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGQUIT)
}
func (s *Signals) Code() int { return int(s.code.Load()) }
func (s *Signals) Stop()     { s.once.Do(func() { signal.Stop(s.ch); close(s.done); s.cancel() }) }
